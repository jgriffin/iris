# model-export

Python tooling to convert external PyTorch object-detection models (YOLO, etc.)
into Core ML `.mlpackage`s for use in Iris as a `CoreMLDetector`. **Separate from
the Swift package** — it is never a SwiftPM dependency.

- **[`RUNBOOK.md`](./RUNBOOK.md)** — the durable, verified procedure (the blessed
  `uv run` one-liner, the load-bearing pins, the path-A/path-B decode fork, the
  "add the next model" checklist). Start here.
- **`inspect_model.py`** — dumps a converted `.mlpackage`'s inputs/outputs/labels
  so you can confirm which decode path you got before wiring it into Iris.

Background and design rationale live in
[`explorations/2026-05-25-coreml-model-conversion/`](../../explorations/2026-05-25-coreml-model-conversion/)
(`SYNTHESIS.md`, `RECOMMENDATIONS.md`). Converted artifacts land under
[`data/models/`](../../data/models/) and are gitignored.
