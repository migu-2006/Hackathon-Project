"""Build an in-app airport map from OpenStreetMap.

    python tools/fetch_osm_map.py LHR EGLL "London Heathrow"
    python tools/fetch_osm_map.py CRA LRCV "Craiova International Airport"

Writes app/maps/<IATA>.json with terminal outlines, indoor rooms per level, gates, points of
interest and the lost & found zones (gates + check-in / security / baggage areas per terminal).
Coordinates are metres in a local projection (x right, y down), origin at the top-left.

Map data © OpenStreetMap contributors, ODbL 1.0.
"""
from __future__ import annotations

import json
import math
import re
import sys
import time
from pathlib import Path

import httpx

ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]
HEADERS = {"User-Agent": "skyfindr-hackathon/0.1", "Accept": "application/json"}
OUT_DIR = Path(__file__).resolve().parent.parent / "app" / "maps"

# Lost & found zone categories, how to recognise them and where to fall back inside a terminal
# (fractions of the terminal bounding box) when OSM has no such feature.
CATEGORIES = {
    "check-in": ("Check-in hall", (0.2, 0.75)),
    "security": ("Security", (0.4, 0.55)),
    "food": ("Food court", (0.55, 0.4)),
    "baggage": ("Baggage claim", (0.25, 0.3)),
    "arrivals": ("Arrivals hall", (0.15, 0.2)),
    "gates": ("Departure gates", (0.8, 0.3)),  # only used when OSM has no individual gates
}


def overpass(query: str) -> dict:
    last = None
    for attempt in range(6):
        url = ENDPOINTS[attempt % len(ENDPOINTS)]
        try:
            r = httpx.post(url, data={"data": query}, headers=HEADERS, timeout=180)
            if r.status_code == 200:
                return r.json()
            last = f"{url}: HTTP {r.status_code}"
        except httpx.HTTPError as exc:
            last = f"{url}: {exc}"
        print("  retrying,", last)
        time.sleep(3 + attempt * 2)
    raise SystemExit(f"Overpass unavailable ({last})")


# ---------------------------------------------------------------- geometry helpers

def simplify(points: list[tuple[float, float]], tol: float) -> list[tuple[float, float]]:
    """Douglas-Peucker."""
    if len(points) < 3:
        return points
    (x1, y1), (x2, y2) = points[0], points[-1]
    dx, dy = x2 - x1, y2 - y1
    norm = math.hypot(dx, dy) or 1e-9
    idx, dmax = 0, 0.0
    for i in range(1, len(points) - 1):
        px, py = points[i]
        d = abs(dy * px - dx * py + x2 * y1 - y2 * x1) / norm if norm > 1e-9 else math.hypot(px - x1, py - y1)
        if d > dmax:
            idx, dmax = i, d
    if dmax <= tol:
        return [points[0], points[-1]]
    return simplify(points[: idx + 1], tol)[:-1] + simplify(points[idx:], tol)


def area(poly) -> float:
    return abs(sum(x1 * y2 - x2 * y1 for (x1, y1), (x2, y2) in zip(poly, poly[1:] + poly[:1]))) / 2


def centroid(poly) -> tuple[float, float]:
    xs, ys = zip(*poly)
    return sum(xs) / len(xs), sum(ys) / len(ys)


def inside(pt, poly) -> bool:
    x, y = pt
    hit = False
    for (x1, y1), (x2, y2) in zip(poly, poly[1:] + poly[:1]):
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1 + 1e-12) + x1:
            hit = not hit
    return hit


def bbox(poly):
    xs, ys = zip(*poly)
    return min(xs), min(ys), max(xs), max(ys)


def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def levels_of(tags: dict) -> list[str]:
    raw = tags.get("level") or tags.get("level:ref")
    if not raw:
        return []
    out = []
    for part in raw.replace(",", ";").split(";"):
        part = part.strip()
        if re.fullmatch(r"-?\d+(\.\d+)?", part):
            out.append(str(int(float(part))) if float(part).is_integer() else part)
    return out


def classify(tags: dict) -> str | None:
    text = " ".join(str(v) for v in tags.values()).lower()
    if tags.get("aeroway") in ("check_in", "checkin") or "check-in" in text or "check in" in text:
        return "check-in"
    if "security" in text and tags.get("amenity") != "police":
        return "security"
    if tags.get("aeroway") in ("baggage_reclaim", "baggage_claim") or "baggage" in text or "reclaim" in text:
        return "baggage"
    if "arrival" in text or tags.get("aeroway") == "arrivals":
        return "arrivals"
    if tags.get("amenity") in ("cafe", "restaurant", "fast_food", "food_court", "bar", "pub"):
        return "food"
    return None


