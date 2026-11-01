"""Smart Airport Lost & Found - FastAPI backend.

Run:  uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
Docs: http://localhost:8000/docs
"""
from __future__ import annotations

import asyncio
import io
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

from . import auth, config, images, matching, storage, vision
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


def _public_item(item: dict, reveal: bool = False) -> dict:
    """Passenger view: no hidden detail, and only the blurred photo unless the passenger
    found this item through a reverse image search (`reveal`)."""
    out = {k: v for k, v in item.items() if k not in ("embedding", "secretDetail", "previewUrl")}
    if not reveal:
        out["imageUrl"] = _preview_url(item)
    out["photoHidden"] = not reveal
    return out


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


async def _notify_match(report: dict, match: dict):
    item = match["item"]
    storage.update("lost_reports", report["id"], status="matched", matchedItemId=item["id"])
    await notifier.send(
        report["userId"],
        "Possible match found!",
        f"A {item['color']} {item['category']} was found at {item['location']}.",
        {"reportId": report["id"], "itemId": item["id"], "score": match["score"]},
    )


# ---------------------------------------------------------------- Modul A: Smart Intake (staff)

@app.post("/intake/analyze", tags=["Smart Intake"])
async def analyze_image(image: UploadFile = File(...), _: dict = Depends(require_staff)):
    """Preview the AI attributes before the operator confirms the intake."""
    img, _ = await _read_image(image)
    analysis = await asyncio.to_thread(vision.analyze, img)
    return analysis.public()


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
    analysis = await asyncio.to_thread(vision.analyze, img)
    zone_id, label = _resolve_zone(airport, location)
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
        "secretDetail": secretDetail,
        "embedding": analysis.embedding,
        "timestamp": storage.now(),
        "status": "available",
    })

    # Auto-match: notify every passenger at this airport still searching for something like this.
    notified = []
    for report in storage.find("lost_reports", status="searching", airport=airport):
        s, breakdown = matching.score(report, item)
        if s >= config.MATCH_THRESHOLD:
            await _notify_match(report, {"score": s, "breakdown": breakdown, "item": item})
            notified.append({"reportId": report["id"], "score": s})

    return {"item": _staff_item(item), "ai": analysis.public(), "notifiedReports": notified}


@app.get("/found-items", tags=["Found Items"])
def list_found_items(airport: str | None = None, category: str | None = None, color: str | None = None,
                     zoneId: str | None = None, status: str | None = "available", staff: bool = False,
                     user: dict | None = Depends(optional_user)):
    """Passengers get blurred photos; `staff=true` (inventory, staff accounts) gets the real ones."""
    if staff and not auth.is_staff(user):
        raise HTTPException(403, "Airport staff only")
    items = storage.find("found_items", airport=_airport(airport), category=category, color=color,
                         zoneId=zoneId, status=status)
    return [_staff_item(i) if staff else _public_item(i) for i in items]


@app.get("/found-items/{item_id}", tags=["Found Items"])
def get_found_item(item_id: str, staff: bool = False, user: dict | None = Depends(optional_user)):
    if staff and not auth.is_staff(user):
        raise HTTPException(403, "Airport staff only")
    item = storage.get("found_items", item_id)
    if not item:
        raise HTTPException(404, "Item not found")
    return _staff_item(item) if staff else _public_item(item)


# ---------------------------------------------------------------- Modul B: Passenger app

@app.post("/search/visual", tags=["Passenger"])
async def visual_search(image: UploadFile = File(...), limit: int = Form(10), airport: str | None = Form(None)):
    """Reverse image search: rank available found items by similarity to the passenger photo."""
    img, _ = await _read_image(image)
    analysis = await asyncio.to_thread(vision.analyze, img)
    query = {"category": analysis.category, "color": analysis.color, "embedding": analysis.embedding}
    matches = matching.rank(query, _available_items(_airport(airport)), limit=limit, min_score=0.2)
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
    travelDate: str | None = Form(None, description="YYYY-MM-DD"),
    image: UploadFile | None = File(None),
    user: dict = Depends(current_user),
):
    airport = _airport(airport)
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
        "lastSeenLocation": _resolve_zone(airport, lastSeenLocation)[1],
        "travelDate": travelDate,
        "imageUrl": imageUrl,
        "embedding": embedding,
        "timestamp": storage.now(),
        "status": "searching",
        "matchedItemId": None,
    })

    # The item may already be in the inventory.
    matches = matching.rank(report, _available_items(airport), limit=5, min_score=config.MATCH_THRESHOLD)
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
    matches = matching.rank(report, _available_items(report["airport"]), limit=limit, min_score=0.2)
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


@app.get("/airports/{airport}/zones", tags=["Airports & maps"])
def map_zones(airport: str | None = None):
    """Zones with the available found items pinned on each."""
    code = _airport(airport)
    items = _available_items(code)
    out = []
    for zone in config.zones(code):
        here = [_public_item(i) for i in items if i.get("zoneId") == zone["id"] or i["location"] == zone["label"]]
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
        if value.startswith("lostfound:claim:"):
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
    deleted = {t: storage.execute(f"DELETE FROM {t}") for t in ("lost_reports", "claims", "claim_attempts", "notifications")}
    prefixes = ("lost_",)
    if body.includeItems:
        deleted["found_items"] = storage.execute("DELETE FROM found_items")
        prefixes += ("found_", "preview_")
    else:
        deleted["itemsBackOnShelf"] = storage.execute("UPDATE found_items SET status = 'available' WHERE status != 'available'")
    deleted["photos"] = images.delete_prefixed(prefixes)
    log.warning("Developer reset: %s", deleted)
    await notifier.broadcast({"type": "reset"})
    return {"deleted": deleted}
