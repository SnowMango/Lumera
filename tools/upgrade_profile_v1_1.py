#!/usr/bin/env python3
"""Convert explicitly selected development profiles. Default operation is a dry run."""
import argparse
import collections
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile

LIMIT = 16 * 1024 * 1024
RULE_VERSION = '7-to-8.1'
OLD_TARGETS = set('noise.gain noise.chromaRatio grain.amount grain.size grain.roughness grain.chroma softening.amount softening.sigma detail.fineGain detail.midGain detail.sharpenAmount glow.amount glow.threshold halation.amount halation.threshold vignette.amountEV'.split())
MODULES = {
    'color': 'exposureEV matrix shift whiteBalance',
    'detail': 'enabled fineGain fineSigma maxAdjustment midGain midSigma sharpenAmount sharpenSigma threshold',
    'glow': 'amount enabled farSigma farWeight knee nearSigma threshold',
    'grain': 'amount chroma enabled luminanceCurve roughness size',
    'halation': 'amount blue enabled green knee red sigma threshold',
    'noise': 'chromaCorrelation chromaRatio chromaSigma curve enabled gain lumaSigma',
    'softening': 'amount enabled sigma', 'tone': 'curve enabled',
    'vignette': 'amountEV centerX centerY enabled falloff startRadius',
}


def parse(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('duplicate key: ' + key)
            result[key] = value
        return result

    def number(value):
        result = float(value)
        if not math.isfinite(result):
            raise ValueError('nonfinite number')
        return result

    if len(data) > LIMIT:
        raise ValueError('profile exceeds 16 MiB')
    return json.loads(data.decode('utf-8'), object_pairs_hook=pairs, parse_float=number, parse_constant=number)


def fields(value, expected, path):
    if not isinstance(value, dict):
        raise ValueError(f'{path}: expected an object')
    expected = set(expected)
    if value.keys() != expected:
        raise ValueError(f'{path}: missing {sorted(expected - value.keys())}, unknown {sorted(value.keys() - expected)}')


def require_old_curve(curve, path):
    fields(curve, ['shape'], path)
    shape = curve['shape']
    if isinstance(shape, dict) and set(shape) == {'function'}:
        fields(shape['function'], ['_0'], path + '.shape.function')
        fields(shape['function']['_0'], 'family start end xLower xUpper exponent center width'.split(),
               path + '.shape.function._0')
    elif isinstance(shape, dict) and set(shape) == {'points'}:
        points = shape['points']
        fields(points, ['_0', 'interpolation'], path + '.shape.points')
        if not isinstance(points['_0'], list):
            raise ValueError(path + '.shape.points._0: expected an array')
        for i, node in enumerate(points['_0']):
            fields(node, ['x', 'y'], f'{path}.shape.points._0[{i}]')
    else:
        raise ValueError(path + '.shape: expected exactly one of function or points')


def convert(source):
    fields(source, 'id name description schemaVersion renderContractVersion spatialScaleVersion responses temporalPolicy parameters'.split(), '$')
    result = copy.deepcopy(source)
    for key, expected in [('schemaVersion', 7), ('spatialScaleVersion', 1), ('renderContractVersion', 1)]:
        if type(result[key]) is not int or result[key] != expected:
            raise ValueError('unsupported ' + key)
    modules = result['parameters']
    fields(modules, MODULES, 'parameters')
    for module, keys in MODULES.items():
        fields(modules[module], keys.split(), 'parameters.' + module)
    fields(modules['color']['matrix'], ['values'], 'parameters.color.matrix')
    fields(modules['color']['whiteBalance'], ['source', 'destination'], 'parameters.color.whiteBalance')
    for point in modules['color']['whiteBalance'].values():
        fields(point, ['x', 'y'], 'parameters.color.whiteBalance.*')
    fields(modules['color']['shift'], ['redGreen', 'yellowBlue'], 'parameters.color.shift')
    fields(result['temporalPolicy'], ['noise', 'grain'], 'temporalPolicy')
    if not isinstance(result['responses'], list):
        raise ValueError('responses: expected an array')
    for module, key in [('grain', 'luminanceCurve'), ('noise', 'curve'), ('tone', 'curve')]:
        require_old_curve(modules[module][key], f'parameters.{module}.{key}')
    for i, binding in enumerate(result['responses']):
        fields(binding, ['target', 'axis', 'operation', 'curve'], f'responses[{i}]')
        if not isinstance(binding['target'], str) or binding['target'] not in OLD_TARGETS:
            raise ValueError(f'responses[{i}].target: unknown schema 7 response')
        require_old_curve(binding['curve'], f'responses[{i}].curve')
    halo = modules['halation']
    sigma = halo.pop('sigma')
    if type(sigma) not in (int, float) or not 0.1 <= sigma <= 32:
        raise ValueError('parameters.halation.sigma: outside schema 7 range')
    radius = math.sqrt(2) * sigma
    if radius > 32:
        raise ValueError('parameters.halation.radius: converted radius exceeds 32; retune explicitly')
    halo['radius'] = radius
    result['schemaVersion'] = 8
    del result['spatialScaleVersion'], result['renderContractVersion']
    changes = [
        dict(field='schemaVersion', before=7, after=8, reason='parameter contract changed'),
        dict(field='renderContractVersion', before=1, reason='implementation detail moved out of Profile'),
        dict(field='spatialScaleVersion', before=1, reason='2048 reference is fixed by the schema'),
        dict(field='parameters.halation.sigma', target='parameters.halation.radius', before=sigma,
             after=radius, reason='continuous Gaussian radial RMS is sqrt(2) * sigma; new RGB kernels differ')
    ]
    review = []
    if halo['enabled'] or sigma != 4:
        review.append('parameters.halation.radius')
    grain_rules = {
        'amount': (0, 'reference-resolution integrated luminance RMS'),
        'size': (1, 'half-correlation distance in reference pixels'),
        'roughness': (0.35, 'coarse fraction of integrated reference variance'),
        'chroma': (0.15, 'relative normalized chroma amplitude'),
        'luminanceCurve': (None, 'encoded brightness to grain amplitude multiplier'),
    }
    for key, (default, meaning) in grain_rules.items():
        field = 'parameters.grain.' + key
        changes.append(dict(field=field, action='value preserved; review appearance', reason=meaning))
        if modules['grain']['enabled'] or (default is not None and modules['grain'][key] != default):
            review.append(field)
    for index, binding in enumerate(result['responses']):
        if binding['target'].startswith(('grain.', 'halation.')):
            field = f'responses[{index}]'
            review.append(field)
            changes.append(dict(field=field, action='preserve target, axis, operation and curve',
                                reason='response now drives the new texture model'))
    return result, changes, review


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False, sort_keys=True) + '\n').encode()


