import sys, os, coremltools as ct

path = sys.argv[1]
spec = ct.models.MLModel(path, skip_model_load=True).get_spec()

print("=" * 60)
print("MODEL:", path)
print("=" * 60)

print("INPUTS:")
for i in spec.description.input:
    kind = i.type.WhichOneof("Type")
    extra = ""
    if kind == "imageType":
        it = i.type.imageType
        extra = f" W={it.width} H={it.height} colorspace={it.colorSpace}"
    elif kind == "multiArrayType":
        extra = f" shape={list(i.type.multiArrayType.shape)}"
    print("  ", i.name, kind, extra)

print("OUTPUTS:")
for o in spec.description.output:
    kind = o.type.WhichOneof("Type")
    extra = ""
    if kind == "multiArrayType":
        extra = f" shape={list(o.type.multiArrayType.shape)}"
    print("  ", o.name, kind, extra)

print("TOP-LEVEL TYPE:", spec.WhichOneof("Type"))

# Pipeline structure
top = spec.WhichOneof("Type")
if top in ("pipeline", "pipelineClassifier", "pipelineRegressor"):
    pipe = getattr(spec, top)
    print("PIPELINE STAGES:")
    for n, m in enumerate(pipe.models):
        print(f"  stage {n}: {m.WhichOneof('Type')}")
        if m.WhichOneof("Type") == "nonMaximumSuppression":
            nms = m.nonMaximumSuppression
            print("    NMS coordinatesOutput:", nms.coordinatesOutputFeatureName)
            print("    NMS confidenceOutput:", nms.confidenceOutputFeatureName)
            print("    NMS iouThreshold:", nms.iouThreshold)
            print("    NMS confidenceThreshold:", nms.confidenceThreshold)
            ssl = nms.stringClassLabels.vector
            print("    NMS class label count:", len(ssl))
            print("    NMS first 5 labels:", list(ssl[:5]))

try:
    md = {k: v for k, v in spec.description.metadata.userDefinedMetadata.items()}
except AttributeError:
    md = {}
print("METADATA keys:", list(md.keys()))
print("METADATA shortDescription:", spec.description.metadata.shortDescription[:80])
names = md.get("names")
if names:
    print("  names (first 120 chars):", names[:120])
    print("  names length:", len(names))
for k in ("task", "imgsz", "nms", "stride", "batch"):
    if k in md:
        print(f"  {k}: {md[k]}")

# file size
def dirsize(p):
    if os.path.isfile(p):
        return os.path.getsize(p)
    total = 0
    for root, _, files in os.walk(p):
        for f in files:
            total += os.path.getsize(os.path.join(root, f))
    return total

print("MLPACKAGE SIZE: %.2f MB" % (dirsize(path) / 1e6))
