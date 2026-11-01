import io
import json
import os
import tempfile
import uuid

os.environ["LF_DATA_DIR"] = tempfile.mkdtemp()
os.environ["LF_ADMIN_EMAIL"] = "admin@test.app"
os.environ["LF_ADMIN_PASSWORD"] = "admin-pass"
# Tests use a throwaway SQLite file and image folder, never the Supabase project in backend/.env
# (set LF_TEST_SUPABASE=1 to run them against it on purpose).
if os.getenv("LF_TEST_SUPABASE") != "1":
    for key in ("DATABASE_URL", "SUPABASE_URL", "SUPABASE_SERVICE_KEY"):
        os.environ[key] = ""

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app import mailer, main, matching, storage, vision

# Verification emails are captured here instead of sent: {email: [codes, newest last]}.
SENT: dict[str, list[str]] = {}


def fake_analysis(category="backpack", color="black", emb=(1.0, 0.0, 0.0)):
    return vision.Analysis(category=category, label=category, confidence=0.9, color=color,
                           color_rgb=(10, 10, 10), text="", bbox=None, embedding=list(emb))


@pytest.fixture
def client(monkeypatch):
    """Signed-out client (public endpoints); its lifespan creates the first administrator."""
    monkeypatch.setattr(vision, "warmup", lambda: None)
    state = {"next": fake_analysis()}
    monkeypatch.setattr(vision, "analyze", lambda img: state["next"])
    monkeypatch.setattr(mailer, "send_verification_code",
                        lambda to, name, code, minutes: SENT.setdefault(to, []).append(code))
    with TestClient(main.app) as c:
        c.state = state
        yield c


def signed_in(token: str) -> TestClient:
    c = TestClient(main.app, headers={"Authorization": f"Bearer {token}"})
    c.user = c.get("/auth/me").json()
    return c


def login(client, email, password, role=None) -> TestClient:
    r = client.post("/auth/login", json={"email": email, "password": password, "role": role})
    assert r.status_code == 200, r.text
    return signed_in(r.json()["token"])


def admin(client) -> TestClient:
    return login(client, "admin@test.app", "admin-pass", role="admin")


def register(client, email, password="secret1", name="Pax") -> TestClient:
    """Sign-up + the emailed code, like a passenger in the app."""
    r = client.post("/auth/register", json={"email": email, "password": password, "name": name})
    assert r.status_code == 200 and r.json()["verificationRequired"], r.text
    r = client.post("/auth/verify", json={"email": email, "code": SENT[email.lower()][-1]})
    assert r.status_code == 200, r.text
    return signed_in(r.json()["token"])


def passenger(client, name="Pax") -> TestClient:
    return register(client, f"{uuid.uuid4().hex[:8]}@mail.com", name=name)


def staff(client) -> TestClient:
    email = f"staff-{uuid.uuid4().hex[:6]}@skyfindr.app"
    assert admin(client).post("/admin/users", json={"email": email, "password": "desk-pass", "name": "Desk",
                                                    "role": "staff"}).status_code == 200
    return login(client, email, "desk-pass", role="staff")


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


def test_accounts_and_roles(client):
    # Passengers sign themselves up (with the emailed code); emails are unique and case-insensitive.
    ana = register(client, "Ana@Mail.com", name="Ana")
    assert ana.user == ana.user | {"email": "ana@mail.com", "role": "passenger", "verified": True}
    assert "passwordHash" not in ana.user
    assert client.post("/auth/register", json={"email": "ana@mail.com", "password": "secret1", "name": "A"}).status_code == 409
    assert client.post("/auth/register", json={"email": "x@mail.com", "password": "123", "name": "X"}).status_code == 400
    assert client.post("/auth/login", json={"email": "ana@mail.com", "password": "wrong"}).status_code == 401
    ana = login(client, "ANA@mail.com", "secret1", role="passenger")
    assert ana.user["name"] == "Ana"

    # Portals: a passenger can't use the staff or admin sign-in.
    assert client.post("/auth/login", json={"email": "ana@mail.com", "password": "secret1", "role": "staff"}).status_code == 403
    assert client.post("/auth/login", json={"email": "ana@mail.com", "password": "secret1", "role": "admin"}).status_code == 403

    # Signed out / passenger / staff / admin access.
    assert client.get("/staff/claims").status_code == 401
    assert client.get("/lost-reports").status_code == 401
    assert ana.get("/staff/claims").status_code == 403
    assert ana.get("/found-items", params={"staff": True}).status_code == 403
    assert ana.get("/admin/users").status_code == 403
    desk = staff(client)
    assert desk.get("/staff/claims").status_code == 200
    assert desk.get("/admin/users").status_code == 403
    boss = admin(client)
    assert boss.get("/staff/claims").status_code == 200  # an administrator can do staff work too
    assert {"ana@mail.com", "admin@test.app"} <= {u["email"] for u in boss.get("/admin/users").json()}

    # Administrator: disable signs the user out everywhere; can't lock themselves out.
    assert boss.patch(f"/admin/users/{ana.user['id']}", json={"disabled": True}).json()["disabled"] == 1
    assert ana.get("/auth/me").status_code == 401
    assert client.post("/auth/login", json={"email": "ana@mail.com", "password": "secret1"}).status_code == 403
    boss.patch(f"/admin/users/{ana.user['id']}", json={"disabled": False, "password": "newpass"})
    ana = login(client, "ana@mail.com", "newpass")
    assert boss.patch(f"/admin/users/{boss.user['id']}", json={"role": "staff"}).status_code == 400
    assert boss.delete(f"/admin/users/{boss.user['id']}").status_code == 400

    # Change own password, sign out.
    assert ana.post("/auth/password", json={"currentPassword": "nope", "newPassword": "x123456"}).status_code == 400
    assert ana.post("/auth/password", json={"currentPassword": "newpass", "newPassword": "x123456"}).status_code == 200
    ana.post("/auth/logout")
    assert ana.get("/auth/me").status_code == 401


