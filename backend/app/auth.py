"""Accounts and sign-in: passengers register themselves, the administrator creates staff.

Passwords are stored as salted scrypt hashes; a sign-in returns a random bearer token whose
SHA-256 is kept in `sessions` (a leaked database can't be replayed as live sessions).
"""
from __future__ import annotations

import hashlib
import hmac
import logging
import re
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel

from . import config, mailer, storage

log = logging.getLogger("lostfound")
router = APIRouter(tags=["Accounts"])

ROLES = ("passenger", "staff", "admin")
SESSION_DAYS = 30
CODE_MINUTES = 10        # a verification code expires after this
CODE_ATTEMPTS = 5        # wrong guesses before the code is burned (new one needed)
RESEND_SECONDS = 60      # minimum gap between two emails to the same account
_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


# ---------------------------------------------------------------- passwords & tokens

def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=1)
    return f"scrypt${salt.hex()}${digest.hex()}"


def check_password(password: str, stored: str | None) -> bool:
    try:
        _, salt, digest = (stored or "").split("$")
        test = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt), n=2**14, r=8, p=1)
        return hmac.compare_digest(test.hex(), digest)
    except ValueError:
        return False


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _new_session(user: dict) -> str:
    token = secrets.token_urlsafe(32)
    storage.insert("sessions", {
        "id": _token_hash(token), "userId": user["id"], "timestamp": storage.now(),
        "expiresAt": (datetime.now(timezone.utc) + timedelta(days=SESSION_DAYS)).isoformat(),
    })
    return token


def public_user(user: dict) -> dict:
    out = {k: user.get(k) for k in ("id", "email", "name", "role", "airport", "disabled", "timestamp")}
    out["verified"] = is_verified(user)
    return out


def _check_password_rules(password: str):
    if len(password) < 6:
        raise HTTPException(400, "Password must be at least 6 characters")


def _normalize_email(email: str) -> str:
    email = email.strip().lower()
    if not _EMAIL.match(email):
        raise HTTPException(400, "Enter a valid email address")
    return email


def _user_by_email(email: str) -> dict | None:
    found = storage.find("users", email=email)
    return found[0] if found else None


def user_for_token(token: str | None) -> dict | None:
    if not token:
        return None
    session = storage.get("sessions", _token_hash(token))
    if not session or session["expiresAt"] < storage.now():
        return None
    user = storage.get("users", session["userId"])
    return user if user and not user.get("disabled") and is_verified(user) else None


# ---------------------------------------------------------------- dependencies

def optional_user(authorization: str | None = Header(None)) -> dict | None:
    """The signed-in user, or None for public endpoints."""
    token = authorization.removeprefix("Bearer ").strip() if authorization else None
    return user_for_token(token)


def current_user(user: dict | None = Depends(optional_user)) -> dict:
    if not user:
        raise HTTPException(401, "Please sign in")
    return user


def is_staff(user: dict | None) -> bool:
    return bool(user) and user["role"] in ("staff", "admin")


def require_staff(user: dict = Depends(current_user)) -> dict:
    if not is_staff(user):
        raise HTTPException(403, "Airport staff only")
    return user


def require_admin(user: dict = Depends(current_user)) -> dict:
    if user["role"] != "admin":
        raise HTTPException(403, "Administrator only")
    return user


def require_self_or_staff(user: dict, owner_id: str | None):
    """Passengers only see their own reports, claims and notifications; staff see everyone's."""
    if not is_staff(user) and owner_id != user["id"]:
        raise HTTPException(403, "This belongs to another passenger")


# ---------------------------------------------------------------- sign up / in / out

class Register(BaseModel):
    email: str
    password: str
    name: str


class Login(BaseModel):
    email: str
    password: str
    role: str | None = None  # portal the user signed in from: passenger / staff / admin


# ---------------------------------------------------------------- email verification (sign-up)

def is_verified(user: dict) -> bool:
    # SQLite may hand the flag back as text; NULL means an account from before verification existed.
    return str(user.get("verified")) not in ("0", "False")


def _code_hash(user_id: str, code: str) -> str:
    return hashlib.sha256(f"{user_id}:{code}".encode()).hexdigest()


