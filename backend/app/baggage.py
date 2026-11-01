"""Lost luggage: checked bags that didn't arrive on the belt (delayed) or arrived damaged.

A passenger files a report with the bag tag number(s) from their boarding pass; the baggage
desk registers unclaimed bags ("on hand"). Bags and reports are matched on the tag number
first (exact match = same bag), then on flight, name on the bag, type, colour and photo.
The file then moves through desk events: located -> forwarded -> arrived -> out for delivery /
ready for pickup -> delivered (or declared lost after the search ends)."""
from __future__ import annotations

import re
from datetime import date

from . import matching

BAG_TYPES = ["suitcase", "soft_bag", "backpack", "stroller", "sports", "box", "other"]
AI_TO_BAG = {"suitcase": "suitcase", "backpack": "backpack", "handbag": "soft_bag", "sports": "sports"}

# Desk events and the status each one moves the file to ("note" keeps the status).
EVENT_STATUS = {
    "reported": "reported",
    "found_here": "arrived",  # an unclaimed bag at this airport was matched to the report
    "located": "located",  # found at another airport
    "forwarded": "forwarded",  # put on a flight to this airport
    "arrived": "arrived",
    "out_for_delivery": "out_for_delivery",
    "ready_for_pickup": "ready_for_pickup",
    "delivered": "delivered",
    "declared_lost": "declared_lost",
    "note": None,
}
STAFF_EVENTS = {"located", "forwarded", "arrived", "out_for_delivery", "ready_for_pickup", "declared_lost", "note"}
HANDOVER = {"out_for_delivery", "ready_for_pickup"}
CLOSED = {"delivered", "declared_lost"}

# Passenger notification for each event: (title, body); {ref} {airport} {station} {flight} {eta} filled in.
MESSAGES = {
    "reported": ("Bag report received", "File {ref}: we're looking for your bag."),
    "found_here": ("Your bag is here!", "Your bag was found at {airport}."),
    "located": ("Bag located", "Your bag was found at {station}."),
    "forwarded": ("Your bag is on its way", "It's on flight {flight}{eta}."),
    "arrived": ("Your bag has arrived", "Your bag is at {airport}. We'll get it to you soon."),
    "out_for_delivery": ("Out for delivery", "Your bag is on its way to you. Show your delivery code to the driver."),
    "ready_for_pickup": ("Ready for pickup", "Collect your bag at the baggage service desk with your delivery code."),
    "delivered": ("Bag delivered", "You and your bag are back together. Enjoy your stay!"),
    "declared_lost": ("Bag declared lost", "We're sorry. You can now claim compensation from the airline."),
}


def normalize_tag(raw: str) -> str | None:
    """Bag tag number as printed (10 digits, or airline code + 6 digits), without spaces/dashes."""
    tag = re.sub(r"[^A-Z0-9]", "", raw.upper())
    return tag if 6 <= len(tag) <= 10 else None


def parse_tags(raw: str | None) -> list[str]:
    """Tag numbers separated by commas, semicolons or new lines. Raises ValueError on a bad one."""
    tags = []
    for part in re.split(r"[,;\n]+", raw or ""):
        if not part.strip():
            continue
        tag = normalize_tag(part)
        if not tag:
            raise ValueError(f"'{part.strip()}' is not a bag tag number (6 to 10 letters or digits)")
        tags.append(tag)
    return list(dict.fromkeys(tags))


def normalize_flight(raw: str | None) -> str | None:
    flight = re.sub(r"\s+", "", (raw or "").upper())
    return flight or None


def _words(s: str | None) -> set[str]:
    return {w for w in re.findall(r"[a-z]+", (s or "").lower()) if len(w) > 1}


def _name_score(a: str | None, b: str | None) -> float | None:
    wa, wb = _words(a), _words(b)
    if not wa or not wb:
        return None
    return len(wa & wb) / min(len(wa), len(wb))


def _days_apart(a: str | None, b: str | None) -> int | None:
    try:
        return abs((date.fromisoformat(a[:10]) - date.fromisoformat(b[:10])).days)
    except (TypeError, ValueError):
        return None


WEIGHTS = {"tag": 0.35, "flight": 0.2, "name": 0.2, "type": 0.1, "color": 0.1, "visual": 0.05}


def score(report: dict, bag: dict) -> tuple[float, dict]:
    """How likely an unclaimed bag is the reported one (0..1)."""
    tags = set(report.get("tagNumbers") or [])
    tag = bag.get("tagNumber")
    if tag and tag in tags:
        return 1.0, {"tag": 1.0}
    signals: dict[str, float | None] = {k: None for k in WEIGHTS}
    if tag and tags:
        # Same 6-digit serial: the airline prefix was misread or typed differently.
        if not any(t[-6:] == tag[-6:] for t in tags):
            return 0.0, {**signals, "tag": 0.0}  # both tagged, different tags: another bag
        signals["tag"] = 0.8
    days = _days_apart(report.get("flightDate"), (bag.get("timestamp") or "")[:10])
    if days is not None and days > 3:
        return 0.0, signals
    if report.get("flight") and bag.get("flight"):
        signals["flight"] = 1.0 if report["flight"] == bag["flight"] else 0.0
    signals["name"] = _name_score(report.get("nameOnTag") or report.get("passengerName"), bag.get("nameOnTag"))
    if report.get("bagType") and bag.get("bagType"):
        signals["type"] = 1.0 if report["bagType"] == bag["bagType"] else 0.0
    signals["color"] = matching._color_score(report.get("color"), bag.get("color"))
    signals["visual"] = matching._visual_score(report.get("embedding"), bag.get("embedding"))
    present = {k: v for k, v in signals.items() if v is not None}
    if not present:
        return 0.0, signals
    covered = sum(WEIGHTS[k] for k in present)
    s = sum(WEIGHTS[k] * v for k, v in present.items()) / covered
    # Type and colour alone say little: scale down until enough evidence is there.
    return round(s * min(1.0, covered / 0.5), 3), signals


def as_case(report: dict) -> dict:
    """A baggage report shaped like a lost-item report, for the shared live chat."""
    category = {"backpack": "backpack", "soft_bag": "handbag"}.get(report.get("bagType") or "", "suitcase")
    return {
        "id": report["id"], "userId": report["userId"], "airport": report.get("airport"), "ref": report.get("ref"),
        "kind": "baggage", "description": report.get("marks") or "", "category": category,
        "color": report.get("color"), "timestamp": report["timestamp"], "status": report["status"],
        "matchedItemId": None, "route": [],
    }
