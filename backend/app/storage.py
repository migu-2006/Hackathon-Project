"""Persistence: Postgres (Supabase) when DATABASE_URL is set, otherwise a local SQLite file.
Both use the same tables (supabase/schema.sql is the Postgres copy of SCHEMA below) and
the same small API: insert / update / get / find / execute, documents as dicts."""
from __future__ import annotations

import json
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from . import config

POSTGRES = bool(config.DATABASE_URL)

_lock = threading.Lock()

SCHEMA = """
CREATE TABLE IF NOT EXISTS found_items (
    id TEXT PRIMARY KEY,
    imageUrl TEXT,
    previewUrl TEXT,      -- blurred copy shown publicly; the real photo only via reverse image search
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
    status TEXT,
    pickupCode TEXT
);
CREATE TABLE IF NOT EXISTS claim_attempts (
    id TEXT PRIMARY KEY,
    claimId TEXT,
    itemId TEXT,
    userId TEXT,
    airport TEXT,
    answer TEXT,
    result TEXT,          -- correct | wrong | unchecked (no hidden detail to compare: staff decides)
    cleared INTEGER DEFAULT 0,  -- 1 once staff unlocked the passenger (kept for the audit log)
    timestamp TEXT
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
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    email TEXT UNIQUE,
    name TEXT,
    role TEXT,            -- passenger | staff | admin
    airport TEXT,         -- staff: home airport (optional)
    passwordHash TEXT,    -- scrypt$salt$hash
    disabled INTEGER DEFAULT 0,
    verified INTEGER,     -- 0 until the emailed code is entered (NULL: older accounts, verified)
    timestamp TEXT
);
CREATE TABLE IF NOT EXISTS verification_codes (
    id TEXT PRIMARY KEY,  -- user id (one live code per account)
    codeHash TEXT,
    expiresAt TEXT,
    attempts INTEGER DEFAULT 0,
    sentAt TEXT
);
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,  -- SHA-256 of the bearer token (the token itself is never stored)
    userId TEXT,
    timestamp TEXT,
    expiresAt TEXT
);
"""

JSON_FIELDS = {"embedding", "data", "route"}


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_id() -> str:
    return uuid.uuid4().hex[:12]


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(config.DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


def _q(name: str) -> str:
    """Quoted column name: Postgres would otherwise lowercase camelCase (imageUrl -> imageurl)."""
    return f'"{name}"'


def _sql(sql: str) -> str:
    return sql.replace("?", "%s") if POSTGRES else sql


def _migrate_postgres(conn) -> None:
    conn.execute((Path(__file__).resolve().parents[1] / "supabase" / "schema.sql").read_text(encoding="utf-8"))
    conn.execute('ALTER TABLE claims ADD COLUMN IF NOT EXISTS "pickupCode" TEXT')
    conn.execute('ALTER TABLE users ADD COLUMN IF NOT EXISTS "verified" INTEGER')
    conn.execute('ALTER TABLE lost_reports ADD COLUMN IF NOT EXISTS "route" TEXT')
    for table in ("found_items", "lost_reports"):
        conn.execute(f'UPDATE {table} SET "airport" = %s WHERE "airport" IS NULL', (config.DEFAULT_AIRPORT,))


def _migrate(conn: sqlite3.Connection) -> None:
    """Add columns introduced after a database was created (CREATE IF NOT EXISTS won't)."""
    for table, column in [("lost_reports", "travelDate"), ("claims", "reviewedAt"),
                          ("found_items", "airport"), ("found_items", "zoneId"), ("lost_reports", "airport"),
                          ("found_items", "previewUrl"), ("claims", "pickupCode"), ("lost_reports", "route")]:
        existing = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
        if column not in existing:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} TEXT")
    if "verified" not in {r[1] for r in conn.execute("PRAGMA table_info(users)")}:
        conn.execute("ALTER TABLE users ADD COLUMN verified INTEGER")
    # Rows from before multi-airport support belong to the default airport.
    for table in ("found_items", "lost_reports"):
        conn.execute(f"UPDATE {table} SET airport = ? WHERE airport IS NULL", (config.DEFAULT_AIRPORT,))
    conn.commit()


if POSTGRES:
    import psycopg
    from psycopg.rows import dict_row
    from psycopg_pool import ConnectionPool

    # Every call is one statement, so autocommit saves the COMMIT round trip (~100+ ms to Supabase).
    # prepare_threshold=None: no server-side prepared statements (fine behind any pooler mode).
    _pool = ConnectionPool(config.DATABASE_URL, min_size=2, max_size=8, open=True, max_idle=300,
                           kwargs={"row_factory": dict_row, "prepare_threshold": None, "autocommit": True})
    with _pool.connection() as _c:
        _migrate_postgres(_c)

    # A connection the server dropped while idle fails once; the pool then discards it.
    _RETRY: tuple = (psycopg.OperationalError,)

    @contextmanager
    def tx():
        with _pool.connection() as conn:
            yield conn
else:
    _RETRY = ()

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


def _row(row) -> dict | None:
    if row is None:
        return None
    out = dict(row)
    for key in JSON_FIELDS & out.keys():
        out[key] = json.loads(out[key]) if out[key] else None
    return out


def _run(sql: str, params: tuple = (), fetch: str | None = None):
    """One statement: fetch "one" / "all" rows, or return the affected row count."""
    for attempt in (1, 2):
        try:
            with tx() as c:
                cur = c.execute(_sql(sql), params)
                if fetch == "one":
                    return cur.fetchone()
                return cur.fetchall() if fetch == "all" else cur.rowcount
        except _RETRY:
            if attempt == 2:
                raise


def insert(table: str, doc: dict) -> dict:
    values = {k: json.dumps(v) if k in JSON_FIELDS and v is not None else v for k, v in doc.items()}
    cols = ", ".join(_q(k) for k in values)
    marks = ", ".join("?" for _ in values)
    _run(f"INSERT INTO {table} ({cols}) VALUES ({marks})", tuple(values.values()))
    return doc


def update(table: str, id_: str, **fields) -> None:
    sets = ", ".join(f"{_q(k)} = ?" for k in fields)
    _run(f'UPDATE {table} SET {sets} WHERE "id" = ?', (*fields.values(), id_))


def get(table: str, id_: str) -> dict | None:
    return _row(_run(f'SELECT * FROM {table} WHERE "id" = ?', (id_,), fetch="one"))


def find(table: str, order: str = "timestamp DESC", **filters) -> list[dict]:
    filters = {k: v for k, v in filters.items() if v is not None}
    where = " AND ".join(f"{_q(k)} = ?" for k in filters)
    column, *direction = order.split()
    sql = f"SELECT * FROM {table}" + (f" WHERE {where}" if where else "") + f" ORDER BY {_q(column)} {' '.join(direction)}"
    return [_row(r) for r in _run(sql, tuple(filters.values()), fetch="all")]


def execute(sql: str, params: tuple = ()) -> int:
    """Raw write (bulk updates / deletes) with ? placeholders and "quoted" camelCase columns;
    returns the number of rows affected."""
    return _run(sql, params)
