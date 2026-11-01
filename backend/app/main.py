"""Smart Airport Lost & Found - FastAPI backend.

Run:  uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
Docs: http://localhost:8000/docs
"""
from __future__ import annotations

import asyncio
import io
import json
import logging
import re
import secrets
from contextlib import asynccontextmanager

import qrcode
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from PIL import Image, ImageFilter, UnidentifiedImageError
from pydantic import BaseModel

from . import auth, baggage, config, images, matching, storage, vision
from .auth import current_user, optional_user, require_self_or_staff, require_staff

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("lostfound")


@asynccontextmanager
async def lifespan(_: FastAPI):
    # Load YOLO weights at startup so the first intake request is fast.
    await asyncio.to_thread(vision.warmup)
    auth.ensure_admin()
    log.info("Developer key (app: Help > Account, tap the passenger ID 7 times): %s", config.DEV_KEY)
    yield


app = FastAPI(title="Smart Airport Lost & Found", version="0.1.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
app.mount("/images", StaticFiles(directory=config.IMAGES_DIR), name="images")
app.include_router(auth.router)


# ---------------------------------------------------------------- realtime notifications

class Notifier:
    """Per-user WebSocket fan-out. Flutter listens on /ws/{userId}; swap for FCM in production."""

    def __init__(self):
        self.sockets: dict[str, set[WebSocket]] = {}

    async def connect(self, user_id: str, ws: WebSocket):
        await ws.accept()
        self.sockets.setdefault(user_id, set()).add(ws)

    def disconnect(self, user_id: str, ws: WebSocket):
        self.sockets.get(user_id, set()).discard(ws)

    async def send(self, user_id: str, title: str, body: str, data: dict):
        doc = storage.insert("notifications", {
            "id": storage.new_id(), "userId": user_id, "title": title, "body": body,
            "data": data, "timestamp": storage.now(), "read": 0,
        })
        for ws in list(self.sockets.get(user_id, ())):
            try:
                await ws.send_json(doc)
            except Exception:
                self.disconnect(user_id, ws)

    async def push(self, user_ids, event: dict):
        """Live event to some users' open apps (not stored), e.g. a new item for the staff desk."""
        for user_id in user_ids:
            for ws in list(self.sockets.get(user_id, ())):
                try:
                    await ws.send_json(event)
                except Exception:
                    self.disconnect(user_id, ws)

    async def broadcast(self, event: dict):
        """Live event to every connected app (not stored), e.g. {"type": "reset"}."""
        for user_id, sockets in list(self.sockets.items()):
            for ws in list(sockets):
                try:
                    await ws.send_json(event)
                except Exception:
                    self.disconnect(user_id, ws)


notifier = Notifier()


@app.websocket("/ws/{user_id}")
async def ws_notifications(ws: WebSocket, user_id: str, token: str | None = None):
    """Live notifications for the signed-in passenger (?token=<session token>)."""
    user = auth.user_for_token(token)
    if not user or user["id"] != user_id:
        await ws.close(code=4401)
        return
    await notifier.connect(user_id, ws)
    try:
        while True:
            await ws.receive_text()  # keep-alive; client messages are ignored
    except WebSocketDisconnect:
        notifier.disconnect(user_id, ws)


@app.get("/users/{user_id}/notifications")
def list_notifications(user_id: str, user: dict = Depends(current_user)):
    require_self_or_staff(user, user_id)
    return storage.find("notifications", userId=user_id)


# ---------------------------------------------------------------- helpers

async def _read_image(upload: UploadFile) -> tuple[Image.Image, bytes]:
    raw = await upload.read()
    try:
        img = Image.open(io.BytesIO(raw))
        img.load()
    except UnidentifiedImageError:
        raise HTTPException(400, "File is not a valid image")
    return img.convert("RGB"), raw


def _save_image(img: Image.Image, prefix: str) -> str:
    img.thumbnail((1280, 1280))
    return images.save(img, f"{prefix}_{storage.new_id()}.jpg", quality=85)


def _save_preview(img: Image.Image) -> str:
    """Small, heavily blurred copy for public listings: shape and colour, no identifying detail.
    Its file name is unrelated to the original's, so the real photo can't be guessed from it."""
    small = img.copy()
    small.thumbnail((360, 360))
    small = small.filter(ImageFilter.GaussianBlur(max(small.size) / 28))  # shape + colour, no text/stickers
    return images.save(small, f"preview_{storage.new_id()}.jpg", quality=70)


def _preview_url(item: dict) -> str | None:
    """Blurred photo of a found item (made on first use for items registered before blurring existed)."""
    if item.get("previewUrl") or not item.get("imageUrl"):
        return item.get("previewUrl")
    try:
        with images.open_image(item["imageUrl"]) as img:
            url = _save_preview(img.convert("RGB"))
    except OSError:
        return None
    storage.update("found_items", item["id"], previewUrl=url)
    return url


def _public_item(item: dict, reveal: bool = False, located: bool = False) -> dict:
    """Passenger view: no hidden detail, and only the blurred photo unless the passenger
    found this item through a reverse image search (`reveal`). Where the item was found stays
    hidden until staff approve this passenger's claim on it (`located`)."""
    out = {k: v for k, v in item.items() if k not in ("embedding", "secretDetail", "previewUrl", "reportedBy")}
    if not reveal:
        out["imageUrl"] = _preview_url(item)
    out["photoHidden"] = not reveal
    if not located:
        out |= {"location": "", "zoneId": None}
    out["locationHidden"] = not located
    return out


def _approved_item_ids(user: dict | None) -> set[str]:
    """Items whose claim staff approved for this passenger: the only ones they see the location of."""
    if not user:
        return set()
    return {c["itemId"] for c in storage.find("claims", userId=user["id"])
            if c["status"] in ("ready_for_pickup", "recovered")}


def _check_staff_airport(user: dict, airport: str):
    """Staff work on the airport an administrator assigned them (administrators: any airport)."""
    home = user.get("airport")
    if user["role"] == "staff" and home and home.upper() != airport:
        raise HTTPException(403, f"Your account works at {home.upper()}. Ask an administrator to change it.")


def _staff_item(item: dict) -> dict:
    """Staff view: real photo and the hidden detail."""
    return {k: v for k, v in item.items() if k not in ("embedding", "previewUrl")}


def _public_report(report: dict) -> dict:
    return {k: v for k, v in report.items() if k != "embedding"}


def _public_match(m: dict, reveal: bool = False) -> dict:
    return {"score": m["score"], "breakdown": m["breakdown"], "item": _public_item(m["item"], reveal)}


def _airport(code: str | None) -> str:
    code = (code or config.DEFAULT_AIRPORT).upper()
    if code not in config.AIRPORTS:
        raise HTTPException(404, f"Unknown airport {code}")
    return code


def _resolve_zone(airport: str, location: str | None) -> tuple[str | None, str | None]:
    """Zone id / label / name -> (zoneId, label). Unknown text is kept as a free-form location."""
    if not location:
        return None, None
    for z in config.zones(airport):
        if location in (z["id"], z["label"]):
            return z["id"], z["label"]
    named = [z for z in config.zones(airport) if z["name"].lower() == location.lower()]
    if len(named) == 1:
        return named[0]["id"], named[0]["label"]
    return None, location


def _available_items(airport: str) -> list[dict]:
    return storage.find("found_items", status="available", airport=airport)


def _for_matching(report: dict) -> dict:
    """The report plus the lost & found areas of its route, which limit what it can match."""
    return {**report, "routeZones": config.route_zones(report.get("airport") or config.DEFAULT_AIRPORT, report.get("route"))}


def _my_route_zones(user: dict | None, airport: str) -> set[str]:
    """Areas a passenger walked through, from the routes of their open reports at this airport."""
    if not user:
        return set()
    reports = storage.find("lost_reports", userId=user["id"], airport=airport)
    return set().union(*[config.route_zones(airport, r.get("route")) for r in reports if r["status"] != "recovered"])


async def _notify_match(report: dict, match: dict):
    item = match["item"]
    storage.update("lost_reports", report["id"], status="matched", matchedItemId=item["id"])
    await notifier.send(
        report["userId"],
        "Possible match found!",
        f"A {item['color']} {item['category']} was handed in at "
        f"{config.AIRPORTS.get(item.get('airport') or '', {}).get('name', 'the airport')}.",
        {"reportId": report["id"], "itemId": item["id"], "score": match["score"]},
    )


# ---------------------------------------------------------------- Modul A: Smart Intake (staff)

@app.post("/intake/analyze", tags=["Smart Intake"])
async def analyze_image(image: UploadFile = File(...), _: dict = Depends(require_staff)):
    """Preview the AI attributes before the operator confirms the intake."""
    img, _ = await _read_image(image)
    analysis = await asyncio.to_thread(vision.analyze, img)
    return analysis.public()


async def _register_item(img: Image.Image, airport: str, zone_id: str | None, label: str | None, *,
                         category: str | None = None, color: str | None = None, notes: str | None = None,
                         secret: str | None = None, source: str = "staff", reported_by: str | None = None):
    """Add a found item to the inventory and notify the passengers whose reports it matches."""
    analysis = await asyncio.to_thread(vision.analyze, img)
    item = storage.insert("found_items", {
        "id": storage.new_id(),
        "airport": airport,
        "zoneId": zone_id,
        "previewUrl": _save_preview(img),
        "imageUrl": _save_image(img, "found"),
        "category": (category or analysis.category).lower(),
        "label": analysis.label,
        "color": (color or analysis.color).lower(),
        "colorHex": analysis.public()["colorHex"],
        "text": analysis.text,
        "location": label,
        "notes": notes,
        "secretDetail": secret,
        "source": source,
        "reportedBy": reported_by,
        "embedding": analysis.embedding,
        "timestamp": storage.now(),
        "status": "available",
    })

    # Auto-match: notify every passenger at this airport still searching for something like this
    # (never the passenger who handed it in).
    notified = []
    for report in storage.find("lost_reports", status="searching", airport=airport):
        if report["userId"] == reported_by:
            continue
        s, breakdown = matching.score(_for_matching(report), item)
        if s >= config.MATCH_THRESHOLD:
            await _notify_match(report, {"score": s, "breakdown": breakdown, "item": item})
            notified.append({"reportId": report["id"], "score": s})
    return item, analysis, notified


@app.post("/found-items", tags=["Smart Intake"])
async def create_found_item(
    image: UploadFile = File(...),
    location: str = Form(..., description="Zone id or label, e.g. lhr-gate-b42 / Terminal 5 · Gate B42"),
    airport: str | None = Form(None, description="IATA code, e.g. LHR or CRA"),
    category: str | None = Form(None, description="Override the AI category"),
    color: str | None = Form(None, description="Override the AI color"),
    notes: str | None = Form(None),
    secretDetail: str | None = Form(None, description="Hidden detail used to verify ownership"),
    _: dict = Depends(require_staff),
):
    airport = _airport(airport)
    img, _ = await _read_image(image)
    zone_id, label = _resolve_zone(airport, location)
    item, analysis, notified = await _register_item(img, airport, zone_id, label, category=category, color=color,
                                                    notes=notes, secret=secretDetail)
    return {"item": _staff_item(item), "ai": analysis.public(), "notifiedReports": notified}


@app.post("/handed-in", tags=["Passenger"])
async def hand_in_item(
    image: UploadFile = File(...),
    place: str = Form(..., description="Where it was found: a place id from /airports/{IATA}/places"),
    description: str = Form(..., min_length=3, max_length=500),
    secretDetail: str | None = Form(None, max_length=200, description="Hidden detail only the owner would know"),
    airport: str | None = Form(None),
    user: dict = Depends(current_user),
):
    """A passenger found something someone else lost: it goes straight into the airport's
    inventory (marked as handed in by a passenger), is matched against open reports, and the
    airport's staff get a live alert."""
    if auth.is_staff(user):
        raise HTTPException(403, "Staff register found items from the intake screen")
    airport = _airport(airport)
    spot = next((p for p in config.places(airport) if p["id"] == place), None)
    if not spot:
        raise HTTPException(422, f"Unknown place at {airport}")
    zone_id = spot["zoneIds"][0]
    img, _ = await _read_image(image)
    item, analysis, notified = await _register_item(
        img, airport, zone_id, spot["label"], notes=description.strip(),
        secret=(secretDetail or "").strip() or None, source="passenger", reported_by=user["id"])
    await notifier.push(_desk_ids(airport), {"type": "handed_in", "itemId": item["id"], "airport": airport,
                               "category": item["category"], "color": item["color"], "location": item["location"]})
    return {"item": _public_item(item, reveal=True, located=True), "ai": analysis.public(),
            "notifiedReports": len(notified)}


def _desk_ids(airport: str) -> list[str]:
    """Accounts that work the desk at this airport: its staff (and staff with no airport set) and administrators."""
    return [u["id"] for u in storage.find("users") if u["role"] == "admin"
            or (u["role"] == "staff" and (u.get("airport") or airport) == airport)]


@app.get("/handed-in", tags=["Passenger"])
def my_handed_in_items(user: dict = Depends(current_user)):
    """Items this passenger handed in, newest first, with their own photo and location."""
    items = storage.find("found_items", reportedBy=user["id"])
    return [_public_item(i, reveal=True, located=True) for i in sorted(items, key=lambda i: i["timestamp"], reverse=True)]


@app.get("/found-items", tags=["Found Items"])
def list_found_items(airport: str | None = None, category: str | None = None, color: str | None = None,
                     zoneId: str | None = None, status: str | None = "available", staff: bool = False,
                     onMyRoute: bool = False, user: dict | None = Depends(optional_user)):
    """Passengers get blurred photos; `staff=true` (inventory, staff accounts) gets the real ones.
    `onMyRoute=true`: only items found in the areas the passenger listed on their reports' routes."""
    if staff and not auth.is_staff(user):
        raise HTTPException(403, "Airport staff only")
    code = _airport(airport)
    if staff:
        _check_staff_airport(user, code)
    elif zoneId:
        raise HTTPException(403, "Item locations are shared once your claim is approved")
    items = storage.find("found_items", airport=code, category=category, color=color, zoneId=zoneId, status=status)
    if staff:
        return [_staff_item(i) for i in items]
    if onMyRoute:
        route = _my_route_zones(user, code)
        items = [i for i in items if i.get("zoneId") in route]
    approved = _approved_item_ids(user)
    return [_public_item(i, located=i["id"] in approved) for i in items]


@app.get("/found-items/{item_id}", tags=["Found Items"])
def get_found_item(item_id: str, staff: bool = False, user: dict | None = Depends(optional_user)):
    if staff and not auth.is_staff(user):
        raise HTTPException(403, "Airport staff only")
    item = storage.get("found_items", item_id)
    if not item:
        raise HTTPException(404, "Item not found")
    if staff:
        _check_staff_airport(user, item.get("airport") or config.DEFAULT_AIRPORT)
        return _staff_item(item)
    return _public_item(item, located=item_id in _approved_item_ids(user))


# ---------------------------------------------------------------- Modul B: Passenger app

@app.post("/search/visual", tags=["Passenger"])
async def visual_search(image: UploadFile = File(...), limit: int = Form(10), airport: str | None = Form(None),
                        user: dict | None = Depends(optional_user)):
    """Reverse image search: rank available found items by similarity to the passenger photo.
    A signed-in passenger only searches the items found in the areas of their reports' routes."""
    img, _ = await _read_image(image)
    analysis = await asyncio.to_thread(vision.analyze, img)
    query = {"category": analysis.category, "color": analysis.color, "embedding": analysis.embedding}
    code = _airport(airport)
    items = _available_items(code)
    if user and not auth.is_staff(user):
        route = _my_route_zones(user, code)
        items = [i for i in items if i.get("zoneId") in route]
    matches = matching.rank(query, items, limit=limit, min_score=0.2)
    # The only passenger view with a clear photo, and only for the best match (results are sorted by score):
    # enough to recognise your own item, without exposing every similar item someone else lost.
    return {"query": analysis.public(), "matches": [_public_match(m, reveal=i == 0) for i, m in enumerate(matches)]}


@app.post("/lost-reports", tags=["Passenger"])
async def create_lost_report(
    userId: str | None = Form(None, description="Ignored: reports belong to the signed-in passenger"),
    description: str = Form(""),
    airport: str | None = Form(None),
    category: str | None = Form(None),
    color: str | None = Form(None),
    lastSeenLocation: str | None = Form(None),
    route: str | None = Form(None, description='Places visited, as a JSON list of ids from /airports/{IATA}/places'),
    travelDate: str | None = Form(None, description="YYYY-MM-DD"),
    image: UploadFile | None = File(None),
    user: dict = Depends(current_user),
):
    airport = _airport(airport)
    stops = _parse_route(airport, route)
    imageUrl, embedding = None, None
    # "Black over-ear headphones" -> color black, so the form doesn't need a separate color field.
    color = color or next((c for c in vision.NAMED_COLORS if re.search(rf"\b{c}\b", description.lower())), None)
    if image is not None and image.filename:
        img, _ = await _read_image(image)
        analysis = await asyncio.to_thread(vision.analyze, img)
        imageUrl, embedding = _save_image(img, "lost"), analysis.embedding
        category = category or analysis.category
        color = color or analysis.color
    if not category:
        raise HTTPException(422, "Provide a category or a photo of the item")

    report = storage.insert("lost_reports", {
        "id": storage.new_id(),
        "userId": user["id"],
        "airport": airport,
        "description": description,
        "category": category.lower(),
        "color": color.lower() if color else None,
        "lastSeenLocation": " → ".join(_place_labels(airport, stops)) if stops else _resolve_zone(airport, lastSeenLocation)[1],
        "route": stops or None,
        "travelDate": travelDate,
        "imageUrl": imageUrl,
        "embedding": embedding,
        "timestamp": storage.now(),
        "status": "searching",
        "matchedItemId": None,
    })

    # The item may already be in the inventory.
    matches = matching.rank(_for_matching(report), _available_items(airport), limit=5, min_score=config.MATCH_THRESHOLD)
    if matches:
        await _notify_match(report, matches[0])
        report = storage.get("lost_reports", report["id"])
    return {"report": _public_report(report), "matches": [_public_match(m) for m in matches]}


@app.get("/lost-reports", tags=["Passenger"])
def list_lost_reports(userId: str | None = None, status: str | None = None, user: dict = Depends(current_user)):
    if not auth.is_staff(user):
        userId = user["id"]  # passengers only ever see their own
    return [_public_report(r) for r in storage.find("lost_reports", userId=userId, status=status)]


@app.get("/lost-reports/{report_id}/matches", tags=["Passenger"])
def report_matches(report_id: str, limit: int = 10, user: dict = Depends(current_user)):
    report = storage.get("lost_reports", report_id)
    if not report:
        raise HTTPException(404, "Report not found")
    require_self_or_staff(user, report["userId"])
    matches = matching.rank(_for_matching(report), _available_items(report["airport"]), limit=limit, min_score=0.2)
    return [_public_match(m) for m in matches]


# ---------------------------------------------------------------- Airports & maps

@app.get("/airports", tags=["Airports & maps"])
def airports():
    return list(config.AIRPORTS.values())


@app.get("/meta", tags=["Airports & maps"])
def meta(airport: str | None = None):
    """Airport info and lost & found zones for forms and labels."""
    code = _airport(airport)
    return {"airport": config.AIRPORTS[code], "zones": config.zones(code), "airports": list(config.AIRPORTS.values())}


@app.get("/map/{airport}", tags=["Airports & maps"])
def airport_map(airport: str):
    """Terminal outlines, rooms per level, gates and POIs (metres). © OpenStreetMap contributors."""
    return JSONResponse(config.airport_map(_airport(airport)), headers={"Cache-Control": "public, max-age=3600"})


@app.get("/airports/{airport}/places", tags=["Airports & maps"])
def route_places(airport: str):
    """Areas and named shops / services a passenger can add to the route of a lost report."""
    return [{k: v for k, v in p.items() if k != "zoneIds"} for p in config.places(_airport(airport))]


def _parse_route(airport: str, raw: str | None) -> list[str]:
    if not raw:
        return []
    try:
        stops = json.loads(raw)
    except ValueError:
        stops = [s.strip() for s in raw.split(",")]
    if not isinstance(stops, list):
        raise HTTPException(422, "route must be a list of place ids")
    known = {p["id"] for p in config.places(airport)}
    unknown = [s for s in stops if s not in known]
    if unknown:
        raise HTTPException(422, f"Unknown place(s) at {airport}: {', '.join(map(str, unknown[:3]))}")
    return list(dict.fromkeys(stops))  # keep the order, drop repeats


def _place_labels(airport: str, stops: list[str]) -> list[str]:
    by_id = {p["id"]: p for p in config.places(airport)}
    return [by_id[s]["label"] for s in stops]


@app.get("/airports/{airport}/zones", tags=["Airports & maps"])
def map_zones(airport: str | None = None, user: dict | None = Depends(optional_user)):
    """Zones with found items pinned on each. Staff see the whole inventory of their airport;
    a passenger only sees the items whose claim staff approved for them."""
    code = _airport(airport)
    if auth.is_staff(user):
        _check_staff_airport(user, code)
        items, view = _available_items(code), _staff_item
    else:
        approved = _approved_item_ids(user)
        items = [i for i in storage.find("found_items", airport=code) if i["id"] in approved and i["status"] != "disposed"]
        view = lambda i: _public_item(i, located=True)  # noqa: E731
    out = []
    for zone in config.zones(code):
        here = [view(i) for i in items if i.get("zoneId") == zone["id"] or i["location"] == zone["label"]]
        out.append({**zone, "count": len(here), "items": here})
    return out


# ---------------------------------------------------------------- Modul C: Claim & Pick-up

class ClaimCreate(BaseModel):
    reportId: str
    itemId: str


class ClaimAnswer(BaseModel):
    answer: str


class ClaimDecision(BaseModel):
    approved: bool


def _verification_question(item: dict) -> str:
    if item.get("text"):
        return "What brand, name or text is written on the item?"
    if item.get("secretDetail"):
        return "Describe something distinctive about the item (contents, stickers, scratches, engravings)."
    return f"Describe the {item['category']} in detail: brand, contents and any distinctive marks."


def _get_claim(claim_id: str) -> dict:
    claim = storage.get("claims", claim_id)
    if not claim:
        raise HTTPException(404, "Claim not found")
    return claim


# No 0/O, 1/I/L: the code is read aloud and typed at the desk.
_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"


def _ensure_pickup_code(claim: dict) -> dict:
    """Short code shown under the QR, for desks that can't scan. Created on approval
    (or lazily for claims approved before codes existed)."""
    if claim.get("pickupCode"):
        return claim
    while True:
        code = "".join(secrets.choice(_CODE_ALPHABET) for _ in range(6))
        if not storage.find("claims", pickupCode=code):
            break
    storage.update("claims", claim["id"], pickupCode=code)
    return {**claim, "pickupCode": code}


def _public_claim(claim: dict) -> dict:
    """Passenger view: the answer stays private; the QR token and pickup code only exist once approved."""
    if claim["status"] in ("ready_for_pickup", "recovered"):
        claim = _ensure_pickup_code(claim)
    out = {k: v for k, v in claim.items() if k != "answer"}
    if claim["status"] not in ("ready_for_pickup", "recovered"):
        out["token"] = None
        out["pickupCode"] = None
    return out


def _claim_by_token(value: str) -> dict:
    """Accepts the scanned QR content, its bare token, or the pickup code typed at the desk
    (any case, with or without spaces/dashes)."""
    value = value.strip().removeprefix("lostfound:claim:")
    claims = storage.find("claims", token=value)
    if not claims:
        code = re.sub(r"[^A-Z0-9]", "", value.upper())
        if len(code) == 6:
            claims = storage.find("claims", pickupCode=code)
    if not claims:
        raise HTTPException(404, "Unknown pickup code. Check the code under the passenger's QR.")
    return claims[0]


def _staff_claim_view(claim: dict) -> dict:
    item = storage.get("found_items", claim["itemId"])
    return {
        "claim": claim,
        "item": _staff_item(item),  # staff sees the real photo and secretDetail
        "report": _public_report(storage.get("lost_reports", claim["reportId"])),
    }


@app.post("/claims", tags=["Claim & Pick-up"])
def create_claim(body: ClaimCreate, user: dict = Depends(current_user)):
    report = storage.get("lost_reports", body.reportId)
    item = storage.get("found_items", body.itemId)
    if not report or not item:
        raise HTTPException(404, "Report or item not found")
    if report["userId"] != user["id"]:
        raise HTTPException(403, "You can only claim items for your own reports")
    if item["status"] != "available":
        raise HTTPException(409, "Item is no longer available")
    if item.get("reportedBy") == user["id"]:
        raise HTTPException(403, "You handed this item in, so you can't claim it")
    # One claim per passenger and item: once the details are sent, they can't claim it again,
    # whatever staff decide. A claim opened but never sent is reused.
    mine = storage.find("claims", userId=user["id"], itemId=item["id"])
    if any(c["status"] != "awaiting_answer" for c in mine):
        raise HTTPException(409, "You already sent a claim for this item. Each item can only be claimed once.")
    if mine:
        claim = mine[0]
        return {"id": claim["id"], "question": claim["question"], "status": claim["status"]}
    claim = storage.insert("claims", {
        "id": storage.new_id(),
        "token": secrets.token_urlsafe(16),
        "reportId": report["id"],
        "itemId": item["id"],
        "userId": report["userId"],
        "question": _verification_question(item),
        "answer": None,
        "timestamp": storage.now(),
        "status": "awaiting_answer",
    })
    storage.update("lost_reports", report["id"], status="matched", matchedItemId=item["id"])
    return {"id": claim["id"], "question": claim["question"], "status": claim["status"]}


@app.get("/claims", tags=["Claim & Pick-up"])
def list_claims(userId: str | None = None, user: dict = Depends(current_user)):
    """A passenger's claims with their review status (and pick-up token once approved)."""
    userId = userId if auth.is_staff(user) and userId else user["id"]
    return [_public_claim(c) for c in storage.find("claims", userId=userId)]


@app.post("/claims/{claim_id}/answer", tags=["Claim & Pick-up"])
def answer_claim(claim_id: str, body: ClaimAnswer, user: dict = Depends(current_user)):
    """The passenger's description of the item, sent once: it goes straight to staff review
    (staff compare it with the hidden detail and decide) and is kept in the staff log."""
    claim = _get_claim(claim_id)
    if claim["userId"] != user["id"]:
        raise HTTPException(403, "This claim belongs to another passenger")
    if claim["status"] != "awaiting_answer":
        raise HTTPException(409, f"Claim is {claim['status']}")
    item = storage.get("found_items", claim["itemId"])
    answer = body.answer.strip()
    if len(answer) < 3:
        raise HTTPException(422, "Please describe the item in a bit more detail.")
    storage.insert("claim_attempts", {
        "id": storage.new_id(), "claimId": claim_id, "itemId": item["id"], "userId": claim["userId"],
        "airport": item.get("airport"), "answer": answer, "result": "submitted", "cleared": 0,
        "timestamp": storage.now(),
    })
    storage.update("claims", claim_id, answer=answer, status="under_review")
    return {"id": claim_id, "status": "under_review"}


@app.get("/claims/{claim_id}/qr", tags=["Claim & Pick-up"])
def claim_qr(claim_id: str, token: str | None = None, user: dict | None = Depends(optional_user)):
    """QR image of the pick-up pass (owner or staff; `?token=` works for plain image loaders)."""
    claim = _get_claim(claim_id)
    user = user or auth.user_for_token(token)
    if not user:
        raise HTTPException(401, "Please sign in")
    require_self_or_staff(user, claim["userId"])
    if claim["status"] not in ("ready_for_pickup", "recovered"):
        raise HTTPException(409, "The pick-up pass is available once staff approve the claim")
    buf = io.BytesIO()
    qrcode.make(f"lostfound:claim:{claim['token']}").save(buf, "PNG")
    return Response(buf.getvalue(), media_type="image/png")


# Ownership review (staff, remote) -----------------------------------------------------------

@app.get("/staff/claims", tags=["Claim & Pick-up"])
def staff_claims(status: str = "under_review", _: dict = Depends(require_staff)):
    """Claims waiting for an ownership decision, with the hidden detail to compare against."""
    return [_staff_claim_view(c) for c in storage.find("claims", status=status)]


@app.get("/staff/claim-attempts", tags=["Claim & Pick-up"])
def claim_attempts(airport: str | None = None, _: dict = Depends(require_staff)):
    """Claim log: the details each passenger sent for an item, grouped per passenger + item."""
    groups: dict[tuple[str, str], dict] = {}
    for a in storage.find("claim_attempts", airport=airport.upper() if airport else None):
        g = groups.setdefault((a["userId"], a["itemId"]), {"userId": a["userId"], "itemId": a["itemId"], "attempts": []})
        g["attempts"].append({k: a[k] for k in ("id", "claimId", "answer", "result", "timestamp")})
    out = []
    for g in groups.values():
        item = storage.get("found_items", g["itemId"])
        if not item:
            continue
        g |= {
            "item": _staff_item(item),  # staff view: real photo, secretDetail
            "lastAttempt": g["attempts"][0]["timestamp"],  # newest first
        }
        out.append(g)
    return sorted(out, key=lambda g: g["lastAttempt"], reverse=True)


@app.post("/staff/claims/{claim_id}/review", tags=["Claim & Pick-up"])
async def review_claim(claim_id: str, body: ClaimDecision, _: dict = Depends(require_staff)):
    claim = _get_claim(claim_id)
    if claim["status"] != "under_review":
        raise HTTPException(409, f"Claim is {claim['status']}")
    if body.approved:
        storage.update("claims", claim_id, status="ready_for_pickup", reviewedAt=storage.now())
        _ensure_pickup_code(claim)
        item = storage.get("found_items", claim["itemId"])
        desk = config.AIRPORTS.get(item.get("airport") or config.DEFAULT_AIRPORT, {}).get("desk", "Lost Property desk")
        await notifier.send(claim["userId"], "Ready for pickup",
                            f"Your claim was approved. Show your pickup pass at the {desk}.",
                            {"claimId": claim_id})
        return {"status": "ready_for_pickup"}
    storage.update("claims", claim_id, status="rejected", reviewedAt=storage.now())
    storage.update("lost_reports", claim["reportId"], status="searching", matchedItemId=None)
    await notifier.send(claim["userId"], "Claim not approved",
                        "We couldn't confirm ownership. We'll keep searching for your item.", {"claimId": claim_id})
    return {"status": "rejected"}


# Pick-up desk ---------------------------------------------------------------------------------

@app.post("/claims/scan-image", tags=["Claim & Pick-up"])
async def scan_qr_image(image: UploadFile = File(...), _: dict = Depends(require_staff)):
    """Finds a pick-up QR in a photo (webcam frame or screenshot) for desks without a phone scanner."""
    import cv2
    import numpy as np

    img, _ = await _read_image(image)
    gray = cv2.cvtColor(np.array(img), cv2.COLOR_RGB2GRAY)
    detector = cv2.QRCodeDetector()
    for frame in (gray, cv2.resize(gray, None, fx=2, fy=2)):  # small QRs decode better upscaled
        value, _, _ = detector.detectAndDecode(frame)
        if value.startswith(("lostfound:claim:", "lostfound:bag:")):
            return {"code": value}
    raise HTTPException(422, "No pick-up QR code found in the image")


@app.get("/claims/scan/{token}", tags=["Claim & Pick-up"])
def scan_claim(token: str, _: dict = Depends(require_staff)):
    """Operator view after scanning the QR: the passenger's answer next to the hidden details."""
    return _staff_claim_view(_claim_by_token(token))


@app.post("/claims/scan/{token}/decision", tags=["Claim & Pick-up"])
async def decide_claim(token: str, body: ClaimDecision, _: dict = Depends(require_staff)):
    claim = _claim_by_token(token)
    if claim["status"] != "ready_for_pickup":
        raise HTTPException(409, f"Claim is {claim['status']}")

    if body.approved:
        storage.update("claims", claim["id"], status="recovered")
        storage.update("found_items", claim["itemId"], status="claimed")
        storage.update("lost_reports", claim["reportId"], status="recovered")
        await notifier.send(claim["userId"], "Item recovered", "Have a safe flight!", {"claimId": claim["id"]})
        return {"status": "recovered"}

    storage.update("claims", claim["id"], status="rejected")
    storage.update("lost_reports", claim["reportId"], status="searching", matchedItemId=None)
    await notifier.send(claim["userId"], "Claim rejected", "Identity could not be confirmed at the desk.",
                        {"claimId": claim["id"]})
    return {"status": "rejected"}


# ---------------------------------------------------------------- Lost luggage (checked bags)

def _bag_report_view(report: dict, staff: bool) -> dict:
    """Owner and staff see the whole file; the delivery code only exists once the bag is handed over."""
    out = {k: v for k, v in report.items() if k not in ("embedding", "handoverToken")}
    if report["status"] not in baggage.HANDOVER | {"delivered"}:
        out["handoverCode"] = None
    out["events"] = storage.find("bag_events", order="timestamp ASC", reportId=report["id"])
    return out


def _bag_view(bag: dict) -> dict:
    return {k: v for k, v in bag.items() if k != "embedding"}


def _get_bag_report(report_id: str, user: dict) -> dict:
    report = storage.get("baggage_reports", report_id)
    if not report:
        raise HTTPException(404, "Baggage file not found")
    if auth.is_staff(user):
        _check_staff_airport(user, report.get("airport") or config.DEFAULT_AIRPORT)
    elif report["userId"] != user["id"]:
        raise HTTPException(403, "This belongs to another passenger")
    return report


def _ensure_handover(report: dict) -> dict:
    if report.get("handoverToken"):
        return report
    while True:
        code = "".join(secrets.choice(_CODE_ALPHABET) for _ in range(6))
        if not storage.find("baggage_reports", handoverCode=code):
            break
    fields = {"handoverToken": secrets.token_urlsafe(16), "handoverCode": code}
    storage.update("baggage_reports", report["id"], **fields)
    return {**report, **fields}


async def _bag_event(report: dict, kind: str, by: dict | None = None, *, station: str | None = None,
                     flight: str | None = None, eta: str | None = None, note: str | None = None) -> dict:
    """Add a step to the file's timeline, move its status, tell the passenger and the desk."""
    if kind in baggage.HANDOVER:
        report = _ensure_handover(report)
    status = baggage.EVENT_STATUS[kind] or report["status"]
    storage.insert("bag_events", {
        "id": storage.new_id(), "reportId": report["id"], "kind": kind, "station": station, "flight": flight,
        "eta": eta, "note": note, "byId": by["id"] if by else None,
        "byName": (by.get("name") or by["email"].split("@")[0]) if by else None, "timestamp": storage.now(),
    })
    storage.update("baggage_reports", report["id"], status=status, updatedAt=storage.now())
    report = {**report, "status": status}
    if kind in baggage.MESSAGES:
        airport = config.AIRPORTS.get(report["airport"], {}).get("name", report["airport"])
        title, body = baggage.MESSAGES[kind]
        await notifier.send(report["userId"], title, body.format(
            ref=report["ref"], airport=airport, station=station or "another airport", flight=flight or "",
            eta=f", arriving {eta}" if eta else ""), {"baggageReportId": report["id"], "kind": kind})
    await notifier.push(_desk_ids(report["airport"]), {"type": "baggage", "reportId": report["id"], "kind": kind})
    return report


async def _link_bag(report: dict, bag: dict, by: dict | None = None) -> dict:
    storage.update("on_hand_bags", bag["id"], status="matched", reportId=report["id"])
    storage.update("baggage_reports", report["id"], matchedBagId=bag["id"])
    where = bag.get("location") or "the baggage service desk"
    return await _bag_event({**report, "matchedBagId": bag["id"]}, "found_here", by, station=report["airport"],
                            note=f"Tag {bag.get('tagNumber') or '—'} · {where}")


def _for_bag_matching(report: dict) -> dict:
    user = storage.get("users", report["userId"]) or {}
    return {**report, "passengerName": user.get("name")}


def _bag_suggestions(report: dict, limit: int = 5) -> list[dict]:
    r = _for_bag_matching(report)
    scored = [(baggage.score(r, b), b) for b in storage.find("on_hand_bags", airport=report["airport"], status="on_hand")]
    best = sorted(((s, sig, b) for (s, sig), b in scored if s >= 0.3), key=lambda t: -t[0])[:limit]
    return [{"score": s, "breakdown": sig, "bag": _bag_view(b)} for s, sig, b in best]


@app.post("/baggage-reports", tags=["Lost luggage"])
async def create_baggage_report(
    flight: str = Form(..., description="e.g. RO642"),
    flightDate: str = Form(..., description="YYYY-MM-DD"),
    tagNumbers: str | None = Form(None, description="Bag tag numbers, comma separated"),
    bagType: str | None = Form(None),
    color: str | None = Form(None),
    brand: str | None = Form(None),
    nameOnTag: str | None = Form(None),
    marks: str | None = Form(None),
    contents: str | None = Form(None),
    kind: str = Form("delayed", description="delayed | damaged"),
    deliveryMethod: str = Form("deliver", description="deliver | pickup"),
    deliveryAddress: str | None = Form(None),
    deliveryPhone: str | None = Form(None),
    deliveryWindow: str | None = Form(None),
    airport: str | None = Form(None),
    image: UploadFile | None = File(None),
    user: dict = Depends(current_user),
):
    """A checked bag didn't arrive (or arrived damaged): open a file at the arrival airport."""
    if auth.is_staff(user):
        raise HTTPException(403, "Passengers file baggage reports from their own account")
    airport = _airport(airport)
    try:
        tags = baggage.parse_tags(tagNumbers)
    except ValueError as e:
        raise HTTPException(422, str(e))
    if kind not in ("delayed", "damaged") or deliveryMethod not in ("deliver", "pickup"):
        raise HTTPException(422, "Unknown report or delivery type")
    if bagType and bagType not in baggage.BAG_TYPES:
        raise HTTPException(422, "Unknown bag type")
    if not tags and not (bagType and color):
        raise HTTPException(422, "Add the bag tag number, or at least the bag type and colour")
    if deliveryMethod == "deliver" and not ((deliveryAddress or "").strip() and (deliveryPhone or "").strip()):
        raise HTTPException(422, "Add the delivery address and a phone number")
    embedding, image_url = None, None
    if image:
        img, _ = await _read_image(image)
        analysis = await asyncio.to_thread(vision.analyze, img)
        embedding, image_url = analysis.embedding, _save_image(img, "lost")
        color = color or analysis.color
        bagType = bagType or baggage.AI_TO_BAG.get(analysis.category)
    n = len(storage.find("baggage_reports", airport=airport)) + 1
    report = storage.insert("baggage_reports", {
        "id": storage.new_id(), "ref": f"{airport}-BG-{n:05d}", "userId": user["id"], "airport": airport,
        "kind": kind, "flight": baggage.normalize_flight(flight), "flightDate": flightDate[:10], "tagNumbers": tags,
        "bagType": bagType, "color": (color or "").lower() or None, "brand": brand, "nameOnTag": nameOnTag or user.get("name"),
        "marks": marks, "contents": contents, "deliveryMethod": deliveryMethod,
        "deliveryAddress": (deliveryAddress or "").strip() or None, "deliveryPhone": (deliveryPhone or "").strip() or None,
        "deliveryWindow": deliveryWindow, "imageUrl": image_url, "embedding": embedding, "status": "reported",
        "updatedAt": storage.now(), "timestamp": storage.now(),
    })
    report = await _bag_event(report, "reported")
    # The bag may already be waiting at the desk: same tag number = same bag.
    suggestions = _bag_suggestions(report)
    if suggestions and suggestions[0]["score"] >= 1.0:
        report = await _link_bag(report, storage.get("on_hand_bags", suggestions[0]["bag"]["id"]))
    return _bag_report_view(storage.get("baggage_reports", report["id"]), staff=False)


@app.get("/baggage-reports", tags=["Lost luggage"])
def list_baggage_reports(airport: str | None = None, status: str | None = None, user: dict = Depends(current_user)):
    """Staff: the files at their airport. Passengers: their own files, with the timeline."""
    if auth.is_staff(user):
        code = _airport(airport)
        _check_staff_airport(user, code)
        reports = storage.find("baggage_reports", airport=code, status=status)
    else:
        reports = storage.find("baggage_reports", userId=user["id"], status=status)
    return [_bag_report_view(r, auth.is_staff(user)) for r in reports]


@app.get("/baggage-reports/{report_id}", tags=["Lost luggage"])
def get_baggage_report(report_id: str, user: dict = Depends(current_user)):
    """One file; staff also get the matched bag and likely unclaimed bags."""
    report = _get_bag_report(report_id, user)
    out = _bag_report_view(report, auth.is_staff(user))
    if auth.is_staff(user):
        bag = storage.get("on_hand_bags", report["matchedBagId"]) if report.get("matchedBagId") else None
        out["bag"] = _bag_view(bag) if bag else None
        out["suggestions"] = [] if bag or report["status"] in baggage.CLOSED else _bag_suggestions(report)
        passenger = storage.get("users", report["userId"]) or {}
        out["passengerName"] = passenger.get("name")
        out["passengerEmail"] = passenger.get("email")
    return out


class BagEventIn(BaseModel):
    kind: str
    station: str | None = None
    flight: str | None = None
    eta: str | None = None
    note: str | None = None


@app.post("/baggage-reports/{report_id}/events", tags=["Lost luggage"])
async def add_baggage_event(report_id: str, body: BagEventIn, user: dict = Depends(require_staff)):
    """Desk update on a file: located elsewhere, forwarded on a flight, arrived, out for delivery..."""
    report = _get_bag_report(report_id, user)
    if body.kind not in baggage.STAFF_EVENTS:
        raise HTTPException(422, "Unknown update")
    if report["status"] in baggage.CLOSED:
        raise HTTPException(409, "This file is closed")
    if body.kind == "located" and not (body.station or "").strip():
        raise HTTPException(422, "Where was the bag found?")
    if body.kind == "forwarded" and not (body.flight or "").strip():
        raise HTTPException(422, "Which flight is the bag on?")
    if body.kind == "note" and not (body.note or "").strip():
        raise HTTPException(422, "Write a note")
    if body.kind == "out_for_delivery" and not report.get("deliveryAddress"):
        raise HTTPException(409, "The passenger chose to pick the bag up at the desk")
    await _bag_event(report, body.kind, user, station=(body.station or "").strip().upper() or None,
                     flight=baggage.normalize_flight(body.flight), eta=(body.eta or "").strip() or None,
                     note=(body.note or "").strip() or None)
    if body.kind == "declared_lost" and report.get("matchedBagId"):
        storage.update("on_hand_bags", report["matchedBagId"], status="on_hand", reportId=None)
    return get_baggage_report(report_id, user)


class BagLink(BaseModel):
    bagId: str


@app.post("/baggage-reports/{report_id}/link", tags=["Lost luggage"])
async def link_baggage(report_id: str, body: BagLink, user: dict = Depends(require_staff)):
    """Staff confirm that an unclaimed bag at the desk is this passenger's."""
    report = _get_bag_report(report_id, user)
    bag = storage.get("on_hand_bags", body.bagId)
    if not bag or bag["airport"] != report["airport"]:
        raise HTTPException(404, "Bag not found at this airport")
    if bag["status"] != "on_hand" or report.get("matchedBagId") or report["status"] in baggage.CLOSED:
        raise HTTPException(409, "This bag or file is already matched")
    await _link_bag(report, bag, user)
    return get_baggage_report(report_id, user)


@app.post("/baggage/on-hand", tags=["Lost luggage"])
async def register_on_hand_bag(
    airport: str | None = Form(None),
    tagNumber: str | None = Form(None),
    flight: str | None = Form(None),
    bagType: str | None = Form(None),
    color: str | None = Form(None),
    brand: str | None = Form(None),
    nameOnTag: str | None = Form(None),
    location: str | None = Form(None, description="Zone id or label where the bag is kept"),
    notes: str | None = Form(None),
    image: UploadFile | None = File(None),
    user: dict = Depends(require_staff),
):
    """An unclaimed bag (left on the belt, rush bag from another airport): register it and match
    it against open files. Same tag number as a file = matched and the passenger is told right away."""
    airport = _airport(airport)
    _check_staff_airport(user, airport)
    tag = baggage.normalize_tag(tagNumber) if tagNumber and tagNumber.strip() else None
    if tagNumber and tagNumber.strip() and not tag:
        raise HTTPException(422, "A bag tag number has 6 to 10 letters or digits")
    if bagType and bagType not in baggage.BAG_TYPES:
        raise HTTPException(422, "Unknown bag type")
    embedding, image_url, color_hex = None, None, None
    if image:
        img, _ = await _read_image(image)
        analysis = await asyncio.to_thread(vision.analyze, img)
        embedding, image_url, color_hex = analysis.embedding, _save_image(img, "found"), analysis.public()["colorHex"]
        color = color or analysis.color
        bagType = bagType or baggage.AI_TO_BAG.get(analysis.category, "other")
    if not tag and not image and not (bagType and color):
        raise HTTPException(422, "Add the tag number, a photo, or the bag type and colour")
    zone_id, label = _resolve_zone(airport, location)
    bag = storage.insert("on_hand_bags", {
        "id": storage.new_id(), "airport": airport, "tagNumber": tag, "flight": baggage.normalize_flight(flight),
        "bagType": bagType or "other", "color": (color or "").lower() or None, "colorHex": color_hex, "brand": brand,
        "nameOnTag": nameOnTag, "zoneId": zone_id, "location": label, "notes": notes, "imageUrl": image_url,
        "embedding": embedding, "status": "on_hand", "reportId": None, "timestamp": storage.now(),
    })
    matched, candidates = None, []
    for report in storage.find("baggage_reports", airport=airport):
        if report["status"] in baggage.CLOSED or report.get("matchedBagId"):
            continue
        s, _ = baggage.score(_for_bag_matching(report), bag)
        if s >= 1.0 and not matched:
            matched = await _link_bag(report, bag, user)
        elif s >= 0.5:
            candidates.append({"reportId": report["id"], "ref": report["ref"], "score": s})
    return {"bag": _bag_view(storage.get("on_hand_bags", bag["id"])),
            "matchedReport": {"id": matched["id"], "ref": matched["ref"]} if matched else None,
            "candidates": sorted(candidates, key=lambda c: -c["score"])}


@app.get("/baggage/on-hand", tags=["Lost luggage"])
def list_on_hand_bags(airport: str | None = None, status: str | None = "on_hand", user: dict = Depends(require_staff)):
    code = _airport(airport)
    _check_staff_airport(user, code)
    return [_bag_view(b) for b in storage.find("on_hand_bags", airport=code, status=status)]


@app.get("/baggage-reports/{report_id}/qr", tags=["Lost luggage"])
def baggage_qr(report_id: str, token: str | None = None, user: dict | None = Depends(optional_user)):
    """QR of the delivery code (owner or staff; `?token=` works for plain image loaders)."""
    user = user or auth.user_for_token(token)
    if not user:
        raise HTTPException(401, "Please sign in")
    report = _get_bag_report(report_id, user)
    if report["status"] not in baggage.HANDOVER:
        raise HTTPException(409, "The delivery code is available once the bag is on its way to you")
    report = _ensure_handover(report)
    buf = io.BytesIO()
    qrcode.make(f"lostfound:bag:{report['handoverToken']}").save(buf, "PNG")
    return Response(buf.getvalue(), media_type="image/png")


def _bag_by_handover(value: str) -> dict:
    value = value.strip().removeprefix("lostfound:bag:")
    reports = storage.find("baggage_reports", handoverToken=value)
    if not reports:
        code = re.sub(r"[^A-Z0-9]", "", value.upper())
        if len(code) == 6:
            reports = storage.find("baggage_reports", handoverCode=code)
    if not reports:
        raise HTTPException(404, "Unknown delivery code")
    return reports[0]


@app.get("/baggage/handover/{code}", tags=["Lost luggage"])
def scan_baggage_handover(code: str, user: dict = Depends(require_staff)):
    """Driver / desk after scanning the passenger's delivery QR: the file and the bag to hand over."""
    return get_baggage_report(_bag_by_handover(code)["id"], user)


@app.post("/baggage/handover/{code}", tags=["Lost luggage"])
async def confirm_baggage_handover(code: str, user: dict = Depends(require_staff)):
    report = _get_bag_report(_bag_by_handover(code)["id"], user)
    if report["status"] not in baggage.HANDOVER:
        raise HTTPException(409, "This bag is not waiting to be handed over")
    await _bag_event(report, "delivered", user)
    if report.get("matchedBagId"):
        storage.update("on_hand_bags", report["matchedBagId"], status="delivered")
    return {"status": "delivered"}


# ---------------------------------------------------------------- Live chat (passenger <-> desk)

class ChatSend(BaseModel):
    text: str


def _chat_report(report_id: str, user: dict) -> dict:
    """The lost report or baggage file a conversation belongs to, if this user may take part in it."""
    report = storage.get("lost_reports", report_id)
    if not report and (bag := storage.get("baggage_reports", report_id)):
        report = {**baggage.as_case(bag), "staffId": bag.get("staffId"), "_table": "baggage_reports"}
    if not report:
        raise HTTPException(404, "Report not found")
    if auth.is_staff(user):
        _check_staff_airport(user, report.get("airport") or config.DEFAULT_AIRPORT)
    elif report["userId"] != user["id"]:
        raise HTTPException(403, "This belongs to another passenger")
    return report


def _side(user: dict) -> str:
    return "staff" if auth.is_staff(user) else "passenger"


def _chat_thread(report: dict, user: dict, messages: list[dict]) -> dict:
    """Conversation header: the report, the item it matched, who is on the other side, unread count."""
    staff = auth.is_staff(user)
    item = storage.get("found_items", report["matchedItemId"]) if report.get("matchedItemId") else None
    passenger = storage.get("users", report["userId"]) or {}
    agent = storage.get("users", report["staffId"]) if report.get("staffId") else None
    return {
        "report": _public_report({k: v for k, v in report.items() if k != "_table"}),
        "item": (_staff_item(item) if staff else _public_item(item, located=item["id"] in _approved_item_ids(user)))
        if item else None,
        "passengerName": passenger.get("name") or passenger.get("email", "").split("@")[0] if staff else None,
        "staffName": agent.get("name") if agent else None,
        "last": messages[-1] if messages else None,
        "unread": sum(1 for m in messages if m["senderRole"] != _side(user) and not m.get("read")),
    }


@app.get("/chats", tags=["Live chat"])
def list_chats(airport: str | None = None, user: dict = Depends(current_user)):
    """Staff: conversations at their airport (reports with a possible match or any message).
    Passengers: their own conversations. Newest activity first."""
    if auth.is_staff(user):
        code = _airport(airport)
        _check_staff_airport(user, code)
        reports = storage.find("lost_reports", airport=code)
        bags = storage.find("baggage_reports", airport=code)
    else:
        reports = storage.find("lost_reports", userId=user["id"])
        bags = storage.find("baggage_reports", userId=user["id"])
    out = []
    for r in reports + [{**baggage.as_case(b), "staffId": b.get("staffId")} for b in bags]:
        messages = storage.find("chat_messages", order="timestamp ASC", reportId=r["id"])
        # Baggage files can always be discussed; lost items once there is a possible match.
        if messages or r.get("matchedItemId") or (r.get("kind") == "baggage" and not auth.is_staff(user)):
            out.append(_chat_thread(r, user, messages))
    return sorted(out, key=lambda t: (t["last"] or t["report"])["timestamp"], reverse=True)


@app.get("/chats/{report_id}", tags=["Live chat"])
def chat_messages(report_id: str, user: dict = Depends(current_user)):
    """The conversation about a lost report; opening it marks the other side's messages as read."""
    report = _chat_report(report_id, user)
    storage.execute('UPDATE chat_messages SET "read" = 1 WHERE "reportId" = ? AND "senderRole" != ?',
                    (report_id, _side(user)))
    messages = storage.find("chat_messages", order="timestamp ASC", reportId=report_id)
    return {**_chat_thread(report, user, messages), "messages": messages}


@app.post("/chats/{report_id}", tags=["Live chat"])
async def send_chat_message(report_id: str, body: ChatSend, user: dict = Depends(current_user)):
    """Send a message; the passenger and the airport's desk get it live over /ws."""
    report = _chat_report(report_id, user)
    text = body.text.strip()
    if not text:
        raise HTTPException(422, "Write a message")
    if len(text) > 1000:
        raise HTTPException(422, "Messages can be at most 1000 characters")
    staff = auth.is_staff(user)
    airport = report.get("airport") or config.DEFAULT_AIRPORT
    if staff and not report.get("staffId"):
        # The first staff member to answer looks after this passenger from now on.
        storage.update(report.get("_table", "lost_reports"), report_id, staffId=user["id"])
        report = {**report, "staffId": user["id"]}
    msg = storage.insert("chat_messages", {
        "id": storage.new_id(),
        "reportId": report_id,
        "airport": airport,
        "senderId": user["id"],
        "senderRole": _side(user),
        "senderName": (user.get("name") or user["email"].split("@")[0]) if staff else None,
        "text": text,
        "timestamp": storage.now(),
        "read": 0,
    })
    await notifier.push(set(_desk_ids(airport)) | {report["userId"]}, {"type": "chat", "message": msg})
    return msg


@app.get("/health")
def health():
    return {"ok": True}


# ---------------------------------------------------------------- Developer tools

class ResetRequest(BaseModel):
    includeItems: bool = False


def _require_dev(key: str | None, user: dict | None = None):
    """Developer key (X-Dev-Key header) or a signed-in administrator."""
    if user and user["role"] == "admin":
        return
    if not key or not secrets.compare_digest(key, config.DEV_KEY):
        raise HTTPException(401, "Wrong developer key")


@app.get("/dev/check", tags=["Developer"])
def dev_check(x_dev_key: str | None = Header(None), user: dict | None = Depends(optional_user)):
    """Lets the app unlock its developer tools (send the key in the X-Dev-Key header)."""
    _require_dev(x_dev_key, user)
    return {"ok": True}


@app.post("/dev/reset", tags=["Developer"])
async def dev_reset(body: ResetRequest, x_dev_key: str | None = Header(None),
                    user: dict | None = Depends(optional_user)):
    """Demo reset: delete every passenger request (lost reports, claims, verification attempts,
    notifications) and put found items back on the shelf. With includeItems, empty the inventory too.
    Connected apps get a live {"type": "reset"} event and clear their screens."""
    _require_dev(x_dev_key, user)
    deleted = {t: storage.execute(f"DELETE FROM {t}")
               for t in ("lost_reports", "claims", "claim_attempts", "notifications", "chat_messages",
                         "baggage_reports", "bag_events")}
    prefixes = ("lost_",)
    if body.includeItems:
        deleted["found_items"] = storage.execute("DELETE FROM found_items")
        deleted["on_hand_bags"] = storage.execute("DELETE FROM on_hand_bags")
        prefixes += ("found_", "preview_")
    else:
        deleted["itemsBackOnShelf"] = storage.execute("UPDATE found_items SET status = 'available' WHERE status != 'available'")
        deleted["bagsBackOnHand"] = storage.execute(
            'UPDATE on_hand_bags SET "status" = \'on_hand\', "reportId" = NULL WHERE "status" != \'on_hand\'')
    deleted["photos"] = images.delete_prefixed(prefixes)
    log.warning("Developer reset: %s", deleted)
    await notifier.broadcast({"type": "reset"})
    return {"deleted": deleted}
