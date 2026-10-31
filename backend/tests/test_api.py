import io
import os
import tempfile

os.environ["LF_DATA_DIR"] = tempfile.mkdtemp()

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app import main, matching, vision


def fake_analysis(category="backpack", color="black", emb=(1.0, 0.0, 0.0)):
    return vision.Analysis(category=category, label=category, confidence=0.9, color=color,
                           color_rgb=(10, 10, 10), text="", bbox=None, embedding=list(emb))


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(vision, "warmup", lambda: None)
    state = {"next": fake_analysis()}
    monkeypatch.setattr(vision, "analyze", lambda img: state["next"])
    with TestClient(main.app) as c:
        c.state = state
        yield c


def png():
    buf = io.BytesIO()
    Image.new("RGB", (32, 32), "black").save(buf, "PNG")
    return ("item.png", buf.getvalue(), "image/png")


def test_color_name():
    assert vision.color_name((10, 10, 10)) == "black"
    assert vision.color_name((250, 250, 250)) == "white"
    assert vision.color_name((200, 30, 30)) == "red"
    assert vision.color_name((30, 70, 200)) == "blue"


def test_category_mismatch_vetoes():
    s, _ = matching.score({"category": "laptop", "color": "black"}, {"category": "backpack", "color": "black"})
    assert s == 0


def test_airports_and_maps(client):
    codes = {a["code"] for a in client.get("/airports").json()}
    assert codes == {"LHR", "CRA"}
    for code in codes:
        m = client.get(f"/map/{code}").json()
        assert m["terminals"] and m["zones"] and "OpenStreetMap" in m["attribution"]
        meta = client.get("/meta", params={"airport": code}).json()
        assert meta["airport"]["code"] == code and all(" · " in z["label"] for z in meta["zones"])
    assert client.get("/map/XXX").status_code == 404


def test_items_only_match_reports_at_the_same_airport(client):
    cra_zone = client.get("/meta", params={"airport": "CRA"}).json()["zones"][0]
    client.post("/lost-reports", data={"userId": "u-lhr", "category": "backpack", "color": "black", "airport": "LHR"})
    r = client.post("/found-items", files={"image": png()}, data={"location": cra_zone["id"], "airport": "CRA"})
    assert r.json()["item"]["airport"] == "CRA" and r.json()["item"]["location"] == cra_zone["label"]
    assert r.json()["notifiedReports"] == []
    lhr_ids = {i["id"] for i in client.get("/found-items", params={"airport": "LHR"}).json()}
    assert r.json()["item"]["id"] not in lhr_ids


def test_full_flow(client):
    gate = next(z for z in client.get("/meta").json()["zones"] if z["name"].startswith("Gate "))
    # Passenger reports first, nothing found yet.
    r = client.post("/lost-reports", data={"userId": "u1", "description": "Black backpack with stickers",
                                           "category": "backpack", "lastSeenLocation": gate["id"],
                                           "travelDate": "2026-10-24"})
    assert r.status_code == 200 and r.json()["matches"] == []
    assert r.json()["report"]["color"] == "black"  # parsed from the description
    assert r.json()["report"]["airport"] == "LHR"
    report_id = r.json()["report"]["id"]

    # Staff intake triggers the auto-match notification.
    r = client.post("/found-items", files={"image": png()},
                    data={"location": gate["id"], "secretDetail": "Lufthansa sticker"})
    assert r.status_code == 200
    item = r.json()["item"]
    assert item["location"] == gate["label"] and item["zoneId"] == gate["id"]
    assert item["secretDetail"] == "Lufthansa sticker" and "embedding" not in item  # staff intake view
    public = client.get(f"/found-items/{item['id']}").json()
    assert "secretDetail" not in public and "embedding" not in public
    assert r.json()["notifiedReports"][0]["reportId"] == report_id
    assert client.get("/users/u1/notifications").json()[0]["data"]["itemId"] == item["id"]

    zones = {z["id"]: z for z in client.get("/airports/LHR/zones").json()}
    assert zones[gate["id"]]["count"] == 1

    # Visual search finds it.
    r = client.post("/search/visual", files={"image": png()})
    assert r.json()["matches"][0]["item"]["id"] == item["id"]

    # Claim -> answer -> staff review -> QR -> desk scan -> recovered.
    claim = client.post("/claims", json={"reportId": report_id, "itemId": item["id"]}).json()
    client.post(f"/claims/{claim['id']}/answer", json={"answer": "Lufthansa sticker on the front"})
    listed = client.get("/claims", params={"userId": "u1"}).json()
    assert listed[0]["status"] == "under_review" and listed[0]["token"] is None and "answer" not in listed[0]
    assert client.get(f"/claims/{claim['id']}/qr").status_code == 409

    review = client.get("/staff/claims").json()
    assert review[0]["item"]["secretDetail"] == "Lufthansa sticker"
    assert review[0]["claim"]["answer"] == "Lufthansa sticker on the front"
    client.post(f"/staff/claims/{claim['id']}/review", json={"approved": True})
    token = client.get("/claims", params={"userId": "u1"}).json()[0]["token"]
    assert client.get(f"/claims/{claim['id']}/qr").headers["content-type"] == "image/png"

    scan = client.get(f"/claims/scan/lostfound:claim:{token}").json()
    assert scan["claim"]["status"] == "ready_for_pickup"
    assert client.post(f"/claims/scan/{token}/decision", json={"approved": True}).json()["status"] == "recovered"
    assert client.get(f"/found-items/{item['id']}").json()["status"] == "claimed"
    assert client.get("/lost-reports", params={"userId": "u1"}).json()[0]["status"] == "recovered"


