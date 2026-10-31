import json
import os
from functools import lru_cache
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = Path(os.getenv("LF_DATA_DIR", BASE_DIR / "data"))
IMAGES_DIR = DATA_DIR / "images"
DB_PATH = DATA_DIR / "lostfound.db"

# Ultralytics weights are downloaded automatically on first use.
DETECT_MODEL = os.getenv("LF_DETECT_MODEL", "yolo11n.pt")
CLASSIFY_MODEL = os.getenv("LF_CLASSIFY_MODEL", "yolo11n-cls.pt")
ENABLE_OCR = os.getenv("LF_ENABLE_OCR", "0") == "1"

# A lost report and a found item are considered a match above this score (0..1).
MATCH_THRESHOLD = float(os.getenv("LF_MATCH_THRESHOLD", "0.55"))

# Supported airports. Each has a map built from OpenStreetMap by tools/fetch_osm_map.py
# (app/maps/<code>.json); its zones (gates, check-in, security, ...) are where items get pinned.
AIRPORTS = {
    "LHR": {
        "code": "LHR",
        "name": "London Heathrow",
        "short": "Heathrow",
        "country": "United Kingdom",
        "desk": "Lost Property desk · Terminal 2 Arrivals",
        "team": "Lost Property team",
    },
    "CRA": {
        "code": "CRA",
        "name": "Craiova International Airport",
        "short": "Craiova",
        "country": "Romania",
        "desk": "Lost & Found desk · Arrivals hall",
        "team": "Lost & Found team",
    },
}
DEFAULT_AIRPORT = os.getenv("LF_DEFAULT_AIRPORT", "LHR")
MAPS_DIR = Path(__file__).resolve().parent / "maps"


@lru_cache(maxsize=None)
def airport_map(code: str) -> dict:
    return json.loads((MAPS_DIR / f"{code}.json").read_text(encoding="utf-8"))


@lru_cache(maxsize=None)
def zones(code: str) -> list[dict]:
    """Lost & found zones of an airport, each with a unique label like "Terminal 5 · Gate B42"."""
    return [{**z, "label": f"{z['terminal']} · {z['name']}"} for z in airport_map(code)["zones"]]

DATA_DIR.mkdir(parents=True, exist_ok=True)
IMAGES_DIR.mkdir(parents=True, exist_ok=True)