def test_sign_up_needs_the_emailed_code(client):
    email = "new.pax@mail.com"
    r = client.post("/auth/register", json={"email": email, "password": "secret1", "name": "New Pax"}).json()
    assert r == r | {"verificationRequired": True, "email": email} and "token" not in r
    code = SENT[email][-1]
    assert len(code) == 6 and code.isdigit()

    # No session before the code: signing in just asks for the code again (resend throttled).
    r = client.post("/auth/login", json={"email": email, "password": "secret1"}).json()
    assert r["verificationRequired"] and "token" not in r and len(SENT[email]) == 1
    assert client.post("/auth/resend", json={"email": email}).status_code == 429

    # Wrong codes count down, then the code is burned.
    wrong = "000000" if code != "000000" else "111111"
    r = client.post("/auth/verify", json={"email": email, "code": wrong})
    assert r.status_code == 400 and "4 attempt(s) left" in r.json()["detail"]
    for _ in range(4):
        client.post("/auth/verify", json={"email": email, "code": wrong})
    assert client.post("/auth/verify", json={"email": email, "code": code}).status_code == 429

    # A new code (after the cooldown) works, with spaces as typed from the email.
    uid = storage.find("users", email=email)[0]["id"]
    storage.update("verification_codes", uid, sentAt="2000-01-01T00:00:00+00:00")  # cooldown over
    assert client.post("/auth/resend", json={"email": email}).json()["ok"]
    code = SENT[email][-1]
    r = client.post("/auth/verify", json={"email": email, "code": f"{code[:3]} {code[3:]}"})
    assert r.status_code == 200 and r.json()["user"]["verified"] is True
    assert signed_in(r.json()["token"]).get("/auth/me").status_code == 200
    assert client.post("/auth/verify", json={"email": email, "code": code}).status_code == 400  # used up

    # Verified: normal sign-in, and the email can't be registered again.
    assert "token" in client.post("/auth/login", json={"email": email, "password": "secret1"}).json()
    assert client.post("/auth/register", json={"email": email, "password": "x123456", "name": "X"}).status_code == 409
    # Resend never reveals whether an address has an account.
    assert client.post("/auth/resend", json={"email": "nobody@mail.com"}).json()["ok"]

    # An expired code is refused.
    other = "late@mail.com"
    client.post("/auth/register", json={"email": other, "password": "secret1", "name": "Late"})
    uid = storage.find("users", email=other)[0]["id"]
    storage.update("verification_codes", uid, expiresAt="2000-01-01T00:00:00+00:00")
    r = client.post("/auth/verify", json={"email": other, "code": SENT[other][-1]})
    assert r.status_code == 400 and "expired" in r.json()["detail"]
    # Signing up again with the same (unverified) email starts over with a new code.
    client.post("/auth/register", json={"email": other, "password": "newpass", "name": "Late Again"})
    r = client.post("/auth/verify", json={"email": other, "code": SENT[other][-1]}).json()
    assert r["user"]["name"] == "Late Again"
    assert "token" in client.post("/auth/login", json={"email": other, "password": "newpass"}).json()

    # Staff created by an administrator need no code.
    assert staff(client).user["verified"] is True


