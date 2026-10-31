# Supabase (cloud database + photo storage)

Without configuration the backend uses `data/lostfound.db` (SQLite) and `data/images`.
With a `backend/.env` it uses a Supabase project instead: Postgres for the tables and a
public Storage bucket for the photos. The API and the app don't change.

## Setup (once per project)

1. supabase.com → **New project** (free plan). Keep the database password.
2. **SQL Editor** → paste `schema.sql` → **Run**. (The backend also runs it on start.)
3. **Storage** → **New bucket** `images`, **Public** on.
4. Create `backend/.env` (gitignored, never commit it):

   ```
   DATABASE_URL=postgresql://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres
   SUPABASE_URL=https://<ref>.supabase.co
   SUPABASE_SERVICE_KEY=<service_role or sb_secret_ key>
   ```

   - `DATABASE_URL`: **Connect** button → Connection string → URI → **Session pooler**
     (the direct connection is IPv6-only on the free plan).
   - `SUPABASE_URL`: Project Settings → Data API → Project URL.
   - `SUPABASE_SERVICE_KEY`: Project Settings → API Keys → `service_role` (legacy tab) or a secret key.
     Not the anon / publishable key.
5. `pip install -r requirements.txt`, then `python supabase\check_connection.py`.
6. Optional, to bring local data along: `python supabase\migrate_sqlite.py` (safe to re-run).

Start the backend as usual; the log shows the same endpoints, now backed by Supabase.
Remove or rename `.env` to go back to SQLite.

## Notes

- Row Level Security is on with no policies: Supabase's public REST API can't read the tables,
  only the backend (database owner) can. Hidden details and pickup tokens stay private.
- Tests always use a temporary SQLite database, even when `.env` exists.
- Free projects pause after about a week without activity: open the dashboard and restore before a demo.
- Every query is a network round trip (~100–200 ms to the project's region), so pick the region
  closest to where the backend runs.
