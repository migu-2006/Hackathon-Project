"""One-time copy of the local data (data/lostfound.db + data/images) into Supabase.

    cd backend
    .venv\\Scripts\\python supabase\\migrate_sqlite.py

Safe to run again: rows that already exist in Supabase are skipped, photos are overwritten.
Photo URLs ("/images/x.jpg") are rewritten to the bucket's public URLs.
"""
import json
import sqlite3
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))

from app import config, images, storage  # noqa: E402

if not (storage.POSTGRES and images.REMOTE):
    sys.exit("Set DATABASE_URL, SUPABASE_URL and SUPABASE_SERVICE_KEY in backend/.env first.")

src = BACKEND / "data" / "lostfound.db"
photos = BACKEND / "data" / "images"
if not src.exists():
    sys.exit(f"Nothing to migrate: {src} not found.")

# 1. Photos.
uploaded = 0
for f in sorted(photos.glob("*.jpg")):
    r = images._http.post(f"{images._base}/object/{config.SUPABASE_BUCKET}/{f.name}", content=f.read_bytes(),
                          headers={**images._auth, "Content-Type": "image/jpeg", "x-upsert": "true"})
    r.raise_for_status()
    uploaded += 1
print(f"photos uploaded: {uploaded}")


def remote(url):
    return images.public_url(url.rsplit("/", 1)[-1]) if isinstance(url, str) and url.startswith("/images/") else url


# 2. Rows.
db = sqlite3.connect(src)
db.row_factory = sqlite3.Row
for table in ("found_items", "lost_reports", "claims", "claim_attempts", "notifications"):
    rows = [dict(r) for r in db.execute(f"SELECT * FROM {table}")]
    added = 0
    with storage.tx() as c:
        for row in rows:
            for key in ("imageUrl", "previewUrl"):
                if key in row:
                    row[key] = remote(row[key])
            cols = ", ".join(f'"{k}"' for k in row)
            marks = ", ".join("%s" for _ in row)
            cur = c.execute(f'INSERT INTO {table} ({cols}) VALUES ({marks}) ON CONFLICT ("id") DO NOTHING',
                            tuple(row.values()))
            added += cur.rowcount
    print(f"{table}: {added} copied ({len(rows) - added} already there)")

# Sanity check: a found item reads back with its JSON embedding and remote photo.
item = next(iter(storage.find("found_items")), None)
if item:
    print("check:", item["id"], item["imageUrl"], f"embedding={len(item['embedding'] or [])} floats")
    json.dumps(item)