def test_email_failure_is_reported(client, monkeypatch):
    def broken(*_):
        raise OSError("smtp down")
    monkeypatch.setattr(mailer, "send_verification_code", broken)
    r = client.post("/auth/register", json={"email": "fail@mail.com", "password": "secret1", "name": "F"})
    assert r.status_code == 502 and "email" in r.json()["detail"]


def test_passengers_only_see_their_own_data(client):
    desk = staff(client)
    zone = client.get("/meta", params={"airport": "CRA"}).json()["zones"][0]  # away from the LHR flow tests
    item = desk.post("/found-items", files={"image": png()}, data={"location": zone["id"], "airport": "CRA"}).json()["item"]
    ana, bob = passenger(client, "Ana"), passenger(client, "Bob")
    # userId in the form is ignored: the report belongs to whoever is signed in.
    report = ana.post("/lost-reports", data={"userId": bob.user["id"], "category": "backpack",
                                             "airport": "CRA"}).json()["report"]
    assert report["userId"] == ana.user["id"]
    assert bob.get("/lost-reports", params={"userId": ana.user["id"]}).json() == []
    assert bob.get(f"/lost-reports/{report['id']}/matches").status_code == 403
    assert bob.post("/claims", json={"reportId": report["id"], "itemId": item["id"]}).status_code == 403
    claim = ana.post("/claims", json={"reportId": report["id"], "itemId": item["id"]}).json()
    assert bob.post(f"/claims/{claim['id']}/answer", json={"answer": "x"}).status_code == 403
    assert bob.get(f"/users/{ana.user['id']}/notifications").status_code == 403
    assert bob.get(f"/claims/{claim['id']}/qr").status_code == 403
    assert desk.get("/lost-reports", params={"userId": ana.user["id"]}).json()[0]["id"] == report["id"]
    # Live notifications need the passenger's own token.
    with pytest.raises(Exception):
        with client.websocket_connect(f"/ws/{ana.user['id']}?token=wrong") as ws:
            ws.receive_json()


def test_items_only_match_reports_at_the_same_airport(client):
    desk, pax = staff(client), passenger(client)
    cra_zone = client.get("/meta", params={"airport": "CRA"}).json()["zones"][0]
    pax.post("/lost-reports", data={"category": "backpack", "color": "black", "airport": "LHR"})
    r = desk.post("/found-items", files={"image": png()}, data={"location": cra_zone["id"], "airport": "CRA"})
    assert r.json()["item"]["airport"] == "CRA" and r.json()["item"]["location"] == cra_zone["label"]
    assert r.json()["notifiedReports"] == []
    lhr_ids = {i["id"] for i in client.get("/found-items", params={"airport": "LHR"}).json()}
    assert r.json()["item"]["id"] not in lhr_ids