def _send_code(user: dict, force: bool = False) -> None:
    """Emails a fresh 6-digit code (replacing the old one), at most once per RESEND_SECONDS."""
    existing = storage.get("verification_codes", user["id"])
    if existing and not force:
        wait = RESEND_SECONDS - (datetime.now(timezone.utc) - datetime.fromisoformat(existing["sentAt"])).total_seconds()
        if wait > 0:
            raise HTTPException(429, f"Please wait {int(wait) + 1} seconds before asking for another code")
    code = f"{secrets.randbelow(10**6):06d}"
    try:
        mailer.send_verification_code(user["email"], user["name"], code, CODE_MINUTES)
    except Exception:
        log.exception("Verification email to %s failed", user["email"])
        raise HTTPException(502, "We couldn't send the verification email. Try again in a moment.")
    storage.execute('DELETE FROM verification_codes WHERE "id" = ?', (user["id"],))
    storage.insert("verification_codes", {
        "id": user["id"], "codeHash": _code_hash(user["id"], code), "attempts": 0, "sentAt": storage.now(),
        "expiresAt": (datetime.now(timezone.utc) + timedelta(minutes=CODE_MINUTES)).isoformat(),
    })


def _pending(user: dict) -> dict:
    """Sign-up / sign-in answer for an account that still needs its email code: no session yet."""
    return {"verificationRequired": True, "email": user["email"], "codeMinutes": CODE_MINUTES,
            "resendSeconds": RESEND_SECONDS}


@router.post("/auth/register")
def register(body: Register):
    """Passenger self sign-up. Emails a 6-digit code; the account works once /auth/verify accepts it.
    Staff and administrator accounts are created by an administrator (already verified)."""
    email = _normalize_email(body.email)
    _check_password_rules(body.password)
    if not body.name.strip():
        raise HTTPException(400, "Enter your name")
    existing = _user_by_email(email)
    if existing and is_verified(existing):
        raise HTTPException(409, "An account with this email already exists. Sign in instead.")
    if existing:
        # Never verified (code lost, typo in the name...): start the sign-up over.
        storage.update("users", existing["id"], name=body.name.strip(), passwordHash=hash_password(body.password))
        user = storage.get("users", existing["id"])
    else:
        user = storage.insert("users", {
            "id": storage.new_id(), "email": email, "name": body.name.strip(), "role": "passenger",
            "airport": None, "passwordHash": hash_password(body.password), "disabled": 0, "verified": 0,
            "timestamp": storage.now(),
        })
    _send_code(user, force=True)
    return _pending(user)


class Verify(BaseModel):
    email: str
    code: str


@router.post("/auth/verify")
def verify_email(body: Verify):
    """Checks the emailed code; on success the account is active and signed in."""
    user = _user_by_email(body.email.strip().lower())
    entry = storage.get("verification_codes", user["id"]) if user else None
    if not user or is_verified(user) or not entry:
        raise HTTPException(400, "No code is waiting for this email. Ask for a new one.")
    if entry["expiresAt"] < storage.now():
        raise HTTPException(400, "This code has expired. Ask for a new one.")
    if int(entry["attempts"] or 0) >= CODE_ATTEMPTS:
        raise HTTPException(429, "Too many wrong codes. Ask for a new one.")
    code = re.sub(r"\D", "", body.code)
    if not hmac.compare_digest(_code_hash(user["id"], code), entry["codeHash"]):
        attempts = int(entry["attempts"] or 0) + 1
        storage.update("verification_codes", user["id"], attempts=attempts)
        left = CODE_ATTEMPTS - attempts
        raise HTTPException(400, f"That code isn't right. {left} attempt(s) left." if left else
                            "Too many wrong codes. Ask for a new one.")
    storage.update("users", user["id"], verified=1)
    storage.execute('DELETE FROM verification_codes WHERE "id" = ?', (user["id"],))
    user = storage.get("users", user["id"])
    return {"token": _new_session(user), "user": public_user(user)}


class Resend(BaseModel):
    email: str


@router.post("/auth/resend")
def resend_code(body: Resend):
    user = _user_by_email(body.email.strip().lower())
    # Same answer for unknown / already verified emails: don't reveal which addresses have accounts.
    if user and not is_verified(user) and not user.get("disabled"):
        _send_code(user)
    return {"ok": True, "resendSeconds": RESEND_SECONDS}


@router.post("/auth/login")
def login(body: Login):
    user = _user_by_email(body.email.strip().lower())
    if not user or not check_password(body.password, user.get("passwordHash")):
        raise HTTPException(401, "Wrong email or password")
    if user.get("disabled"):
        raise HTTPException(403, "This account is disabled. Contact the administrator.")
    if not is_verified(user):
        try:
            _send_code(user)  # a fresh code, unless one was sent less than a minute ago
        except HTTPException as e:
            if e.status_code != 429:
                raise
        return _pending(user)
    # Staff portals need a staff account; an administrator may use any portal.
    if body.role == "staff" and not is_staff(user):
        raise HTTPException(403, "This is a passenger account. Use the Passenger sign-in.")
    if body.role == "admin" and user["role"] != "admin":
        raise HTTPException(403, "This account is not an administrator.")
    return {"token": _new_session(user), "user": public_user(user)}


@router.get("/auth/me")
def me(user: dict = Depends(current_user)):
    return public_user(user)