def test_wrong_answers_lock_the_item(client):
    gate = next(z for z in client.get("/meta").json()["zones"] if z["name"].startswith("Gate "))
    item = client.post("/found-items", files={"image": png()},
                       data={"location": gate["id"], "secretDetail": "Engraved initials M.A. and a cat sticker"}).json()["item"]
    report = client.post("/lost-reports", data={"userId": "thief", "description": "black backpack",
                                                "category": "backpack"}).json()["report"]

    claim = client.post("/claims", json={"reportId": report["id"], "itemId": item["id"]}).json()
    assert claim["attemptsLeft"] == 3
    r = client.post(f"/claims/{claim['id']}/answer", json={"answer": "a red keychain"}).json()
    assert r == r | {"status": "awaiting_answer", "correct": False, "attemptsLeft": 2}
    # A new claim for the same item does not reset the counter.
    claim = client.post("/claims", json={"reportId": report["id"], "itemId": item["id"]}).json()
    assert claim["attemptsLeft"] == 2
    client.post(f"/claims/{claim['id']}/answer", json={"answer": "a dog sticker"})
    r = client.post(f"/claims/{claim['id']}/answer", json={"answer": "nothing special"}).json()
    assert r["status"] == "locked" and r["attemptsLeft"] == 0 and "desk" in r["message"]
    assert client.post("/claims", json={"reportId": report["id"], "itemId": item["id"]}).status_code == 423

    log = client.get("/staff/claim-attempts", params={"airport": "LHR", "lockedOnly": True}).json()
    entry = next(g for g in log if g["userId"] == "thief")
    assert entry["locked"] and entry["failed"] == 3 and len(entry["attempts"]) == 3
    assert entry["attempts"][0]["answer"] == "nothing special"  # newest first
    assert entry["item"]["secretDetail"].startswith("Engraved")

    # Staff unlock after checking ID: the log is kept, the passenger can answer again (typos tolerated).
    assert client.post("/staff/claim-attempts/unlock", json={"userId": "thief", "itemId": item["id"]}).json()["cleared"] == 3
    claim = client.post("/claims", json={"reportId": report["id"], "itemId": item["id"]}).json()
    assert claim["attemptsLeft"] == 3
    r = client.post(f"/claims/{claim['id']}/answer", json={"answer": "it has a cat stiker and my initals engraved"}).json()
    assert r["status"] == "under_review" and r["correct"] is True
    entry = next(g for g in client.get("/staff/claim-attempts").json() if g["userId"] == "thief")
    assert not entry["locked"] and len(entry["attempts"]) == 4
    assert client.get("/staff/claims").json()[0]["failedAttempts"] == 0


def test_photos_are_blurred_until_reverse_image_search(client):
    gate = next(z for z in client.get("/meta").json()["zones"] if z["name"].startswith("Gate "))
    staff = client.post("/found-items", files={"image": png()}, data={"location": gate["id"]}).json()["item"]
    real = staff["imageUrl"]
    assert real.startswith("/images/found_") and "previewUrl" not in staff

    # Every passenger listing shows only the blurred preview, never the real file.
    listed = next(i for i in client.get("/found-items").json() if i["id"] == staff["id"])
    single = client.get(f"/found-items/{staff['id']}").json()
    pinned = next(i for z in client.get("/airports/LHR/zones").json() for i in z["items"] if i["id"] == staff["id"])
    for view in (listed, single, pinned):
        assert view["photoHidden"] is True
        assert view["imageUrl"].startswith("/images/preview_") and view["imageUrl"] != real
    assert client.get(listed["imageUrl"]).status_code == 200

    # Reverse image search reveals the real photo of the best match only; staff views always have it.
    matches = client.post("/search/visual", files={"image": png()}).json()["matches"]
    assert len(matches) > 1 and matches[0]["score"] >= matches[1]["score"]
    assert [m["item"]["photoHidden"] for m in matches] == [False] + [True] * (len(matches) - 1)
    for m in matches[1:]:
        assert m["item"]["imageUrl"].startswith("/images/preview_")
    best = matches[0]["item"]
    stored = client.get("/found-items", params={"staff": True}).json()
    assert best["imageUrl"] == next(i["imageUrl"] for i in stored if i["id"] == best["id"])
    if best["id"] == staff["id"]:
        assert best["imageUrl"] == real
    inventory = next(i for i in client.get("/found-items", params={"staff": True}).json() if i["id"] == staff["id"])
    assert inventory["imageUrl"] == real


def test_developer_reset(client):
    from app import config

    gate = next(z for z in client.get("/meta").json()["zones"] if z["name"].startswith("Gate "))
    item = client.post("/found-items", files={"image": png()}, data={"location": gate["id"]}).json()["item"]
    report = client.post("/lost-reports", data={"userId": "dev-u", "description": "black backpack",
                                                "category": "backpack"}).json()["report"]
    client.post("/claims", json={"reportId": report["id"], "itemId": item["id"]})

    assert client.get("/dev/check").status_code == 401
    assert client.post("/dev/reset", json={}, headers={"X-Dev-Key": "nope"}).status_code == 401
    key = {"X-Dev-Key": config.DEV_KEY}
    assert client.get("/dev/check", headers=key).json() == {"ok": True}

    with client.websocket_connect("/ws/dev-u") as ws:
        r = client.post("/dev/reset", json={}, headers=key).json()
        assert ws.receive_json() == {"type": "reset"}
    assert r["deleted"]["lost_reports"] >= 1 and r["deleted"]["claims"] >= 1
    assert client.get("/lost-reports", params={"userId": "dev-u"}).json() == []
    assert client.get("/claims", params={"userId": "dev-u"}).json() == []
    assert any(i["id"] == item["id"] for i in client.get("/found-items").json())  # inventory kept

    client.post("/dev/reset", json={"includeItems": True}, headers=key)
    assert client.get("/found-items").json() == []