def test_full_flow(client):
    desk, pax = staff(client), passenger(client)
    gate = next(z for z in client.get("/meta").json()["zones"] if z["name"].startswith("Gate "))
    # Passenger reports first, nothing found yet.
    r = pax.post("/lost-reports", data={"description": "Black backpack with stickers",
                                        "category": "backpack", "lastSeenLocation": gate["id"],
                                        "travelDate": "2026-10-24"})
    assert r.status_code == 200 and r.json()["matches"] == []
    assert r.json()["report"]["color"] == "black"  # parsed from the description
    assert r.json()["report"]["airport"] == "LHR"
    report_id = r.json()["report"]["id"]

    # Staff intake triggers the auto-match notification.
    assert pax.post("/found-items", files={"image": png()}, data={"location": gate["id"]}).status_code == 403
    r = desk.post("/found-items", files={"image": png()},
                  data={"location": gate["id"], "secretDetail": "Lufthansa sticker"})
    assert r.status_code == 200
    item = r.json()["item"]
    assert item["location"] == gate["label"] and item["zoneId"] == gate["id"]
    assert item["secretDetail"] == "Lufthansa sticker" and "embedding" not in item  # staff intake view
    public = client.get(f"/found-items/{item['id']}").json()
    assert "secretDetail" not in public and "embedding" not in public
    assert r.json()["notifiedReports"][0]["reportId"] == report_id
    assert pax.get(f"/users/{pax.user['id']}/notifications").json()[0]["data"]["itemId"] == item["id"]

    zones = {z["id"]: z for z in desk.get("/airports/LHR/zones").json()}
    assert zones[gate["id"]]["count"] >= 1
    # Passengers don't see where items were found until their claim is approved.
    hidden = pax.get(f"/found-items/{item['id']}").json()
    assert hidden["locationHidden"] is True and hidden["location"] == "" and hidden["zoneId"] is None
    assert all(not z["items"] for z in pax.get("/airports/LHR/zones").json())
    assert pax.get("/found-items", params={"zoneId": gate["id"]}).status_code == 403
    assert gate["label"] not in pax.get(f"/users/{pax.user['id']}/notifications").json()[0]["body"]

    # Visual search finds it.
    r = client.post("/search/visual", files={"image": png()})
    assert any(m["item"]["id"] == item["id"] for m in r.json()["matches"])

    # Claim -> answer -> staff review -> QR -> desk scan -> recovered.
    claim = pax.post("/claims", json={"reportId": report_id, "itemId": item["id"]}).json()
    pax.post(f"/claims/{claim['id']}/answer", json={"answer": "Lufthansa sticker on the front"})
    listed = pax.get("/claims").json()
    assert listed[0]["status"] == "under_review" and listed[0]["token"] is None and "answer" not in listed[0]
    assert pax.get(f"/claims/{claim['id']}/qr").status_code == 409

    review = next(c for c in desk.get("/staff/claims").json() if c["claim"]["id"] == claim["id"])
    assert review["item"]["secretDetail"] == "Lufthansa sticker"
    assert review["claim"]["answer"] == "Lufthansa sticker on the front"
    desk.post(f"/staff/claims/{claim['id']}/review", json={"approved": True})
    # Approved: this passenger now sees where their item was found, and only that one.
    shown = pax.get(f"/found-items/{item['id']}").json()
    assert shown["locationHidden"] is False and shown["zoneId"] == gate["id"] and shown["location"] == gate["label"]
    pins = [i["id"] for z in pax.get("/airports/LHR/zones").json() for i in z["items"]]
    assert pins == [item["id"]]
    assert all(i["locationHidden"] for i in passenger(client).get("/found-items").json())
    approved = pax.get("/claims").json()[0]
    token, code = approved["token"], approved["pickupCode"]
    qr = pax.get(f"/claims/{claim['id']}/qr")
    assert qr.headers["content-type"] == "image/png"
    session = pax.headers["Authorization"].removeprefix("Bearer ")
    assert client.get(f"/claims/{claim['id']}/qr", params={"token": session}).status_code == 200  # Image.network

    # Desks without a phone: the typed pickup code (any case, with a dash) or a webcam photo of the QR.
    assert len(code) == 6
    typed = f"{code[:3].lower()}-{code[3:]}"
    assert pax.get(f"/claims/scan/{typed}").status_code == 403
    assert desk.get(f"/claims/scan/{typed}").json()["claim"]["id"] == claim["id"]
    assert desk.get("/claims/scan/ZZZZZZ").status_code == 404
    found = desk.post("/claims/scan-image", files={"image": ("qr.png", qr.content, "image/png")}).json()
    assert found == {"code": f"lostfound:claim:{token}"}
    assert desk.post("/claims/scan-image", files={"image": png()}).status_code == 422

    scan = desk.get(f"/claims/scan/lostfound:claim:{token}").json()
    assert scan["claim"]["status"] == "ready_for_pickup"
    assert desk.post(f"/claims/scan/{token}/decision", json={"approved": True}).json()["status"] == "recovered"
    assert client.get(f"/found-items/{item['id']}").json()["status"] == "claimed"
    assert pax.get("/lost-reports").json()[0]["status"] == "recovered"


def test_one_claim_per_item_and_no_automatic_check(client):
    desk, thief = staff(client), passenger(client, "Thief")
    gate = next(z for z in client.get("/meta").json()["zones"] if z["name"].startswith("Gate "))
    item = desk.post("/found-items", files={"image": png()},
                     data={"location": gate["id"], "secretDetail": "Engraved initials M.A. and a cat sticker"}).json()["item"]
    report = thief.post("/lost-reports", data={"description": "black backpack", "category": "backpack"}).json()["report"]

    # Opening the claim twice before sending reuses it.
    claim = thief.post("/claims", json={"reportId": report["id"], "itemId": item["id"]}).json()
    assert thief.post("/claims", json={"reportId": report["id"], "itemId": item["id"]}).json()["id"] == claim["id"]

    # Any description goes straight to staff review: no automatic comparison with the hidden detail.
    r = thief.post(f"/claims/{claim['id']}/answer", json={"answer": "a red keychain"}).json()
    assert r == {"id": claim["id"], "status": "under_review"}
    assert thief.post(f"/claims/{claim['id']}/answer", json={"answer": "a dog sticker"}).status_code == 409
    view = next(c for c in desk.get("/staff/claims").json() if c["claim"]["id"] == claim["id"])
    assert view["claim"]["answer"] == "a red keychain" and view["item"]["secretDetail"].startswith("Engraved")

    # Staff reject it: the passenger can't claim this item again.
    assert desk.post(f"/staff/claims/{claim['id']}/review", json={"approved": False}).status_code == 200
    again = thief.post("/claims", json={"reportId": report["id"], "itemId": item["id"]})
    assert again.status_code == 409 and "once" in again.json()["detail"]

    # The staff log keeps what was sent.
    uid = thief.user["id"]
    entry = next(g for g in desk.get("/staff/claim-attempts", params={"airport": "LHR"}).json() if g["userId"] == uid)
    assert [a["answer"] for a in entry["attempts"]] == ["a red keychain"]
    assert entry["attempts"][0]["result"] == "submitted"


