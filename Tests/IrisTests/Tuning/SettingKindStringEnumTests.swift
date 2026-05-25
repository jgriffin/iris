import Testing

@testable import Iris

// MARK: - Test goal
//
// M5 adds `SettingKind.string` + `.enum` and a `SettingChange.string`
// payload (the Vision capability audit surfaced text / symbology knobs).
// Wave 1 wires them through the model/schema layer only — no UI yet.
// These tests pin that the new kinds exist in a schema and that a
// string-backed knob round-trips through `TuningModel.update(_:to:)`
// into a `SettingChange.string` payload.

// MARK: - A settings type exercising .string and .enum

/// Minimal settings type carrying one free-form string knob and one
/// enum (single-choice) knob — both backed by a `String` property, as
/// the new `SettingKind` variants intend.
private struct TextSettings: DetectorSettings {
    var customWord: String = ""
    var recognitionLevel: String = "fast"

    static var schema: SettingSchema {
        SettingSchema(knobs: [
            SettingSchema.Knob(
                key: "customWord",
                label: "Custom word",
                kind: .string(default: ""),
                tier: .detector
            ),
            SettingSchema.Knob(
                key: "recognitionLevel",
                label: "Recognition level",
                kind: .enum(options: ["fast", "accurate"], default: "fast"),
                tier: .detector
            ),
        ])
    }

    static func key(for keyPath: PartialKeyPath<Self>) -> String? {
        switch keyPath {
        case \Self.customWord: return "customWord"
        case \Self.recognitionLevel: return "recognitionLevel"
        default: return nil
        }
    }
}

// MARK: - Schema carries the new kinds

@Test
func schemaCarriesStringAndEnumKinds() {
    let schema = TextSettings.schema
    let byKey = Dictionary(uniqueKeysWithValues: schema.knobs.map { ($0.key, $0.kind) })

    guard case .string(let def)? = byKey["customWord"] else {
        Issue.record("customWord should be .string")
        return
    }
    #expect(def == "")

    guard case .enum(let options, let enumDefault)? = byKey["recognitionLevel"] else {
        Issue.record("recognitionLevel should be .enum")
        return
    }
    #expect(options == ["fast", "accurate"])
    #expect(enumDefault == "fast")
}

// MARK: - SettingChange.string builder round-trip

@Test
func settingChangeStringBuilderProducesStringPayload() {
    let change = SettingChange.string(key: "customWord", from: "old", to: "new")
    #expect(change.oldValue == .string("old"))
    #expect(change.newValue == .string("new"))
    #expect(change.key == "customWord")
}

// MARK: - TuningModel routes a String knob through .string payload

@Test
@MainActor
func tuningModelEncodesStringKnobAsStringChange() {
    // A detector-less TuningModel still builds the SettingChange from
    // the keyPath write — this exercises `buildChange`'s new String arm
    // without needing a classifier. `lastChange` exposes the encoded
    // payload.
    let model = TuningModel<NoOpTextDetector>(settings: TextSettings())

    model.update(\.customWord, to: "invoice")

    let change = model.lastChange
    #expect(change?.key == "customWord")
    #expect(change?.oldValue == .string(""))
    #expect(change?.newValue == .string("invoice"))
}

@Test
@MainActor
func tuningModelEncodesEnumKnobAsStringChange() {
    // `.enum` is also a String at the property; it encodes to the same
    // `.string` payload (the schema is what distinguishes free-form vs.
    // constrained, not the change payload).
    let model = TuningModel<NoOpTextDetector>(settings: TextSettings())

    model.update(\.recognitionLevel, to: "accurate")

    let change = model.lastChange
    #expect(change?.key == "recognitionLevel")
    #expect(change?.oldValue == .string("fast"))
    #expect(change?.newValue == .string("accurate"))
}

// MARK: - Minimal detector to parameterize the generic TuningModel

/// `TunableDetector` whose only job is to let `TuningModel<NoOpTextDetector>`
/// type-check in the detector-less init path. `apply(_:)` is never
/// invoked in these tests (the model is constructed via `init(settings:)`,
/// so `detector` is nil and the classifier is skipped).
private struct NoOpTextDetector: TunableDetector {
    typealias Settings = TextSettings

    let settings = TextSettings()
    let availability: DetectorAvailability = .available
    let modelIdentifier = "noop.text"

    var capabilities: DetectorCapabilities {
        DetectorCapabilities(
            geometryKinds: [.box],
            confidence: .perElement,
            tunableKnobs: TextSettings.schema,
            introspectableFields: [
                DetectorCapabilities.IntrospectableField(
                    key: "label",
                    displayName: "Label",
                    valueKind: .label,
                    source: .label
                )
            ]
        )
    }

    func prewarm() async {}
    func detect(in _: Frame) async throws -> [Detection] { [] }
    func apply(_ change: SettingChange) -> ApplyResult { .view }
}
