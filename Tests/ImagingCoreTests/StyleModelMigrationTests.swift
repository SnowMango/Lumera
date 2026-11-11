import XCTest
@testable import ImagingCore

final class StyleModelMigrationTests: XCTestCase {
    func testOriginalV032FixtureDigest() throws {
        let bytes = Data(Self.originalV032.utf8)
        XCTAssertEqual(try StyleModelCodec.persistedModelDigest(bytes), "ea3d2e5cade12d73683839a8fa081a1ffec60a6274cfb16c6948500fd14f59d6")
        let model = try StyleModelCodec.decode(bytes)
        XCTAssertEqual(model.identity.metadata["firmware"], "1.2")
        XCTAssertEqual(model.identity.metadata["settings.contrast"], "low")
        XCTAssertEqual(model.identity.name, "Reference Soft")
    }
    private static let originalV032 = #"""
{
  "adaptation" : {
    "rules" : [

    ]
  },
  "appearance" : {
    "lutWeights" : [

    ],
    "parameters" : {
      "color" : {
        "exposureEV" : 0,
        "matrix" : {
          "values" : [
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            1
          ]
        },
        "shift" : {
          "redGreen" : 0,
          "yellowBlue" : 0
        },
        "whiteBalance" : {
          "destination" : {
            "x" : 0.3127,
            "y" : 0.329
          },
          "source" : {
            "x" : 0.3127,
            "y" : 0.329
          }
        }
      },
      "detail" : {
        "enabled" : false,
        "fineGain" : 1,
        "fineSigma" : 0.75,
        "maxAdjustment" : 0.015,
        "midGain" : 1,
        "midSigma" : 2.5,
        "sharpenAmount" : 0,
        "sharpenSigma" : 0.8,
        "threshold" : 0.008
      },
      "glow" : {
        "amount" : 0,
        "enabled" : false,
        "farSigma" : 14,
        "farWeight" : 0.25,
        "knee" : 0.15,
        "nearSigma" : 3,
        "threshold" : 0.7
      },
      "grain" : {
        "amount" : 0,
        "chroma" : 0.15,
        "enabled" : false,
        "luminanceCurve" : {
          "shape" : {
            "function" : {
              "_0" : {
                "center" : 0.5,
                "end" : 1,
                "exponent" : 2,
                "family" : "bell",
                "start" : 0,
                "width" : 0.25,
                "xLower" : 0,
                "xUpper" : 1
              }
            }
          }
        },
        "roughness" : 0.35,
        "size" : 1
      },
      "halation" : {
        "amount" : 0,
        "blue" : 0.04,
        "enabled" : false,
        "green" : 0.2,
        "knee" : 0.15,
        "radius" : 4,
        "red" : 1,
        "threshold" : 0.7
      },
      "noise" : {
        "chromaCorrelation" : 0,
        "chromaRatio" : 0.15,
        "chromaSigma" : 1.3,
        "curve" : {
          "shape" : {
            "function" : {
              "_0" : {
                "center" : 0.5,
                "end" : 0,
                "exponent" : 2,
                "family" : "constant",
                "start" : 0,
                "width" : 0.25,
                "xLower" : 0,
                "xUpper" : 1
              }
            }
          }
        },
        "enabled" : false,
        "gain" : 1,
        "lumaSigma" : 0.65
      },
      "softening" : {
        "amount" : 0,
        "enabled" : false,
        "sigma" : 1.5
      },
      "tone" : {
        "curve" : {
          "shape" : {
            "function" : {
              "_0" : {
                "center" : 0.5,
                "end" : 1,
                "exponent" : 2,
                "family" : "linear",
                "start" : 0,
                "width" : 0.25,
                "xLower" : 0,
                "xUpper" : 1
              }
            }
          }
        },
        "enabled" : false
      },
      "vignette" : {
        "amountEV" : 0,
        "centerX" : 0.5,
        "centerY" : 0.5,
        "enabled" : false,
        "falloff" : 1.5,
        "startRadius" : 0.35
      }
    },
    "resources" : [

    ],
    "temporalPolicy" : {
      "grain" : "evolving",
      "noise" : "fixed"
    }
  },
  "compatibility" : {
    "dynamicRanges" : [
      "sdr"
    ],
    "referenceRenditionIDs" : [

    ],
    "requiredCapabilities" : [

    ],
    "requiredQualifications" : [

    ],
    "targetConditions" : [

    ]
  },
  "coverage" : {
    "conditions" : [

    ],
    "evidenceDigests" : [

    ]
  },
  "edits" : {
    "allowsInputExposure" : true,
    "allowsInputWhiteBalance" : true,
    "overrideTargets" : [

    ],
    "visualControls" : [

    ]
  },
  "identity" : {
    "camera" : "Reference",
    "firmware" : "1.2",
    "id" : "legacy-style",
    "mode" : "Soft",
    "settings" : {
      "contrast" : "low"
    }
  },
  "observations" : {
    "features" : [

    ],
    "sourceConditions" : [

    ],
    "validity" : {
      "maxAgeFrames" : 0,
      "maxAgeSeconds" : 0,
      "rejectMissingSourceConditions" : true,
      "sourceChangeTolerances" : [

      ]
    }
  },
  "parameterSemanticsVersion" : 1,
  "responseSemanticsVersion" : 1,
  "responses" : [

  ],
  "schemaVersion" : 1
}
"""#
    func legacyFixture() throws -> Data {
        var tree = try XCTUnwrap(JSONSerialization.jsonObject(with: StyleModelCodec.encode(StyleModel(identity: .init(id: "film", name: "Film")))) as? [String: Any])
        tree["schemaVersion"] = 1
        tree["identity"] = ["id": "film", "camera": "Legacy camera", "mode": "Soft", "firmware": "1.2", "settings": ["contrast": "low"]]
        return try JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys])
    }
    func testLegacyOriginalSemanticDigestAndMigration() throws {
        let bytes = try legacyFixture()
        let originalTree = try JSONDecoder().decode(ProfileValue.self, from: bytes)
        XCTAssertEqual(try StyleModelCodec.persistedModelDigest(bytes), try StyleIdentity.digest(originalTree))
        let migrated = try StyleModelCodec.decode(bytes)
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.identity.name, "Legacy camera Soft")
        XCTAssertEqual(migrated.identity.metadata, ["camera": "Legacy camera", "mode": "Soft", "firmware": "1.2", "settings.contrast": "low"])
        XCTAssertNotEqual(try migrated.digest(), try StyleModelCodec.persistedModelDigest(bytes))
        let encoded = try StyleModelCodec.encode(migrated)
        let tree = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let identity = try XCTUnwrap(tree["identity"] as? [String: Any])
        XCTAssertEqual(Set(identity.keys), ["id", "name", "metadata"])
        XCTAssertEqual(try StyleModelCodec.persistedModelDigest(encoded), try migrated.digest())
        XCTAssertEqual(try StyleModelCodec.decode(encoded).appearance, migrated.appearance)
    }
    func testIdentityFieldsMustMatchPersistedVersion() throws {
        var tree = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyFixture()) as? [String: Any])
        tree["schemaVersion"] = 2
        XCTAssertThrowsError(try StyleModelCodec.decode(JSONSerialization.data(withJSONObject: tree)))
        tree["schemaVersion"] = 1
        var identity = try XCTUnwrap(tree["identity"] as? [String: Any])
        identity["name"] = "Ignored by the legacy semantic identity"
        tree["identity"] = identity
        XCTAssertThrowsError(try StyleModelCodec.persistedModelDigest(JSONSerialization.data(withJSONObject: tree)))
    }
    func testGenericModelNeedsOnlyIDAndName() throws {
        let model = StyleModel(identity: .init(id: "art", name: "Illustrated summer"))
        XCTAssertNoThrow(try model.validate())
        XCTAssertEqual(try StyleModelCodec.decode(StyleModelCodec.encode(model)), model)
        let identity = try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(model.identity)) as? [String: Any])
        XCTAssertEqual(Set(identity.keys), ["id", "name"])
    }
}