def test_photos_are_blurred_until_reverse_image_search(client):
    desk = staff(client)
    gate = next(z for z in client.get("/meta").json()["zones"] if z["name"].startswith("Gate "))
    staff_view = desk.post("/found-items", files={"image": png()}, data={"location": gate["id"]}).json()["item"]
    real = staff_view["imageUrl"]
    assert real.startswith("/images/found_") and "previewUrl" not in staff_view

    # Every passenger listing shows only the blurred preview, never the real file.
    listed = next(i for i in client.get("/found-items").json() if i["id"] == staff_view["id"])
    single = client.get(f"/found-items/{staff_view['id']}").json()
    for view in (listed, single):
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
    stored = desk.get("/found-items", params={"staff": True}).json()
    assert best["imageUrl"] == next(i["imageUrl"] for i in stored if i["id"] == best["id"])
    if best["id"] == staff_view["id"]:
        assert best["imageUrl"] == real
    inventory = next(i for i in desk.get("/found-items", params={"staff": True}).json() if i["id"] == staff_view["id"])
    assert inventory["imageUrl"] == real


def test_developer_reset(client):
    from app import config

    desk, pax = staff(client), passenger(client)
    gate = next(z for z in client.get("/meta").json()["zones"] if z["name"].startswith("Gate "))
    item = desk.post("/found-items", files={"image": png()}, data={"location": gate["id"]}).json()["item"]
    report = pax.post("/lost-reports", data={"description": "black backpack", "category": "backpack"}).json()["report"]
    pax.post("/claims", json={"reportId": report["id"], "itemId": item["id"]})

    assert client.get("/dev/check").status_code == 401
    assert desk.get("/dev/check").status_code == 401  # staff isn't enough
    assert admin(client).get("/dev/check").json() == {"ok": True}  # an administrator is
    assert client.post("/dev/reset", json={}, headers={"X-Dev-Key": "nope"}).status_code == 401
    key = {"X-Dev-Key": config.DEV_KEY}
    assert client.get("/dev/check", headers=key).json() == {"ok": True}

    session = pax.headers["Authorization"].removeprefix("Bearer ")
    with client.websocket_connect(f"/ws/{pax.user['id']}?token={session}") as ws:
        r = client.post("/dev/reset", json={}, headers=key).json()
        assert ws.receive_json() == {"type": "reset"}
    assert r["deleted"]["lost_reports"] >= 1 and r["deleted"]["claims"] >= 1
    assert pax.get("/lost-reports").json() == []
    assert pax.get("/claims").json() == []
    assert any(i["id"] == item["id"] for i in client.get("/found-items").json())  # inventory kept
    assert pax.get("/auth/me").status_code == 200  # accounts survive a reset

    client.post("/dev/reset", json={"includeItems": True}, headers=key)
    assert client.get("/found-items").json() == []


def test_staff_see_only_their_airport(client):
    email = f"cra-{uuid.uuid4().hex[:6]}@skyfindr.app"
    assert admin(client).post("/admin/users", json={"email": email, "password": "desk-pass", "name": "CRA desk",
                                                    "role": "staff", "airport": "CRA"}).status_code == 200
    cra = login(client, email, "desk-pass", role="staff")
    zone = client.get("/meta", params={"airport": "CRA"}).json()["zones"][0]
    item = cra.post("/found-items", files={"image": png()}, data={"location": zone["id"], "airport": "CRA"}).json()["item"]

    # Inventory and map of their own airport, with the exact location of every item.
    listed = next(i for i in cra.get("/found-items", params={"airport": "CRA", "staff": True}).json() if i["id"] == item["id"])
    assert listed["zoneId"] == zone["id"] and listed["location"] == zone["label"]
    pins = {i["id"] for z in cra.get("/airports/CRA/zones").json() for i in z["items"]}
    assert item["id"] in pins

    # Another airport's inventory is off limits; administrators see every airport.
    assert cra.get("/found-items", params={"airport": "LHR", "staff": True}).status_code == 403
    assert cra.get("/airports/LHR/zones").status_code == 403
    assert admin(client).get("/found-items", params={"airport": "LHR", "staff": True}).status_code == 200