def poi_kind(tags: dict) -> str | None:
    if tags.get("amenity") in ("toilets",) or tags.get("toilets") == "yes":
        return "toilets"
    if tags.get("amenity") in ("cafe", "restaurant", "fast_food", "food_court", "bar", "pub", "ice_cream"):
        return "food"
    if "shop" in tags:
        return "shop"
    if tags.get("amenity") in ("lost_property_office", "lost_property"):
        return "lost-property"
    if tags.get("tourism") == "information" or tags.get("amenity") == "information":
        return "info"
    if tags.get("amenity") in ("atm", "bureau_de_change", "bank"):
        return "money"
    if poi_type(tags) not in (None, "shop"):
        return "service"
    return None


# Fine-grained POI type (one icon each in the app). Coarse kind above drives the colour.
AMENITY_TYPES = {
    "cafe": "cafe", "restaurant": "restaurant", "fast_food": "fast_food", "food_court": "food_court",
    "bar": "bar", "pub": "bar", "ice_cream": "ice_cream", "toilets": "toilets", "atm": "atm",
    "bureau_de_change": "currency", "bank": "bank", "pharmacy": "pharmacy", "lounge": "lounge",
    "place_of_worship": "prayer", "device_charging_station": "charging", "drinking_water": "water",
    "telephone": "telephone", "post_box": "post", "post_office": "post", "vending_machine": "vending",
    "information": "info", "lost_property_office": "lost_property", "lost_property": "lost_property",
    "car_rental": "car_rental", "police": "police", "clinic": "medical", "doctors": "medical",
    "first_aid": "medical", "luggage_locker": "luggage", "smoking_area": "smoking", "baby_changing": "baby",
    "internet_cafe": "wifi", "taxi": "taxi", "bus_station": "bus",
}
SHOP_TYPES = {
    "clothes": "clothes", "fashion": "clothes", "boutique": "clothes", "fashion_accessories": "clothes",
    "shoes": "shoes", "gift": "gift", "souvenir": "gift", "newsagent": "newsagent", "kiosk": "newsagent",
    "books": "books", "bag": "bag", "electronics": "electronics", "mobile_phone": "electronics",
    "computer": "electronics", "jewelry": "jewelry", "watches": "watch", "chemist": "pharmacy",
    "pharmacy": "pharmacy", "cosmetics": "beauty", "perfumery": "beauty", "beauty": "beauty",
    "department_store": "duty_free", "duty_free": "duty_free", "variety_store": "duty_free",
    "convenience": "convenience", "supermarket": "convenience", "alcohol": "alcohol", "wine": "alcohol",
    "optician": "optician", "toys": "toys", "tobacco": "tobacco", "e-cigarette": "tobacco",
    "confectionery": "sweets", "chocolate": "sweets", "travel_agency": "travel", "photo": "camera",
}


def poi_type(tags: dict) -> str | None:
    if tags.get("tourism") == "information":
        return "info"
    if "shop" in tags:
        return SHOP_TYPES.get(tags["shop"], "shop")
    return AMENITY_TYPES.get(tags.get("amenity", ""))


def poi_info(tags: dict) -> dict:
    """Useful OSM details for the tap-to-open card (only the keys that are present)."""
    keys = {
        "hours": ("opening_hours",), "cuisine": ("cuisine",), "brand": ("brand",), "operator": ("operator",),
        "website": ("website", "contact:website", "brand:website"), "phone": ("phone", "contact:phone"),
        "wheelchair": ("wheelchair",), "description": ("description",),
        "currency": ("currency:others",), "denomination": ("denomination",), "airside": ("airside",),
    }
    out = {}
    for k, alts in keys.items():
        v = next((tags[a] for a in alts if tags.get(a)), None)
        if v:
            out[k] = v
    if tags.get("drink:coffee") == "yes" or tags.get("cuisine") == "coffee_shop":
        out["coffee"] = "yes"
    return out


# ---------------------------------------------------------------- main