@router.post("/auth/logout")
def logout(authorization: str | None = Header(None)):
    if authorization:
        storage.execute('DELETE FROM sessions WHERE "id" = ?', (_token_hash(authorization.removeprefix("Bearer ").strip()),))
    return {"ok": True}


class PasswordChange(BaseModel):
    currentPassword: str
    newPassword: str


@router.post("/auth/password")
def change_password(body: PasswordChange, user: dict = Depends(current_user)):
    if not check_password(body.currentPassword, user.get("passwordHash")):
        raise HTTPException(400, "Current password is wrong")
    _check_password_rules(body.newPassword)
    storage.update("users", user["id"], passwordHash=hash_password(body.newPassword))
    return {"ok": True}


# ---------------------------------------------------------------- administrator

class NewUser(BaseModel):
    email: str
    password: str
    name: str
    role: str = "staff"
    airport: str | None = None


class UserChange(BaseModel):
    name: str | None = None
    role: str | None = None
    airport: str | None = None
    disabled: bool | None = None
    password: str | None = None


@router.get("/admin/users")
def list_users(role: str | None = None, _: dict = Depends(require_admin)):
    return [public_user(u) for u in storage.find("users", role=role)]


@router.post("/admin/users")
def create_user(body: NewUser, _: dict = Depends(require_admin)):
    email = _normalize_email(body.email)
    _check_password_rules(body.password)
    if body.role not in ROLES:
        raise HTTPException(400, f"Role must be one of {', '.join(ROLES)}")
    if _user_by_email(email):
        raise HTTPException(409, "An account with this email already exists")
    user = storage.insert("users", {
        "id": storage.new_id(), "email": email, "name": body.name.strip() or email, "role": body.role,
        "airport": body.airport, "passwordHash": hash_password(body.password), "disabled": 0, "verified": 1,
        "timestamp": storage.now(),
    })
    return public_user(user)


@router.patch("/admin/users/{user_id}")
def change_user(user_id: str, body: UserChange, admin: dict = Depends(require_admin)):
    user = storage.get("users", user_id)
    if not user:
        raise HTTPException(404, "User not found")
    if user_id == admin["id"] and (body.disabled or (body.role and body.role != "admin")):
        raise HTTPException(400, "You can't disable or demote your own account")
    fields: dict = {}
    if body.name is not None:
        fields["name"] = body.name.strip()
    if body.role is not None:
        if body.role not in ROLES:
            raise HTTPException(400, f"Role must be one of {', '.join(ROLES)}")
        fields["role"] = body.role
    if body.airport is not None:
        fields["airport"] = body.airport or None
    if body.disabled is not None:
        fields["disabled"] = int(body.disabled)
    if body.password:
        _check_password_rules(body.password)
        fields["passwordHash"] = hash_password(body.password)
    if fields:
        storage.update("users", user_id, **fields)
    if body.disabled or body.password or body.role:
        # Sign the user out everywhere so the change takes effect immediately.
        storage.execute('DELETE FROM sessions WHERE "userId" = ?', (user_id,))
    return public_user(storage.get("users", user_id))


@router.delete("/admin/users/{user_id}")
def delete_user(user_id: str, admin: dict = Depends(require_admin)):
    if user_id == admin["id"]:
        raise HTTPException(400, "You can't delete your own account")
    if not storage.get("users", user_id):
        raise HTTPException(404, "User not found")
    storage.execute('DELETE FROM sessions WHERE "userId" = ?', (user_id,))
    storage.execute('DELETE FROM users WHERE "id" = ?', (user_id,))
    return {"ok": True}


# ---------------------------------------------------------------- first administrator

def ensure_admin() -> None:
    """Creates the first administrator if there is none: LF_ADMIN_EMAIL / LF_ADMIN_PASSWORD,
    else admin@skyfindr.app with a random password saved to data/admin_password.txt."""
    if storage.find("users", role="admin"):
        return
    email = config.ADMIN_EMAIL.lower()
    password = config.ADMIN_PASSWORD
    if not password:
        path = config.DATA_DIR / "admin_password.txt"
        if not path.exists():
            path.write_text(secrets.token_urlsafe(9))
        password = path.read_text().strip()
    existing = _user_by_email(email)
    if existing:
        storage.update("users", existing["id"], role="admin", disabled=0)
        log.warning("Administrator account: %s (existing account promoted)", email)
        return
    else:
        storage.insert("users", {
            "id": storage.new_id(), "email": email, "name": "Administrator", "role": "admin", "airport": None,
            "passwordHash": hash_password(password), "disabled": 0, "verified": 1, "timestamp": storage.now(),
        })
    log.warning("Administrator account: %s / %s (change it after signing in)", email, password)