def test_route_limits_matching_and_find_items(client):
    desk, pax = staff(client), passenger(client)
    places = client.get("/airports/CRA/places").json()
    areas = {p["id"]: p for p in places if p["kind"] == "area"}
    poi = next(p for p in places if p["kind"] == "poi")
    assert poi["label"].startswith(poi["name"]) and "zoneIds" not in poi
    food, arrivals = "cra-terminal-2-food", "cra-terminal-2-arrivals"

    # The passenger walked through the food court and past a shop; nothing on the route yet.
    assert pax.post("/lost-reports", data={"category": "umbrella", "airport": "CRA",
                                           "route": json.dumps(["nowhere"])}).status_code == 422
    r = pax.post("/lost-reports", data={"category": "umbrella", "color": "blue", "airport": "CRA",
                                       "route": json.dumps([food, poi["id"]])}).json()["report"]
    assert r["route"] == [food, poi["id"]] and areas[food]["label"] in r["lastSeenLocation"]
    before = {i["id"] for i in pax.get("/found-items", params={"airport": "CRA", "onMyRoute": True}).json()}
    assert all(i["airport"] == "CRA" for i in desk.get("/found-items", params={"airport": "CRA", "staff": True}).json()
               if i["id"] in before) and not any(i["zoneId"] == arrivals for i in
                                                   desk.get("/found-items", params={"airport": "CRA", "staff": True}).json()
                                                   if i["id"] in before)

    # The same umbrella found off the route doesn't match or show; found on the route it does.
    away = desk.post("/found-items", files={"image": png()},
                     data={"location": arrivals, "airport": "CRA", "category": "umbrella", "color": "blue"}).json()
    near = desk.post("/found-items", files={"image": png()},
                     data={"location": food, "airport": "CRA", "category": "umbrella", "color": "blue"}).json()
    assert away["notifiedReports"] == [] and [n["reportId"] for n in near["notifiedReports"]] == [r["id"]]
    matched = [m["item"]["id"] for m in pax.get(f"/lost-reports/{r['id']}/matches").json()]
    assert near["item"]["id"] in matched and away["item"]["id"] not in matched
    shown = [i["id"] for i in pax.get("/found-items", params={"airport": "CRA", "onMyRoute": True}).json()]
    assert near["item"]["id"] in shown and away["item"]["id"] not in shown
    assert all(i["locationHidden"] for i in pax.get("/found-items", params={"airport": "CRA", "onMyRoute": True}).json())

    # Another passenger without a route sees nothing there; staff inventory is unaffected.
    assert passenger(client).get("/found-items", params={"airport": "CRA", "onMyRoute": True}).json() == []
    ids = {i["id"] for i in desk.get("/found-items", params={"airport": "CRA", "staff": True}).json()}
    assert {near["item"]["id"], away["item"]["id"]} <= ids


def test_passenger_hands_in_a_found_item(client):
    desk, finder, owner = staff(client), passenger(client), passenger(client)
    shop = next(p for p in client.get("/airports/CRA/places").json() if p["kind"] == "poi")
    food = "cra-terminal-2-food"
    lost = owner.post("/lost-reports", data={"category": "umbrella", "color": "blue", "airport": "CRA",
                                            "route": json.dumps([food, shop["id"]])}).json()["report"]

    assert finder.post("/handed-in", files={"image": png()},
                       data={"place": "nowhere", "description": "Blue umbrella", "airport": "CRA"}).status_code == 422
    assert desk.post("/handed-in", files={"image": png()},
                     data={"place": shop["id"], "description": "Blue umbrella", "airport": "CRA"}).status_code == 403
    r = finder.post("/handed-in", files={"image": png()},
                    data={"place": shop["id"], "description": "Blue umbrella by the ATM", "airport": "CRA",
                          "secretDetail": "Name tag inside"})
    assert r.status_code == 200, r.text
    item = r.json()["item"]
    assert item["source"] == "passenger" and item["location"] == shop["label"]
    assert "secretDetail" not in item and "reportedBy" not in item

    # It is in the staff inventory, marked as handed in, with the hidden detail and the finder.
    inv = {i["id"]: i for i in desk.get("/found-items", params={"airport": "CRA", "staff": True}).json()}
    assert inv[item["id"]]["source"] == "passenger" and inv[item["id"]]["secretDetail"] == "Name tag inside"
    assert inv[item["id"]]["reportedBy"] and inv[item["id"]]["zoneId"]
    assert [i["id"] for i in finder.get("/handed-in").json()] == [item["id"]]
    assert owner.get("/handed-in").json() == []

    # Other passengers never learn who found it; the finder can't claim it.
    shown = owner.get(f"/found-items/{item['id']}").json()
    assert "reportedBy" not in shown and shown["locationHidden"]
    mine = finder.post("/lost-reports", data={"category": "umbrella", "airport": "CRA", "route": json.dumps([food])})
    claim = finder.post("/claims", json={"reportId": mine.json()["report"]["id"], "itemId": item["id"]})
    assert claim.status_code == 403
    assert owner.post("/claims", json={"reportId": lost["id"], "itemId": item["id"]}).status_code == 200


