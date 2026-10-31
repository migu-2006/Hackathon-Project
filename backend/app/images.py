"""Photo files: the local data/images folder, or a Supabase Storage bucket when
SUPABASE_URL + SUPABASE_SERVICE_KEY are set. URLs stored in the database are
"/images/<name>" locally (served by FastAPI) or the bucket's public https URL."""
from __future__ import annotations

import io

import httpx
from PIL import Image

from . import config

REMOTE = bool(config.SUPABASE_URL and config.SUPABASE_SERVICE_KEY)

if REMOTE:
    _base = f"{config.SUPABASE_URL.rstrip('/')}/storage/v1"
    _auth = {"Authorization": f"Bearer {config.SUPABASE_SERVICE_KEY}", "apikey": config.SUPABASE_SERVICE_KEY}
    _http = httpx.Client(timeout=30)


def public_url(name: str) -> str:
    return f"{_base}/object/public/{config.SUPABASE_BUCKET}/{name}" if REMOTE else f"/images/{name}"


def save(img: Image.Image, name: str, quality: int) -> str:
    """Stores a JPEG and returns the URL to put in the database."""
    if not REMOTE:
        img.save(config.IMAGES_DIR / name, "JPEG", quality=quality)
        return public_url(name)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality)
    r = _http.post(f"{_base}/object/{config.SUPABASE_BUCKET}/{name}", content=buf.getvalue(),
                   headers={**_auth, "Content-Type": "image/jpeg", "x-upsert": "true"})
    r.raise_for_status()
    return public_url(name)


def open_image(url: str) -> Image.Image:
    """Opens a stored photo by its database URL (raises OSError if it is gone)."""
    name = url.rsplit("/", 1)[-1]
    if not url.startswith("http"):
        return Image.open(config.IMAGES_DIR / name)
    r = _http.get(url) if REMOTE else httpx.get(url, timeout=30)
    if r.status_code != 200:
        raise OSError(f"{name}: HTTP {r.status_code}")
    return Image.open(io.BytesIO(r.content))


def delete_prefixed(prefixes: tuple[str, ...]) -> int:
    """Deletes every stored photo whose file name starts with one of the prefixes."""
    if not REMOTE:
        files = [f for f in config.IMAGES_DIR.iterdir() if f.name.startswith(prefixes)]
        for f in files:
            f.unlink(missing_ok=True)
        return len(files)
    names: list[str] = []
    while True:
        r = _http.post(f"{_base}/object/list/{config.SUPABASE_BUCKET}", headers=_auth,
                       json={"prefix": "", "limit": 1000, "offset": len(names)})
        r.raise_for_status()
        page = [o["name"] for o in r.json()]
        names += page
        if len(page) < 1000:
            break
    doomed = [n for n in names if n.startswith(prefixes)]
    for i in range(0, len(doomed), 500):
        _http.request("DELETE", f"{_base}/object/{config.SUPABASE_BUCKET}", headers=_auth,
                      json={"prefixes": doomed[i:i + 500]}).raise_for_status()
    return len(doomed)
