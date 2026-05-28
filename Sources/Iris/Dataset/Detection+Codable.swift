// MARK: - Detection serialization decision (M7·P1)
//
// M7·P1 needs `Detection` (and its nested `Keypoint` / `Mask` / `Skeleton` /
// `Readout` types) to be `Codable` so a flagged frame can persist the model's
// predicted detections in the on-disk flag record.
//
// DECISION: **direct synthesized `Codable` conformance, no DTO.**
//
// The M7 doc (Opens · "Detection Codable churn") flagged that the
// self-describing `skeleton` / `readout` fields *might* make a clean `Codable`
// conformance awkward and that a `DetectionRecord` DTO could be the cleaner
// seam. Inspecting the actual types settles it the other way:
//
//   - Every field is a plain value type with synthesizable `Codable`:
//     `CGRect`, `String`, `Float`, `[Keypoint]?`, `Mask?`, `Skeleton?`,
//     `Readout?`. `CGRect` / `CGPoint` carry Foundation `Codable` already.
//   - `skeleton` and `readout` are *self-describing* but still flat structs
//     (`[Edge]` of `{from, to}` strings; `{label, text}` strings). There is
//     no polymorphism or type-erasure to encode — the thing that usually
//     forces a DTO. Synthesized `Codable` captures them losslessly.
//   - A DTO would duplicate the entire field set for zero schema benefit and
//     add a hand-maintained mapping layer that drifts from `Detection`.
//
// IMPLEMENTATION NOTE: Swift only *synthesizes* `Codable` when the conformance
// is declared on the type itself, in the same file — a retroactive cross-file
// `extension … : Codable {}` does NOT get synthesis (compiler: "extension
// outside of file declaring struct … prevents automatic synthesis"). So the
// `: Codable` conformances are declared on the type declarations in
// `Sources/Iris/Detection/{Detection,Skeleton,Readout}.swift`; this file is the
// single place the *rationale* lives, co-located with the dataset consumer that
// motivated it. Keeping the rationale here (not the conformance) preserves the
// "decision lives next to its consumer" intent without fighting the compiler.
//
// TRIPWIRE: `Mask` carries only `width` / `height` today (its pixel payload is
// a `TODO M2+:` placeholder). When that payload lands it must stay `Codable`
// or `Detection`'s synthesized conformance breaks at compile time — a
// deliberate, useful failure.