def test_live_chat_between_passenger_and_desk(client):
    desk, pax, other = staff(client), passenger(client), passenger(client)
    r = pax.post("/lost-reports", data={"category": "keys", "color": "pink", "airport": "CRA",
                                       "route": json.dumps(["cra-terminal-2-baggage"])}).json()["report"]
    assert pax.get("/chats").json() == []  # no match, no messages yet

    # Only the passenger and the airport's staff can read or write.
    assert other.get(f"/chats/{r['id']}").status_code == 403
    assert other.post(f"/chats/{r['id']}", json={"text": "hi"}).status_code == 403
    assert pax.post(f"/chats/{r['id']}", json={"text": "   "}).status_code == 422
    assert pax.post(f"/chats/{r['id']}", json={"text": "x" * 1001}).status_code == 422

    sent = pax.post(f"/chats/{r['id']}", json={"text": "Did anyone find pink keys?"}).json()
    assert sent["senderRole"] == "passenger" and sent["senderName"] is None

    threads = desk.get("/chats", params={"airport": "CRA"}).json()
    mine = next(t for t in threads if t["report"]["id"] == r["id"])
    assert mine["unread"] == 1 and mine["passengerName"] and mine["staffName"] is None

    # Staff open it (read) and answer: they become the passenger's contact.
    convo = desk.get(f"/chats/{r['id']}").json()
    assert [m["text"] for m in convo["messages"]] == ["Did anyone find pink keys?"]
    assert next(t for t in desk.get("/chats", params={"airport": "CRA"}).json() if t["report"]["id"] == r["id"])["unread"] == 0
    reply = desk.post(f"/chats/{r['id']}", json={"text": "Yes, it is at the desk."}).json()
    assert reply["senderRole"] == "staff" and reply["senderName"]

    t = pax.get("/chats").json()[0]
    assert t["unread"] == 1 and t["staffName"] == reply["senderName"] and t["passengerName"] is None
    convo = pax.get(f"/chats/{r['id']}").json()
    assert [m["senderRole"] for m in convo["messages"]] == ["passenger", "staff"]
    assert pax.get("/chats").json()[0]["unread"] == 0

    # Staff of another airport can't join.
    email = f"lhr-{uuid.uuid4().hex[:6]}@skyfindr.app"
    assert admin(client).post("/admin/users", json={"email": email, "password": "desk-pass", "name": "Heathrow desk",
                                                    "role": "staff", "airport": "LHR"}).status_code == 200
    lhr = login(client, email, "desk-pass", role="staff")
    assert lhr.get(f"/chats/{r['id']}").status_code == 403
    assert lhr.post(f"/chats/{r['id']}", json={"text": "hi"}).status_code == 403


