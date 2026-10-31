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
from fastapi import FastAPI, File, Form, HTTPException, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel

from . import config, matching, storage, vision

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("lostfound")


@asynccontextmanager
async def lifespan(_: FastAPI):
    # Load YOLO weights at startup so the first intake request is fast.
    await asyncio.to_thread(vision.warmup)
    yield


app = FastAPI(title="Smart Airport Lost & Found", version="0.1.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
app.mount("/images", StaticFiles(directory=config.IMAGES_DIR), name="images")


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


notifier = Notifier()


@app.websocket("/ws/{user_id}")
async def ws_notifications(ws: WebSocket, user_id: str):
    await notifier.connect(user_id, ws)
    try:
        while True:
            await ws.receive_text()  # keep-alive; client messages are ignored
    except WebSocketDisconnect:
        notifier.disconnect(user_id, ws)


@app.get("/users/{user_id}/notifications")
def list_notifications(user_id: str):
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
    name = f"{prefix}_{storage.new_id()}.jpg"
    img.thumbnail((1280, 1280))
    img.save(config.IMAGES_DIR / name, "JPEG", quality=85)
    return f"/images/{name}"


def _public_item(item: dict) -> dict:
    return {k: v for k, v in item.items() if k not in ("embedding", "secretDetail")}


def _public_report(report: dict) -> dict:
    return {k: v for k, v in report.items() if k != "embedding"}


def _public_match(m: dict) -> dict:
    return {"score": m["score"], "breakdown": m["breakdown"], "item": _public_item(m["item"])}


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
async def analyze_image(image: UploadFile = File(...)):
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
):
    airport = _airport(airport)
    img, _ = await _read_image(image)
    analysis = await asyncio.to_thread(vision.analyze, img)
    zone_id, label = _resolve_zone(airport, location)
    item = storage.insert("found_items", {
        "id": storage.new_id(),
        "airport": airport,
        "zoneId": zone_id,
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

    return {"item": _public_item(item), "ai": analysis.public(), "notifiedReports": notified}


@app.get("/found-items", tags=["Found Items"])
def list_found_items(airport: str | None = None, category: str | None = None, color: str | None = None,
                     zoneId: str | None = None, status: str | None = "available"):
    items = storage.find("found_items", airport=_airport(airport), category=category, color=color,
                         zoneId=zoneId, status=status)
    return [_public_item(i) for i in items]


@app.get("/found-items/{item_id}", tags=["Found Items"])
def get_found_item(item_id: str):
    item = storage.get("found_items", item_id)
    if not item:
        raise HTTPException(404, "Item not found")
    return _public_item(item)


# ---------------------------------------------------------------- Modul B: Passenger app

@app.post("/search/visual", tags=["Passenger"])
async def visual_search(image: UploadFile = File(...), limit: int = Form(10), airport: str | None = Form(None)):
    """Reverse image search: rank available found items by similarity to the passenger photo."""
    img, _ = await _read_image(image)
    analysis = await asyncio.to_thread(vision.analyze, img)
    query = {"category": analysis.category, "color": analysis.color, "embedding": analysis.embedding}
    matches = matching.rank(query, _available_items(_airport(airport)), limit=limit, min_score=0.2)
    return {"query": analysis.public(), "matches": [_public_match(m) for m in matches]}


@app.post("/lost-reports", tags=["Passenger"])
async def create_lost_report(
    userId: str = Form(...),
    description: str = Form(""),
    airport: str | None = Form(None),
    category: str | None = Form(None),
    color: str | None = Form(None),
    lastSeenLocation: str | None = Form(None),
    travelDate: str | None = Form(None, description="YYYY-MM-DD"),
    image: UploadFile | None = File(None),
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
        "userId": userId,
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
def list_lost_reports(userId: str | None = None, status: str | None = None):
    return [_public_report(r) for r in storage.find("lost_reports", userId=userId, status=status)]


@app.get("/lost-reports/{report_id}/matches", tags=["Passenger"])
def report_matches(report_id: str, limit: int = 10):
    report = storage.get("lost_reports", report_id)
    if not report:
        raise HTTPException(404, "Report not found")
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


def _public_claim(claim: dict) -> dict:
    """Passenger view: the answer stays private and the QR token only exists once approved."""
    out = {k: v for k, v in claim.items() if k != "answer"}
    if claim["status"] not in ("ready_for_pickup", "recovered"):
        out["token"] = None
    return out


def _claim_by_token(token: str) -> dict:
    claims = storage.find("claims", token=token.removeprefix("lostfound:claim:"))
    if not claims:
        raise HTTPException(404, "Unknown QR code")
    return claims[0]


def _staff_claim_view(claim: dict) -> dict:
    item = storage.get("found_items", claim["itemId"])
    return {
        "claim": claim,
        "item": {k: v for k, v in item.items() if k != "embedding"},  # staff sees secretDetail
        "report": _public_report(storage.get("lost_reports", claim["reportId"])),
    }


@app.post("/claims", tags=["Claim & Pick-up"])
def create_claim(body: ClaimCreate):
    report = storage.get("lost_reports", body.reportId)
    item = storage.get("found_items", body.itemId)
    if not report or not item:
        raise HTTPException(404, "Report or item not found")
    if item["status"] != "available":
        raise HTTPException(409, "Item is no longer available")
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
def list_claims(userId: str):
    """A passenger's claims with their review status (and pick-up token once approved)."""
    return [_public_claim(c) for c in storage.find("claims", userId=userId)]


@app.post("/claims/{claim_id}/answer", tags=["Claim & Pick-up"])
def answer_claim(claim_id: str, body: ClaimAnswer):
    claim = _get_claim(claim_id)
    if claim["status"] != "awaiting_answer":
        raise HTTPException(409, f"Claim is {claim['status']}")
    storage.update("claims", claim_id, answer=body.answer.strip(), status="under_review")
    return {"id": claim_id, "status": "under_review"}


@app.get("/claims/{claim_id}/qr", tags=["Claim & Pick-up"])
def claim_qr(claim_id: str):
    claim = _get_claim(claim_id)
    if claim["status"] not in ("ready_for_pickup", "recovered"):
        raise HTTPException(409, "The pick-up pass is available once staff approve the claim")
    buf = io.BytesIO()
    qrcode.make(f"lostfound:claim:{claim['token']}").save(buf, "PNG")
    return Response(buf.getvalue(), media_type="image/png")


# Ownership review (staff, remote) -----------------------------------------------------------

@app.get("/staff/claims", tags=["Claim & Pick-up"])
def staff_claims(status: str = "under_review"):
    """Claims waiting for an ownership decision, with the hidden detail to compare against."""
    return [_staff_claim_view(c) for c in storage.find("claims", status=status)]


@app.post("/staff/claims/{claim_id}/review", tags=["Claim & Pick-up"])
async def review_claim(claim_id: str, body: ClaimDecision):
    claim = _get_claim(claim_id)
    if claim["status"] != "under_review":
        raise HTTPException(409, f"Claim is {claim['status']}")
    if body.approved:
        storage.update("claims", claim_id, status="ready_for_pickup", reviewedAt=storage.now())
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

@app.get("/claims/scan/{token}", tags=["Claim & Pick-up"])
def scan_claim(token: str):
    """Operator view after scanning the QR: the passenger's answer next to the hidden details."""
    return _staff_claim_view(_claim_by_token(token))


@app.post("/claims/scan/{token}/decision", tags=["Claim & Pick-up"])
async def decide_claim(token: str, body: ClaimDecision):
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
