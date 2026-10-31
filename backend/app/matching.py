"""Auto-match between passenger lost reports and staff found items.

The score is a weighted average of the signals both sides actually have:
category, color, visual embedding (reverse image search), free text and location."""
from __future__ import annotations

import re

import numpy as np

RELATED_CATEGORIES = [
    {"backpack", "handbag", "suitcase", "wallet"},
    {"phone", "laptop", "electronics", "headphones", "camera"},
    {"clothing", "shoes"},
    {"watch", "jewelry", "glasses"},
]

SIMILAR_COLORS = [
    {"blue", "navy", "purple"},
    {"black", "gray", "navy"},
    {"white", "beige", "gray"},
    {"brown", "beige", "orange"},
    {"red", "pink", "orange"},
    {"yellow", "orange", "beige"},
]

WEIGHTS = {"category": 0.35, "color": 0.2, "visual": 0.3, "text": 0.1, "location": 0.05}

_WORD = re.compile(r"[a-z0-9]{3,}")


def _related(a: str, b: str, groups: list[set[str]]) -> bool:
    return any(a in g and b in g for g in groups)


def _category_score(a: str | None, b: str | None) -> float | None:
    if not a or not b:
        return None
    a, b = a.lower(), b.lower()
    if a == b:
        return 1.0
    return 0.4 if _related(a, b, RELATED_CATEGORIES) else 0.0


def _color_score(a: str | None, b: str | None) -> float | None:
    if not a or not b:
        return None
    a, b = a.lower(), b.lower()
    if a == b:
        return 1.0
    return 0.5 if _related(a, b, SIMILAR_COLORS) else 0.0


def cosine(a, b) -> float:
    a, b = np.asarray(a, dtype=np.float32), np.asarray(b, dtype=np.float32)
    if a.shape != b.shape:
        return 0.0
    denom = np.linalg.norm(a) * np.linalg.norm(b)
    return float(a @ b / denom) if denom else 0.0


def _visual_score(a, b) -> float | None:
    if not a or not b:
        return None
    # YOLO features of unrelated objects still have cosine ~0.4; stretch the useful range.
    return float(np.clip((cosine(a, b) - 0.4) / 0.5, 0, 1))


def _text_score(description: str | None, item: dict) -> float | None:
    words = set(_WORD.findall((description or "").lower()))
    if not words:
        return None
    haystack = " ".join(str(item.get(k) or "") for k in ("text", "label", "notes", "category", "color")).lower()
    item_words = set(_WORD.findall(haystack))
    if not item_words:
        return None
    return min(1.0, len(words & item_words) / 3)


def _location_score(a: str | None, b: str | None) -> float | None:
    if not a or not b:
        return None
    return 1.0 if a.lower() == b.lower() else 0.0


def score(report: dict, item: dict) -> tuple[float, dict]:
    signals = {
        "category": _category_score(report.get("category"), item.get("category")),
        "color": _color_score(report.get("color"), item.get("color")),
        "visual": _visual_score(report.get("embedding"), item.get("embedding")),
        "text": _text_score(report.get("description"), item),
        "location": _location_score(report.get("lastSeenLocation"), item.get("location")),
    }
    available = {k: v for k, v in signals.items() if v is not None}
    if not available:
        return 0.0, signals
    # A category mismatch is a strong veto: a black laptop is not a black backpack.
    if signals["category"] == 0.0 and (signals["visual"] or 0) < 0.8:
        return 0.0, signals
    total_w = sum(WEIGHTS[k] for k in available)
    value = sum(WEIGHTS[k] * v for k, v in available.items()) / total_w
    return round(value, 3), {k: (round(v, 3) if v is not None else None) for k, v in signals.items()}


def rank(report: dict, items: list[dict], limit: int = 10, min_score: float = 0.0) -> list[dict]:
    scored = []
    for item in items:
        s, breakdown = score(report, item)
        if s >= min_score:
            scored.append({"score": s, "breakdown": breakdown, "item": item})
    scored.sort(key=lambda m: m["score"], reverse=True)
    return scored[:limit]
