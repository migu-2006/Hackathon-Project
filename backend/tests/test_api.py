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
    assert "secretDetail" not in item and "embedding" not in item
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