def write_new(path, data):
    # Link rather than replace: two invocations cannot overwrite one another.
    with tempfile.NamedTemporaryFile(dir=path.parent) as tmp:
        tmp.write(data)
        tmp.flush()
        os.link(tmp.name, path)


def process(path, row, validator, staging, output, output_conflict):
    if not path.is_file():
        raise ValueError("input must be an explicitly named regular file")
    with path.open('rb') as stream:
        raw = stream.read(LIMIT + 1)
        digest = hashlib.sha256(raw)
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    row['sourceSHA256'] = digest.hexdigest()
    profile = parse(raw)
    if not isinstance(profile, dict):
        raise ValueError('expected a profile object')
    row['sourceSchema'] = profile.get('schemaVersion')
    if type(row['sourceSchema']) is not int or row['sourceSchema'] not in (7, 8):
        raise ValueError('$.schemaVersion: unsupported source schema')
    if output_conflict:
        raise ValueError('duplicate output name or conflict with report')
    current = row['sourceSchema'] == 8
    candidate, changes, review = (profile, {}, []) if current else convert(profile)
    data = raw if current else encoded(candidate)
    row.update(changes=changes, review=review, targetSchema=8, targetSHA256=hashlib.sha256(data).hexdigest())
    with tempfile.NamedTemporaryFile(suffix='.json') as temp:
        temp.write(data)
        temp.flush()
        check = subprocess.run([validator, 'check-profile', '--profile', temp.name], capture_output=True, text=True)
        if check.returncode:
            raise ValueError(check.stderr.strip() or 'check-profile failed')
        effect_digest = check.stdout.strip()
        if len(effect_digest) != 64 or any(c not in '0123456789abcdef' for c in effect_digest):
            raise ValueError('validator returned no valid profile digest')
        row['effectDigest'] = effect_digest
    row['status'] = 'alreadyCurrent' if current else 'needsReview' if review else 'converted'
    if output and not current:
        write_new(staging / path.name, data)
        row['output'] = str(output / path.name)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, action='append', required=True)
    parser.add_argument('--validator', required=True, help='path to v1.1 ccdlab')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args(argv)
    if args.apply != bool(args.output_dir):
        parser.error('--apply and --output-dir must be supplied together')
    if args.report and (args.report.exists() or args.report.is_symlink()):
        parser.error('report destination already exists')
    output = args.output_dir
    # Reserve the output name exclusively, then swap in a complete sibling directory.
    # Candidates and their report become visible together, including for partial batches.
    if output:
        output.mkdir(exist_ok=False)
    try:
        with tempfile.TemporaryDirectory(dir=output.parent if output else None) as temporary:
            staging = Path(temporary) / 'batch'
            staging.mkdir()
            sidecar = output / 'upgrade-report.json' if output else None
            report = args.report
            if output and report and report.parent.resolve() == output.resolve():
                sidecar, report = report, None
            names = collections.Counter(p.name.casefold() for p in args.input)
            rows = []
            for path in args.input:
                row = {'source': str(path)}
                try:
                    collision = output and (names[path.name.casefold()] > 1 or path.name.casefold() == sidecar.name.casefold())
                    process(path, row, args.validator, staging, output, collision)
                except (ValueError, OSError, RecursionError, TypeError) as error:
                    row.update(status='failed', error=str(error))
                rows.append(row)
            data = encoded({'rules': RULE_VERSION, 'dryRun': not args.apply, 'files': rows})
            if sidecar:
                write_new(staging / sidecar.name, data)
            if report:
                write_new(report, data)
            if output:
                os.rename(staging, output)
    except BaseException:
        if output:
            output.rmdir()  # Only remove our empty reservation.
        raise
    sys.stdout.buffer.write(data)
    return int(any(row['status'] == 'failed' for row in rows))


if __name__ == '__main__':
    try:
        sys.exit(main())
    except OSError as error:
        sys.exit(str(error))
