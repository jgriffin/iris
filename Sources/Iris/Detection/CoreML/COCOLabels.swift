/// Canonical **COCO-80** class labels, in the standard
/// ultralytics / COCO detection order (index `0` = `"person"`, … index `79`
/// = `"toothbrush"`).
///
/// **Why this lives in Iris, supplied externally to the decoder.** A path-B
/// raw-tensor export (`YOLOEnd2EndDecoder`) emits a bare class *index* per
/// row and carries **no embedded label list** — the converted YOLO26n
/// `.mlpackage` reports `METADATA keys: []` (unlike a path-A
/// `NonMaximumSuppression` pipeline, which bakes the 80 COCO names into its
/// NMS stage so Vision can attach them). The class-index → string mapping
/// must therefore be supplied at decode time. `YOLOEnd2EndDecoder` takes a
/// `labels: [String]` at construction; the bundled YOLO26n catalog entry
/// passes ``COCOLabels/coco80`` here, while a downstream custom model passes
/// its own list. This keeps the decode *mechanics* (threshold, letterbox
/// inverse, row→`Detection`) decoupled from the *class set*.
///
/// The order is the ultralytics default `model.names` for COCO-pretrained
/// detectors — the same 80-class ordering YOLOv5/8/11/12/26 ship with, and
/// the same labels a path-A `nms=True` export bakes into its NMS stage. A
/// path-A and a path-B export of the same checkpoint therefore agree on
/// `labels[i]`.
public enum COCOLabels {

    /// The 80 COCO detection classes in canonical ultralytics index order.
    /// `coco80[Int(classIndex)]` maps a raw YOLO class index to its name.
    public static let coco80: [String] = [
        "person",
        "bicycle",
        "car",
        "motorcycle",
        "airplane",
        "bus",
        "train",
        "truck",
        "boat",
        "traffic light",
        "fire hydrant",
        "stop sign",
        "parking meter",
        "bench",
        "bird",
        "cat",
        "dog",
        "horse",
        "sheep",
        "cow",
        "elephant",
        "bear",
        "zebra",
        "giraffe",
        "backpack",
        "umbrella",
        "handbag",
        "tie",
        "suitcase",
        "frisbee",
        "skis",
        "snowboard",
        "sports ball",
        "kite",
        "baseball bat",
        "baseball glove",
        "skateboard",
        "surfboard",
        "tennis racket",
        "bottle",
        "wine glass",
        "cup",
        "fork",
        "knife",
        "spoon",
        "bowl",
        "banana",
        "apple",
        "sandwich",
        "orange",
        "broccoli",
        "carrot",
        "hot dog",
        "pizza",
        "donut",
        "cake",
        "chair",
        "couch",
        "potted plant",
        "bed",
        "dining table",
        "toilet",
        "tv",
        "laptop",
        "mouse",
        "remote",
        "keyboard",
        "cell phone",
        "microwave",
        "oven",
        "toaster",
        "sink",
        "refrigerator",
        "book",
        "clock",
        "vase",
        "scissors",
        "teddy bear",
        "hair drier",
        "toothbrush",
    ]
}
