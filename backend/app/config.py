import json
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
# Wrong answers to an item's verification question before the passenger is locked out of that item.
MAX_CLAIM_ATTEMPTS = int(os.getenv("LF_MAX_CLAIM_ATTEMPTS", "3"))

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
