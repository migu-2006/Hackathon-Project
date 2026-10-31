"""AI engine for Smart Intake: object type, dominant color, visible text and an embedding.

Pipeline:
  1. YOLO detection (COCO) finds the main object and crops it (people / furniture are ignored).
  2. YOLO classification (ImageNet) on the crop refines the label (e.g. wallet, sunglasses) and
     produces the feature vector used for reverse image search.
  3. K-means on the crop pixels gives the dominant color, mapped to a human-readable name.
  4. Optional EasyOCR reads brand / visible text.
"""
from __future__ import annotations

import colorsys
import logging
from dataclasses import dataclass, field
from functools import lru_cache

import numpy as np
from PIL import Image

from . import config

log = logging.getLogger(__name__)

# COCO detection classes that make sense as lost items -> app category.
COCO_TO_CATEGORY = {
    "backpack": "backpack",
    "handbag": "handbag",
    "suitcase": "suitcase",
    "umbrella": "umbrella",
    "cell phone": "phone",
    "laptop": "laptop",
    "book": "book",
    "bottle": "bottle",
    "cup": "cup",
    "teddy bear": "toy",
    "keyboard": "electronics",
    "mouse": "electronics",
    "remote": "electronics",
    "tie": "clothing",
    "clock": "watch",
    "scissors": "other",
    "sports ball": "toy",
    "skateboard": "sports",
    "tennis racket": "sports",
    "frisbee": "toy",
}

# Keywords in ImageNet labels -> app category (first match wins).
IMAGENET_KEYWORDS = [
    (("wallet", "purse"), "wallet"),
    (("backpack",), "backpack"),
    (("mailbag", "handbag", "shopping basket"), "handbag"),
    (("suitcase", "luggage"), "suitcase"),
    (("cellular telephone", "cellphone", "dial telephone", "ipod"), "phone"),
    (("laptop", "notebook", "computer keyboard", "desktop computer"), "laptop"),
    (("sunglass",), "glasses"),
    (("umbrella",), "umbrella"),
    (("water bottle", "pop bottle", "water jug", "beer bottle", "wine bottle"), "bottle"),
    (("digital watch", "analog clock", "stopwatch", "wall clock"), "watch"),
    (("jersey", "cardigan", "sweatshirt", "trench coat", "fur coat", "suit", "jean", "sock", "cowboy hat", "sombrero", "bonnet"), "clothing"),
    (("running shoe", "sandal", "clog", "loafer", "cowboy boot", "boot"), "shoes"),
    (("headphone", "earphone", "earbud"), "headphones"),
    (("reflex camera", "polaroid camera", "camera"), "camera"),
    (("teddy", "toy"), "toy"),
    (("book", "binder", "comic book"), "book"),
    (("key",), "keys"),
    (("necklace", "chain", "ring"), "jewelry"),
]

IGNORED_COCO = {"person", "chair", "bench", "dining table", "couch", "bed", "tv", "potted plant", "toilet", "sink"}

# Reference colors for naming the dominant color.
NAMED_COLORS = {
    "black": (20, 20, 20),
    "white": (240, 240, 240),
    "gray": (128, 128, 128),
    "red": (200, 30, 30),
    "orange": (240, 140, 20),
    "yellow": (240, 220, 40),
    "green": (40, 160, 60),
    "blue": (30, 70, 200),
    "navy": (20, 30, 90),
    "purple": (120, 50, 160),
    "pink": (240, 130, 180),
    "brown": (120, 75, 40),
    "beige": (215, 195, 160),
}


@dataclass
class Analysis:
    category: str
    label: str
    confidence: float
    color: str
    color_rgb: tuple[int, int, int]
    text: str
    bbox: list[float] | None
    embedding: list[float] = field(repr=False)

    def public(self) -> dict:
        return {
            "category": self.category,
            "label": self.label,
            "confidence": round(self.confidence, 3),
            "color": self.color,
            "colorHex": "#%02x%02x%02x" % self.color_rgb,
            "text": self.text,
            "bbox": self.bbox,
        }


@lru_cache(maxsize=1)
def _detector():
    from ultralytics import YOLO

    return YOLO(config.DETECT_MODEL)


@lru_cache(maxsize=1)
def _classifier():
    from ultralytics import YOLO

    return YOLO(config.CLASSIFY_MODEL)


@lru_cache(maxsize=1)
def _ocr_reader():
    if not config.ENABLE_OCR:
        return None
    try:
        import easyocr

        return easyocr.Reader(["en"], gpu=False)
    except Exception as exc:  # easyocr not installed or failed to load
        log.warning("OCR disabled: %s", exc)
        return None


def warmup() -> None:
    _detector()
    _classifier()
    _ocr_reader()


