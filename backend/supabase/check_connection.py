"""Checks that the backend can reach your Supabase project.

    cd backend
    .venv\\Scripts\\pip install "psycopg[binary]" httpx python-dotenv
    .venv\\Scripts\\python supabase\\check_connection.py

Reads DATABASE_URL, SUPABASE_URL and SUPABASE_SERVICE_KEY from backend/.env.
"""
import os
import sys
from pathlib import Path

import httpx
import psycopg
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[1] / ".env")
missing = [k for k in ("DATABASE_URL", "SUPABASE_URL", "SUPABASE_SERVICE_KEY") if not os.getenv(k)]
if missing:
    sys.exit(f"Missing in backend/.env: {', '.join(missing)}")

# 1. Database: list our tables and count their rows.
with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
    print("Database OK:", conn.execute("SELECT version()").fetchone()[0].split(",")[0])
    for table in ("found_items", "lost_reports", "claims", "claim_attempts", "notifications"):
        try:
            n = conn.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
            print(f"  {table}: {n} rows")
        except psycopg.errors.UndefinedTable:
            print(f"  {table}: MISSING - run supabase/schema.sql in the SQL Editor")
            conn.rollback()

# 2. Storage: upload, read back publicly, delete a tiny test file in the "images" bucket.
url, key = os.environ["SUPABASE_URL"].rstrip("/"), os.environ["SUPABASE_SERVICE_KEY"]
auth = {"Authorization": f"Bearer {key}", "apikey": key}
r = httpx.post(f"{url}/storage/v1/object/images/connection_test.txt", headers={**auth, "x-upsert": "true",
               "Content-Type": "text/plain"}, content=b"hello from SkyFindr")
if r.status_code >= 400:
    sys.exit(f"Storage upload failed ({r.status_code}): {r.text} - is there a public bucket named 'images'?")
public = httpx.get(f"{url}/storage/v1/object/public/images/connection_test.txt")
print("Storage OK:" if public.text == "hello from SkyFindr" else "Storage: uploaded but not public!",
      f"{url}/storage/v1/object/public/images/connection_test.txt")
httpx.request("DELETE", f"{url}/storage/v1/object/images", headers=auth, json={"prefixes": ["connection_test.txt"]})
