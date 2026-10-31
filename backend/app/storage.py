"""SQLite persistence. Mirrors the FoundItems / LostReports entities from the spec so the
same documents can later be pushed to Firestore / Supabase without changing the API."""
from __future__ import annotations

import json
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone

from . import config

_lock = threading.Lock()

SCHEMA = """
CREATE TABLE IF NOT EXISTS found_items (
    id TEXT PRIMARY KEY,
    imageUrl TEXT,
    category TEXT,
    label TEXT,
    color TEXT,
    colorHex TEXT,
    text TEXT,
    airport TEXT,
    zoneId TEXT,
    location TEXT,
    notes TEXT,
    secretDetail TEXT,
    embedding TEXT,
    timestamp TEXT,
    status TEXT
);
CREATE TABLE IF NOT EXISTS lost_reports (
    id TEXT PRIMARY KEY,
    userId TEXT,
    airport TEXT,
    description TEXT,
    category TEXT,
    color TEXT,
    lastSeenLocation TEXT,
    travelDate TEXT,
    imageUrl TEXT,
    embedding TEXT,
    timestamp TEXT,
    status TEXT,
    matchedItemId TEXT
);
CREATE TABLE IF NOT EXISTS claims (
    id TEXT PRIMARY KEY,
    token TEXT UNIQUE,
    reportId TEXT,
    itemId TEXT,
    userId TEXT,
    question TEXT,
    answer TEXT,
    timestamp TEXT,
    reviewedAt TEXT,
    status TEXT
);
CREATE TABLE IF NOT EXISTS notifications (
    id TEXT PRIMARY KEY,
    userId TEXT,
    title TEXT,
    body TEXT,
    data TEXT,
    timestamp TEXT,
    read INTEGER DEFAULT 0
);
"""

JSON_FIELDS = {"embedding", "data"}


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_id() -> str:
    return uuid.uuid4().hex[:12]


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(config.DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


def _migrate(conn: sqlite3.Connection) -> None:
    """Add columns introduced after a database was created (CREATE IF NOT EXISTS won't)."""
    for table, column in [("lost_reports", "travelDate"), ("claims", "reviewedAt"),
                          ("found_items", "airport"), ("found_items", "zoneId"), ("lost_reports", "airport")]:
        existing = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
        if column not in existing:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} TEXT")
    # Rows from before multi-airport support belong to the default airport.
    for table in ("found_items", "lost_reports"):
        conn.execute(f"UPDATE {table} SET airport = ? WHERE airport IS NULL", (config.DEFAULT_AIRPORT,))
    conn.commit()


_conn = _connect()
_conn.executescript(SCHEMA)
_migrate(_conn)


@contextmanager
def tx():
    with _lock:
        try:
            yield _conn
            _conn.commit()
        except Exception:
            _conn.rollback()
            raise


def _row(row: sqlite3.Row | None) -> dict | None:
    if row is None:
        return None
    out = dict(row)
    for key in JSON_FIELDS & out.keys():
        out[key] = json.loads(out[key]) if out[key] else None
    return out


def insert(table: str, doc: dict) -> dict:
    values = {k: json.dumps(v) if k in JSON_FIELDS and v is not None else v for k, v in doc.items()}
    cols = ", ".join(values)
    marks = ", ".join("?" for _ in values)
    with tx() as c:
        c.execute(f"INSERT INTO {table} ({cols}) VALUES ({marks})", tuple(values.values()))
    return doc


def update(table: str, id_: str, **fields) -> None:
    sets = ", ".join(f"{k} = ?" for k in fields)
    with tx() as c:
        c.execute(f"UPDATE {table} SET {sets} WHERE id = ?", (*fields.values(), id_))


def get(table: str, id_: str) -> dict | None:
    with tx() as c:
        return _row(c.execute(f"SELECT * FROM {table} WHERE id = ?", (id_,)).fetchone())


def find(table: str, order: str = "timestamp DESC", **filters) -> list[dict]:
    filters = {k: v for k, v in filters.items() if v is not None}
    where = " AND ".join(f"{k} = ?" for k in filters)
    sql = f"SELECT * FROM {table}" + (f" WHERE {where}" if where else "") + f" ORDER BY {order}"
    with tx() as c:
        return [_row(r) for r in c.execute(sql, tuple(filters.values())).fetchall()]
