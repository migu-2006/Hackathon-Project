# SkyFindr — Backend (FastAPI + YOLO)

## Run

```powershell
cd backend
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
.venv\Scripts\python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Open http://localhost:8000/docs for the interactive API. YOLO weights (`yolo11n.pt`, `yolo11n-cls.pt`)
download automatically on first start. Data (SQLite + images) lives in `backend/data/`.

Optional OCR (brand / visible text): `pip install easyocr` and set `LF_ENABLE_OCR=1`.

## Tests

```powershell
.venv\Scripts\python -m pytest -q
```

## AI pipeline (`app/vision.py`)

1. **YOLO detection** (COCO) picks the most prominent relevant object and crops it.
2. **YOLO classification** (ImageNet) on the crop refines the type (wallet, glasses, keys…) and yields
   the **embedding** used for reverse image search.
3. **K-means** on the crop → dominant color name + hex.
4. **EasyOCR** (optional) → brand / visible text.

## Endpoints

| Module | Method | Path | Purpose |
|---|---|---|---|
| A – Smart Intake | POST | `/intake/analyze` | AI preview of a photo (type, color, text) |
| A – Smart Intake | POST | `/found-items` | Register found item (photo + zone); runs auto-match + notifications |
| | GET | `/found-items` | Filter by `category`, `color`, `location`, `status` |
| B – Passenger | POST | `/search/visual` | Reverse image search |
| B – Passenger | POST | `/lost-reports` | Report a lost item (optional photo); returns immediate matches |
| B – Passenger | GET | `/lost-reports/{id}/matches` | Ranked candidates with score breakdown |
| B – Passenger | GET | `/map/zones` | Terminal zones with pinned items for the map |
| B – Passenger | WS | `/ws/{userId}` | Realtime match notifications (also `GET /users/{id}/notifications`) |
| C – Claim | POST | `/claims` | Start a claim → returns verification question |
| C – Claim | POST | `/claims/{id}/answer` | Answer → claim ready, QR available |
| C – Claim | GET | `/claims/{id}/qr` | QR code PNG |
| C – Claim | GET | `/claims/scan/{token}` | Desk view after scanning (shows hidden `secretDetail`) |
| C – Claim | POST | `/claims/scan/{token}/decision` | Approve → item `claimed`, report `recovered` |

## Airports & maps

Two airports are configured in `app/config.py` (`AIRPORTS`): **LHR** London Heathrow and **CRA** Craiova.
Each has a map built from OpenStreetMap and stored in `app/maps/<IATA>.json` (terminal outlines,
indoor rooms per level, gates, shops/services, and the lost & found zones items are pinned to):

```powershell
.venv\Scripts\python -X utf8 tools\fetch_osm_map.py LHR EGLL "London Heathrow"
.venv\Scripts\python -X utf8 tools\fetch_osm_map.py CRA LRCV "Craiova International Airport"
```

Each point of interest has a coarse `kind` (food, shop, money, toilets, info, service), a fine `type`
(cafe, restaurant, atm, pharmacy, lounge… — one icon each in the app) and, when OSM has them, `info`
details (`hours` = raw `opening_hours`, cuisine, brand, operator, website, phone, wheelchair, airside)
shown when a passenger taps the icon.

Zones are real gates where OSM has them (139 at LHR), plus check-in / security / food / baggage /
arrivals per terminal, taken from OSM features or estimated inside the building when missing
(`"source": "estimated"`; Craiova has no indoor data, so all its zones are estimated). To add an airport, run
the tool with its IATA/ICAO codes and add an entry to `AIRPORTS`.

| Method | Path | Purpose |
|---|---|---|
| GET | `/airports` | Supported airports |
| GET | `/meta?airport=CRA` | Airport info + zones |
| GET | `/map/{IATA}` | Map geometry (metres) |
| GET | `/airports/{IATA}/zones` | Zones with the available items pinned on each |

Found items, lost reports, visual search and matching are scoped per airport (`airport` field).
Map data © OpenStreetMap contributors, ODbL.

## Matching (`app/matching.py`)

Weighted average of the signals both sides have: category (0.35), color (0.2), visual embedding (0.3),
text (0.1), location (0.05). A category mismatch vetoes the match unless the photos are near-identical.
Reports scoring ≥ `LF_MATCH_THRESHOLD` (default 0.55) trigger a notification.

Storage is SQLite behind `app/storage.py`; the schema mirrors `FoundItems` / `LostReports`, so it can be
swapped for Firestore/Supabase without touching the API.