def build(code: str, icao: str, name: str) -> dict:
    print(f"[{code}] locating aerodrome {icao}")
    aero = overpass(f'[out:json][timeout:60];nwr["aeroway"="aerodrome"]["icao"="{icao}"];out bb;')["elements"]
    if not aero:
        raise SystemExit(f"No aerodrome with ICAO {icao} in OSM")
    b = aero[0].get("bounds") or {"minlat": aero[0]["lat"] - 0.01, "maxlat": aero[0]["lat"] + 0.01,
                                  "minlon": aero[0]["lon"] - 0.015, "maxlon": aero[0]["lon"] + 0.015}
    bb = f'{b["minlat"]},{b["minlon"]},{b["maxlat"]},{b["maxlon"]}'

    print(f"[{code}] downloading terminals, rooms, gates and points of interest")
    data = overpass(f"""
        [out:json][timeout:180];
        (
          way["aeroway"="terminal"]({bb});
          relation["aeroway"="terminal"]({bb});
          way["building"="terminal"]({bb});
          way["indoor"~"^(room|area|corridor)$"]({bb});
          nwr["aeroway"~"^(gate|check_in|checkin|baggage_reclaim)$"]({bb});
          node["amenity"]({bb});
          node["shop"]({bb});
          node["tourism"="information"]({bb});
        );
        out geom;
    """)["elements"]

    lat0 = (b["minlat"] + b["maxlat"]) / 2
    lon0 = (b["minlon"] + b["maxlon"]) / 2
    kx = 111320 * math.cos(math.radians(lat0))
    ky = 110540

    def proj(lat, lon):
        return ((lon - lon0) * kx, (lat0 - lat) * ky)

    def rings(el) -> list[list[tuple[float, float]]]:
        if el["type"] == "way" and "geometry" in el:
            return [[proj(p["lat"], p["lon"]) for p in el["geometry"]]]
        if el["type"] == "relation":
            return [[proj(p["lat"], p["lon"]) for p in m["geometry"]]
                    for m in el.get("members", []) if m.get("role") == "outer" and "geometry" in m]
        return []

    def point(el):
        if el["type"] == "node":
            return proj(el["lat"], el["lon"])
        r = rings(el)
        return centroid(r[0]) if r and r[0] else None

    terminals, rooms, gates, pois, cat_points = [], [], [], [], []
    for el in data:
        tags = el.get("tags", {})
        if tags.get("aeroway") == "terminal" or tags.get("building") == "terminal":
            for ring in rings(el):
                if len(ring) >= 4 and area(ring) > 400:
                    nm = re.sub(rf"^({name.split()[-1]}|{name})\s+", "", tags.get("name", "")).strip()
                    terminals.append({"name": nm, "poly": simplify(ring, 1.0)})
    if not terminals:
        raise SystemExit("No terminal buildings mapped for this airport")

    # Unnamed terminal parts take the name of the nearest named one ("Terminal" if none is named).
    named = [t for t in terminals if re.search(r"terminal|\bt\d", t["name"], re.I)]  # also "Terminalul" (ro)
    for t in terminals:
        if t not in named:
            c = centroid(t["poly"])
            t["name"] = min(named, key=lambda n: math.dist(c, centroid(n["poly"])))["name"] if named else (t["name"] or "Terminal")
    for t in terminals:
        m = re.search(r"terminal\w*\s*(\d)|\bt(\d)", t["name"], re.I)
        t["group"] = f"Terminal {m.group(1) or m.group(2)}" if m else t["name"]
    margin = 60.0  # metres around terminals that still count (piers, gates on the apron edge)

    def terminal_of(pt):
        for t in terminals:
            if inside(pt, t["poly"]):
                return t
        best = min(terminals, key=lambda t: min(math.dist(pt, p) for p in t["poly"]))
        return best if min(math.dist(pt, p) for p in best["poly"]) < margin else None

    for el in data:
        tags = el.get("tags", {})
        if tags.get("aeroway") == "terminal" or tags.get("building") == "terminal":
            continue
        pt = point(el)
        if pt is None:
            continue
        term = terminal_of(pt)
        if term is None:
            continue
        lv = levels_of(tags)
        if "indoor" in tags and el["type"] != "node":
            for ring in rings(el):
                if len(ring) >= 4:
                    rooms.append({
                        "levels": lv, "kind": tags["indoor"] if tags["indoor"] != "room" else (poi_kind(tags) or "room"),
                        "name": tags.get("name", ""), "poly": simplify(ring, 0.5),
                    })
        if tags.get("aeroway") == "gate":
            ref = tags.get("ref") or tags.get("name", "").replace("Gate", "").strip()
            if ref:
                gates.append({"ref": ref, "terminal": term["group"], "x": pt[0], "y": pt[1], "levels": lv})
            continue
        kind, typ = poi_kind(tags), poi_type(tags)
        if kind and typ and (el["type"] == "node" or tags.get("name")):
            poi = {"kind": kind, "type": typ, "name": tags.get("name", "") or tags.get("brand", ""),
                   "x": pt[0], "y": pt[1], "levels": lv}
            if info := poi_info(tags):
                poi["info"] = info
            pois.append(poi)
        cat = classify(tags)
        if cat:
            cat_points.append((term["group"], cat, pt, lv))

    # Shift everything so the map starts at (0, 0).
    all_pts = [p for t in terminals for p in t["poly"]]
    minx, miny, maxx, maxy = bbox(all_pts)
    pad = 40.0
    ox, oy = minx - pad, miny - pad

    def sh(p):
        return [round(p[0] - ox, 1), round(p[1] - oy, 1)]

    for t in terminals:
        t["poly"] = [sh(p) for p in t["poly"]]
    for r in rooms:
        r["poly"] = [sh(p) for p in r["poly"]]
    for g in gates + pois:
        g["x"], g["y"] = sh((g["x"], g["y"]))

    # ---------------------------------------------------------------- zones
    zones = []
    groups: dict[str, list[dict]] = {}
    for t in terminals:
        groups.setdefault(t["group"], []).append(t)
    def near(a, b, dist=50.0):
        return min(math.dist(p, q) for p in a["poly"][::2] for q in b["poly"][::2]) < dist

    def pull_inside(pt, poly):
        """Move an estimated point toward the centroid until it lies inside the outline."""
        cx, cy = centroid(poly)
        for k in range(11):
            q = (pt[0] + (cx - pt[0]) * k / 10, pt[1] + (cy - pt[1]) * k / 10)
            if inside(q, poly):
                return q
        return cx, cy

    for group, parts in sorted(groups.items()):
        # The passenger building is the part with the most shops/services; size breaks ties.
        def score(t):
            return (sum(inside((p["x"], p["y"]), t["poly"]) for p in pois), area(t["poly"]))

        main = max(parts, key=score)
        x0, y0, x1, y1 = bbox(main["poly"])
        has_gates = any(g["terminal"] == group for g in gates)
        # No gates and no services: a closed or non-passenger building (e.g. LHR Terminal 1).
        if not has_gates and not any(score(t)[0] for t in parts):
            print(f"  skipping zones for {group} (no gates or services mapped)")
            continue
        piers = sorted((t for t in parts if t is not main and near(t, main)), key=lambda t: -area(t["poly"]))
        for cat, (label, (fx, fy)) in CATEGORIES.items():
            if cat == "gates" and has_gates:
                continue
            pts = [(sh(p), lv) for g, c, p, lv in cat_points if g == group and c == cat]
            if pts:
                x = sum(p[0] for p, _ in pts) / len(pts)
                y = sum(p[1] for p, _ in pts) / len(pts)
                level, source = (pts[0][1][0] if pts[0][1] else None), "osm"
            elif cat == "gates" and piers:
                (x, y), level, source = centroid(piers[0]["poly"]), None, "estimated"
            else:
                x, y = pull_inside((x0 + (x1 - x0) * fx, y0 + (y1 - y0) * fy), main["poly"])
                level, source = None, "estimated"
            zones.append({"id": f"{code.lower()}-{slug(group)}-{cat}", "name": label, "terminal": group,
                          "x": round(x, 1), "y": round(y, 1), "level": level, "source": source})
    seen = set()
    for g in sorted(gates, key=lambda g: (g["terminal"], len(g["ref"]), g["ref"])):
        zid = f"{code.lower()}-gate-{slug(g['ref'])}"
        if zid in seen:
            continue
        seen.add(zid)
        zones.append({"id": zid, "name": f"Gate {g['ref']}", "terminal": g["terminal"], "x": g["x"], "y": g["y"],
                      "level": g["levels"][0] if g["levels"] else None, "source": "osm"})

    levels = sorted({lv for r in rooms for lv in r["levels"]} | {lv for p in pois for lv in p["levels"]}, key=float)
    return {
        "code": code,
        "icao": icao,
        "name": name,
        "width": round(maxx - minx + 2 * pad, 1),
        "height": round(maxy - miny + 2 * pad, 1),
        "levels": levels,
        "terminals": [{"name": t["name"], "group": t["group"], "poly": t["poly"]} for t in terminals],
        "rooms": rooms,
        "gates": [{k: g[k] for k in ("ref", "terminal", "x", "y", "levels")} for g in gates],
        "pois": pois,
        "zones": zones,
        "attribution": "© OpenStreetMap contributors (ODbL)",
    }


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    code, icao, name = sys.argv[1].upper(), sys.argv[2].upper(), sys.argv[3]
    result = build(code, icao, name)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out = OUT_DIR / f"{code}.json"
    out.write_text(json.dumps(result, separators=(",", ":"), ensure_ascii=False), encoding="utf-8")
    print(f"[{code}] {len(result['terminals'])} terminal parts, {len(result['rooms'])} rooms, "
          f"{len(result['gates'])} gates, {len(result['pois'])} POIs, {len(result['zones'])} zones, "
          f"levels {result['levels']}, {result['width']:.0f}x{result['height']:.0f} m -> {out} "
          f"({out.stat().st_size // 1024} KB)")
