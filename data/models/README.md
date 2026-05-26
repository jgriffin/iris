# Models

Regenerable model artifacts — **gitignored, safe to delete**. Nothing in
`weights/` or `coreml/` is committed; everything here can be reproduced from
source weights via the export tooling.

## Layout

- `weights/` — downloaded PyTorch source checkpoints (`*.pt`, e.g. `yolo11n.pt`).
- `coreml/` — converted Core ML models (`*.mlpackage`) ready to drop into Iris.

## How to (re)generate these

The download + Core ML conversion process lives in the export tooling, not here.
See the runbook:

→ [`tools/model-export/RUNBOOK.md`](../../tools/model-export/RUNBOOK.md)

In short: the runbook's `uv`-based recipe downloads the source weights and
exports them to Core ML, writing into `weights/` and `coreml/` in this directory.

## Shipping a model

Models we actually ship — bundled in a demo app, or used as test fixtures — get
**promoted** out of this scratch area into the app bundle or
`Tests/IrisTests/Fixtures/` and tracked via Git LFS (see the runbook). This
directory stays the regenerable working area, not the source of truth for any
committed model.
