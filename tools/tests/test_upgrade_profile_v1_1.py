import json
import math
import sys
import subprocess
import tempfile
import os
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import upgrade_profile_v1_1 as upgrade


class ProfileUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.profile = upgrade.parse((Path(__file__).parent / 'fixtures/profile_upgrade/film-v7.json').read_bytes())

    def test_radius_and_reviewed_dynamic_curve(self):
        self.profile['responses'] = [{'target': 'grain.size', 'axis': 'iso', 'operation': 'replace', 'curve': self.profile['parameters']['tone']['curve']}]
        before = json.dumps(self.profile)
        result, changes, review = upgrade.convert(self.profile)
        self.assertEqual(result['schemaVersion'], 8)
        self.assertAlmostEqual(result['parameters']['halation']['radius'], math.sqrt(2) * self.profile['parameters']['halation']['sigma'])
        self.assertEqual(result['responses'], self.profile['responses'])
        self.assertIn('responses[0]', review)
        self.assertEqual(before, json.dumps(self.profile))
        self.assertTrue(changes)

    def test_no_clamp_or_field_loss(self):
        self.profile['parameters']['halation']['sigma'] = 32
        with self.assertRaises(ValueError): upgrade.convert(self.profile)
        self.profile['parameters']['halation']['sigma'] = 1
        self.profile['parameters']['halation']['radius'] = 3
        with self.assertRaises(ValueError): upgrade.convert(self.profile)

    def test_duplicate_keys_and_nonfinite_rejected(self):
        for data in (b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":1e500}'):
            with self.assertRaises(ValueError): upgrade.parse(data)

    def test_rejects_missing_v7_curve_fields_before_new_defaults(self):
        for module, key in [('grain', 'luminanceCurve'), ('noise', 'curve')]:
            curve = self.profile['parameters'][module][key]
            removed = curve['shape']['function']['_0'].pop('width')
            with self.assertRaisesRegex(ValueError, 'width'):
                upgrade.convert(self.profile)
            curve['shape']['function']['_0']['width'] = removed
        self.profile['parameters']['tone']['curve']['shape']['points'].pop('interpolation')
        with self.assertRaisesRegex(ValueError, 'interpolation'):
            upgrade.convert(self.profile)

    def test_unknown_v7_target_is_rejected_before_candidate(self):
        binding = {'target': 'bogus', 'axis': 'iso', 'operation': 'replace',
                   'curve': self.profile['parameters']['tone']['curve']}
        self.profile['responses'] = [binding]
        with self.assertRaisesRegex(ValueError, 'target'):
            upgrade.convert(self.profile)

class UpgradeBatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixtures = Path(__file__).parent / 'fixtures/profile_upgrade'
        # The fixture CLI isolates filesystem/report behavior in the Python suite.
        # Set CCDCLI_BINARY to exercise exactly the same tests through the real codec.
        self.validator = os.environ.get('CCDCLI_BINARY')
        if not self.validator:
            executable = self.root / 'validator'
            executable.write_text('#!/bin/sh\n[ "$1" = check-profile ] && [ "$2" = --profile ] && [ -f "$3" ] || exit 2\necho aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n')
            executable.chmod(0o700)
            self.validator = str(executable)

    def invoke(self, *inputs, extra=(), validator=None):
        args = [sys.executable, str(Path(upgrade.__file__)), '--validator', validator or self.validator]
        for source in inputs:
            args.extend(['--input', str(source)])
        return subprocess.run(args + list(map(str, extra)), capture_output=True, text=True, cwd=self.root)

    def test_dry_run_and_explicit_inputs_only(self):
        source = self.root / 'source.json'
        raw = (self.fixtures / 'dynamic-v7.json').read_bytes()
        source.write_bytes(raw)
        (self.root / 'unlisted.json').write_bytes(b'broken')
        before = set(self.root.iterdir())
        result = self.invoke(source)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        rows = json.loads(result.stdout)['files']
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['status'], 'needsReview')
        self.assertEqual(source.read_bytes(), raw)
        self.assertEqual(before, set(self.root.iterdir()))

    def test_partial_batch_and_repeat_no_overwrite(self):
        output = self.root / 'out'
        old, bad, current = [self.fixtures / name for name in ('dynamic-v7.json', 'duplicate-v7.json', 'current-v8.json')]
        args = ('--apply', '--output-dir', output)
        result = self.invoke(old, bad, current, extra=args)
        self.assertEqual(result.returncode, 1, result.stderr)
        rows = json.loads((output / 'upgrade-report.json').read_bytes())['files']
        self.assertEqual([r['status'] for r in rows], ['needsReview', 'failed', 'alreadyCurrent'])
        self.assertEqual({entry.name for entry in output.iterdir()}, {old.name, 'upgrade-report.json'})
        converted = (output / old.name).read_bytes()
        self.assertEqual(json.loads(converted)['schemaVersion'], 8)
        self.assertNotEqual(self.invoke(old, extra=args).returncode, 0)
        self.assertEqual((output / old.name).read_bytes(), converted)
        current_result = self.invoke(output / old.name)
        self.assertEqual(json.loads(current_result.stdout)['files'][0]['status'], 'alreadyCurrent')

    def test_collisions_and_unavailable_validator_fail_without_candidate(self):
        source = self.fixtures / 'film-v7.json'
        output = self.root / 'duplicate-output'
        result = self.invoke(source, source, extra=('--apply', '--output-dir', output))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual({p.name for p in output.iterdir()}, {'upgrade-report.json'})
        output = self.root / 'bad-validator'
        result = self.invoke(source, validator=str(self.root / 'missing'), extra=('--apply', '--output-dir', output))
        self.assertEqual(result.returncode, 1)
        self.assertEqual({p.name for p in output.iterdir()}, {'upgrade-report.json'})
        self.assertEqual(json.loads(result.stdout)['files'][0]['status'], 'failed')

    def test_unwritable_report_leaves_no_published_output(self):
        source = self.fixtures / 'film-v7.json'
        output = self.root / 'unpublished'
        result = self.invoke(source, extra=('--apply', '--output-dir', output, '--report', self.root / 'absent' / 'log.json'))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