def _detect_main_object(img: Image.Image) -> tuple[str | None, str | None, float, list[float] | None]:
    """Return (category, coco_name, confidence, bbox) of the most prominent relevant object."""
    result = _detector()(img, verbose=False)[0]
    best = None
    w, h = img.size
    for cls_id, conf, xyxy in zip(result.boxes.cls.tolist(), result.boxes.conf.tolist(), result.boxes.xyxy.tolist()):
        name = result.names[int(cls_id)]
        if name in IGNORED_COCO or conf < 0.25:
            continue
        area = (xyxy[2] - xyxy[0]) * (xyxy[3] - xyxy[1]) / (w * h)
        score = conf * (0.5 + area)  # prefer confident, large objects
        if best is None or score > best[0]:
            best = (score, COCO_TO_CATEGORY.get(name, "other"), name, conf, xyxy)
    if best is None:
        return None, None, 0.0, None
    return best[1], best[2], best[3], [round(v, 1) for v in best[4]]


def _classify(crop: Image.Image) -> tuple[str | None, str, float]:
    result = _classifier()(crop, verbose=False)[0]
    probs = result.probs
    for idx, conf in zip(probs.top5, probs.top5conf.tolist()):
        label = result.names[int(idx)].replace("_", " ").lower()
        for keywords, category in IMAGENET_KEYWORDS:
            if any(k in label for k in keywords):
                return category, label, conf
    top = result.names[int(probs.top1)].replace("_", " ").lower()
    return None, top, float(probs.top1conf)


def _embed(crop: Image.Image) -> np.ndarray:
    try:
        vec = _classifier().embed(crop, verbose=False)[0].cpu().numpy().astype(np.float32).ravel()
    except Exception as exc:
        log.warning("YOLO embed failed, using color histogram: %s", exc)
        hist = np.histogramdd(
            np.asarray(crop.resize((64, 64))).reshape(-1, 3), bins=(8, 8, 8), range=[(0, 256)] * 3
        )[0]
        vec = hist.ravel().astype(np.float32)
    norm = np.linalg.norm(vec)
    return vec / norm if norm else vec


def dominant_color(crop: Image.Image, k: int = 4) -> tuple[str, tuple[int, int, int]]:
    """K-means over the central region of the crop; returns the biggest cluster's name and RGB."""
    small = crop.convert("RGB").resize((80, 80))
    arr = np.asarray(small, dtype=np.float32)
    arr = arr[10:70, 10:70].reshape(-1, 3)  # skip borders, which are usually background
    rng = np.random.default_rng(0)
    centers = arr[rng.choice(len(arr), k, replace=False)]
    for _ in range(10):
        labels = np.argmin(((arr[:, None, :] - centers[None]) ** 2).sum(-1), axis=1)
        for i in range(k):
            members = arr[labels == i]
            if len(members):
                centers[i] = members.mean(0)
    counts = np.bincount(labels, minlength=k)
    rgb = tuple(int(c) for c in centers[int(np.argmax(counts))])
    return color_name(rgb), rgb


def color_name(rgb: tuple[int, int, int]) -> str:
    r, g, b = (c / 255 for c in rgb)
    _, light, sat = colorsys.rgb_to_hls(r, g, b)
    # Low saturation colors are best described by lightness alone.
    if sat < 0.15 or light < 0.12 or light > 0.92:
        if light < 0.22:
            return "black"
        if light > 0.85:
            return "white"
        return "gray"
    return min(
        (n for n in NAMED_COLORS if n not in ("black", "white", "gray")),
        key=lambda n: sum((a - b) ** 2 for a, b in zip(rgb, NAMED_COLORS[n])),
    )


def _read_text(crop: Image.Image) -> str:
    reader = _ocr_reader()
    if reader is None:
        return ""
    lines = reader.readtext(np.asarray(crop.convert("RGB")), detail=1)
    return " ".join(text for _, text, conf in lines if conf > 0.4).strip()


def analyze(img: Image.Image) -> Analysis:
    img = img.convert("RGB")
    det_category, det_name, det_conf, bbox = _detect_main_object(img)
    crop = img.crop(tuple(bbox)) if bbox else img

    cls_category, label, cls_conf = _classify(crop)
    # Fine-grained ImageNet categories (wallet, glasses, keys...) beat generic COCO ones.
    if cls_category and (det_category in (None, "other") or cls_conf > det_conf):
        category, confidence = cls_category, cls_conf
    elif det_category:
        category, confidence, label = det_category, det_conf, det_name
    else:
        category, confidence = "other", cls_conf

    color, rgb = dominant_color(crop)
    return Analysis(
        category=category,
        label=label,
        confidence=float(confidence),
        color=color,
        color_rgb=rgb,
        text=_read_text(crop),
        bbox=bbox,
        embedding=_embed(crop).tolist(),
    )
