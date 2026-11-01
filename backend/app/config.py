import json
import math
import os
import secrets
from functools import lru_cache
from pathlib import Path

from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
# Secrets (Supabase) live in backend/.env, which is not committed. Real environment variables win.
load_dotenv(BASE_DIR / ".env")
DATA_DIR = Path(os.getenv("LF_DATA_DIR", BASE_DIR / "data"))
IMAGES_DIR = DATA_DIR / "images"
DB_PATH = DATA_DIR / "lostfound.db"

# Supabase (see supabase/README.md). Without DATABASE_URL the local SQLite file is used;
# without SUPABASE_URL + SUPABASE_SERVICE_KEY photos stay in data/images.
DATABASE_URL = os.getenv("DATABASE_URL", "")
SUPABASE_URL = os.getenv("SUPABASE_URL", "")
SUPABASE_SERVICE_KEY = os.getenv("SUPABASE_SERVICE_KEY", "")
SUPABASE_BUCKET = os.getenv("SUPABASE_BUCKET", "images")

# Outgoing email for sign-up verification codes (Gmail: smtp.gmail.com, 587, an app password).
# Not set: codes are printed in the server log instead of emailed.
SMTP_HOST = os.getenv("SMTP_HOST", "")
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
SMTP_USER = os.getenv("SMTP_USER", "")
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD", "")
SMTP_FROM = os.getenv("SMTP_FROM", "")  # e.g. "SkyFindr <you@gmail.com>"; defaults to SMTP_USER

# First administrator, created on start when there is none (see auth.ensure_admin).
# Without LF_ADMIN_PASSWORD a random one is saved to data/admin_password.txt and printed.
ADMIN_EMAIL = os.getenv("LF_ADMIN_EMAIL", "admin@skyfindr.app")
ADMIN_PASSWORD = os.getenv("LF_ADMIN_PASSWORD", "")

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

@lru_cache(maxsize=None)
def places(code: str) -> list[dict]:
    """What a passenger can put on their route: the lost & found areas, plus the named shops and
    services on the map. Each place lists the area(s) it belongs to (`zoneIds`): a POI belongs to
    the nearest area, and to any other area almost as close."""
    zs = zones(code)
    out = [{"id": z["id"], "kind": "area", "type": "area", "name": z["name"], "terminal": z["terminal"],
            "label": z["label"], "zoneIds": [z["id"]]} for z in zs]
    if not zs:
        return out
    seen = set()
    for p in airport_map(code)["pois"]:
        if not p.get("name"):
            continue
        dist = sorted(((math.hypot(p["x"] - z["x"], p["y"] - z["y"]), z) for z in zs), key=lambda t: t[0])
        nearest = dist[0][0]
        near = [z for d, z in dist if d <= max(nearest * 1.2, nearest + 25)]
        pid = f"poi-{round(p['x'])}-{round(p['y'])}"
        if pid in seen:
            continue
        seen.add(pid)
        out.append({"id": pid, "kind": "poi", "type": p.get("type") or p.get("kind") or "poi", "poiKind": p.get("kind"),
                    "name": p["name"], "terminal": near[0]["terminal"],
                    "label": f"{p['name']} · {near[0]['label']}", "zoneIds": [z["id"] for z in near]})
    return out


def route_zones(code: str, stops: list[str] | None) -> set[str]:
    """Lost & found areas covered by a passenger's route (unknown stops are ignored)."""
    by_id = {p["id"]: p for p in places(code)}
    return {z for s in stops or [] if s in by_id for z in by_id[s]["zoneIds"]}


DATA_DIR.mkdir(parents=True, exist_ok=True)
IMAGES_DIR.mkdir(parents=True, exist_ok=True)


def _dev_key() -> str:
    """Key for the developer-only endpoints (/dev/...): LF_DEV_KEY, else a random one kept in
    data/dev_key.txt (not committed) and printed when the server starts."""
    if os.getenv("LF_DEV_KEY"):
        return os.environ["LF_DEV_KEY"]
    path = DATA_DIR / "dev_key.txt"
    if not path.exists():
        path.write_text(secrets.token_hex(4))  # 8 characters: easy to type on a phone
    return path.read_text().strip()


DEV_KEY = _dev_key()