def test_lost_luggage_from_report_to_delivery(client):
    desk, pax, other = staff(client), passenger(client, name="Ana Pop"), passenger(client)
    form = {"flight": "ro 642", "flightDate": "2026-10-31", "airport": "CRA", "bagType": "suitcase", "color": "red",
            "deliveryMethod": "deliver", "deliveryAddress": "Str. Unirii 10, Craiova", "deliveryPhone": "+40 700 000 000",
            "contents": "Grey suit, camera charger"}

    # Validation: bad tag, nothing to identify the bag, delivery without an address, staff accounts.
    assert pax.post("/baggage-reports", data={**form, "tagNumbers": "12"}).status_code == 422
    assert pax.post("/baggage-reports", data={**form, "bagType": "", "color": ""}).status_code == 422
    assert pax.post("/baggage-reports", data={**form, "tagNumbers": "0281123456", "deliveryAddress": ""}).status_code == 422
    assert desk.post("/baggage-reports", data={**form, "tagNumbers": "0281123456"}).status_code == 403

    r = pax.post("/baggage-reports", data={**form, "tagNumbers": "0281 123 456, RO 654321"})
    assert r.status_code == 200, r.text
    file = r.json()
    assert file["tagNumbers"] == ["0281123456", "RO654321"] and file["flight"] == "RO642"
    assert file["status"] == "reported" and file["ref"].startswith("CRA-BG-") and file["handoverCode"] is None
    assert [e["kind"] for e in file["events"]] == ["reported"]
    assert other.get(f"/baggage-reports/{file['id']}").status_code == 403
    assert all(f["id"] != file["id"] for f in other.get("/baggage-reports").json())

    # Located in Bucharest, forwarded on the next flight.
    ev = lambda body: desk.post(f"/baggage-reports/{file['id']}/events", json=body)
    assert ev({"kind": "located"}).status_code == 422
    assert ev({"kind": "located", "station": "otp", "note": "Missed the connection"}).json()["status"] == "located"
    assert ev({"kind": "forwarded", "flight": "RO 644", "eta": "18:40"}).json()["status"] == "forwarded"

    # An unclaimed bag with a similar tag (same serial, other prefix) is only a suggestion...
    near = desk.post("/baggage/on-hand", files={"image": png()},
                     data={"airport": "CRA", "tagNumber": "0999654321", "bagType": "suitcase", "color": "red"}).json()
    assert near["matchedReport"] is None and [c["reportId"] for c in near["candidates"]] == [file["id"]]
    staff_view = desk.get(f"/baggage-reports/{file['id']}").json()
    assert staff_view["contents"] and staff_view["passengerName"] == "Ana Pop"
    assert near["bag"]["id"] in [s["bag"]["id"] for s in staff_view["suggestions"]]

    # ...the bag with the exact tag is matched on the spot and the passenger is told.
    exact = desk.post("/baggage/on-hand", data={"airport": "CRA", "tagNumber": "0281-123-456", "flight": "RO644",
                                               "location": "cra-terminal-2-baggage"}).json()
    assert exact["matchedReport"]["id"] == file["id"] and exact["bag"]["status"] == "matched"
    mine = pax.get(f"/baggage-reports/{file['id']}").json()
    assert mine["status"] == "arrived" and mine["events"][-1]["kind"] == "found_here"
    assert any(n["data"].get("baggageReportId") == file["id"] and n["title"] == "Your bag is here!"
               for n in pax.get(f"/users/{mine['userId']}/notifications").json())
    assert desk.post(f"/baggage-reports/{file['id']}/link", json={"bagId": near["bag"]["id"]}).status_code == 409

    # Out for delivery: the passenger gets a delivery code; the driver scans it and closes the file.
    assert ev({"kind": "out_for_delivery"}).json()["status"] == "out_for_delivery"
    code = pax.get(f"/baggage-reports/{file['id']}").json()["handoverCode"]
    assert code and len(code) == 6
    assert pax.get(f"/baggage-reports/{file['id']}/qr").headers["content-type"] == "image/png"
    assert pax.get(f"/baggage/handover/{code}").status_code == 403
    assert desk.get(f"/baggage/handover/{code.lower()}").json()["id"] == file["id"]
    assert desk.post(f"/baggage/handover/{code}").json() == {"status": "delivered"}
    assert desk.post(f"/baggage/handover/{code}").status_code == 409
    assert pax.get(f"/baggage-reports/{file['id']}").json()["status"] == "delivered"
    assert ev({"kind": "note", "note": "late"}).status_code == 409

    # The suggested bag is still waiting; a desk chat works on baggage files too.
    assert near["bag"]["id"] in [b["id"] for b in desk.get("/baggage/on-hand", params={"airport": "CRA"}).json()]
    assert pax.post(f"/chats/{file['id']}", json={"text": "Thanks!"}).status_code == 200
    assert other.get(f"/chats/{file['id']}").status_code == 403
    thread = next(t for t in desk.get("/chats", params={"airport": "CRA"}).json() if t["report"]["id"] == file["id"])
    assert thread["report"]["kind"] == "baggage" and thread["unread"] == 1


def test_baggage_report_finds_a_bag_already_at_the_desk(client):
    desk, pax = staff(client), passenger(client)
    desk.post("/baggage/on-hand", data={"airport": "CRA", "tagNumber": "0281777888", "bagType": "backpack", "color": "black"})
    r = pax.post("/baggage-reports", data={"flight": "W6 3121", "flightDate": "2026-10-31", "airport": "CRA",
                                          "tagNumbers": "0281777888", "deliveryMethod": "pickup"}).json()
    assert r["status"] == "arrived" and r["matchedBagId"]
    # Desk pickup: no delivery to an address.
    assert desk.post(f"/baggage-reports/{r['id']}/events", json={"kind": "out_for_delivery"}).status_code == 409
    assert desk.post(f"/baggage-reports/{r['id']}/events", json={"kind": "ready_for_pickup"}).json()["handoverCode"]
