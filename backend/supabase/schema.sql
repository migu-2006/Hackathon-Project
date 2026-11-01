-- SkyFindr schema for Supabase (Postgres). Paste into Supabase > SQL Editor > Run.
-- Same tables and columns as backend/app/storage.py (SQLite).
-- Column names are "quoted" so Postgres keeps the camelCase the API returns (imageUrl, not imageurl).

CREATE TABLE IF NOT EXISTS found_items (
    "id" TEXT PRIMARY KEY,
    "imageUrl" TEXT,
    "previewUrl" TEXT,      -- blurred copy shown publicly
    "category" TEXT,
    "label" TEXT,
    "color" TEXT,
    "colorHex" TEXT,
    "text" TEXT,
    "airport" TEXT,
    "zoneId" TEXT,
    "location" TEXT,
    "notes" TEXT,
    "secretDetail" TEXT,    -- staff only
    "embedding" TEXT,       -- JSON list of floats
    "timestamp" TEXT,
    "status" TEXT
);

CREATE TABLE IF NOT EXISTS lost_reports (
    "id" TEXT PRIMARY KEY,
    "userId" TEXT,
    "airport" TEXT,
    "description" TEXT,
    "category" TEXT,
    "color" TEXT,
    "lastSeenLocation" TEXT,
    "route" TEXT,
    "travelDate" TEXT,
    "imageUrl" TEXT,
    "embedding" TEXT,
    "timestamp" TEXT,
    "status" TEXT,
    "matchedItemId" TEXT
);

CREATE TABLE IF NOT EXISTS claims (
    "id" TEXT PRIMARY KEY,
    "token" TEXT UNIQUE,
    "reportId" TEXT,
    "itemId" TEXT,
    "userId" TEXT,
    "question" TEXT,
    "answer" TEXT,
    "timestamp" TEXT,
    "reviewedAt" TEXT,
    "status" TEXT,
    "pickupCode" TEXT
);

CREATE TABLE IF NOT EXISTS claim_attempts (
    "id" TEXT PRIMARY KEY,
    "claimId" TEXT,
    "itemId" TEXT,
    "userId" TEXT,
    "airport" TEXT,
    "answer" TEXT,
    "result" TEXT,          -- correct | wrong | unchecked
    "cleared" INTEGER DEFAULT 0,
    "timestamp" TEXT
);

CREATE TABLE IF NOT EXISTS notifications (
    "id" TEXT PRIMARY KEY,
    "userId" TEXT,
    "title" TEXT,
    "body" TEXT,
    "data" TEXT,            -- JSON object
    "timestamp" TEXT,
    "read" INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS users (
    "id" TEXT PRIMARY KEY,
    "email" TEXT UNIQUE,
    "name" TEXT,
    "role" TEXT,            -- passenger | staff | admin
    "airport" TEXT,         -- staff: home airport (optional)
    "passwordHash" TEXT,    -- scrypt$salt$hash
    "disabled" INTEGER DEFAULT 0,
    "verified" INTEGER,     -- 0 until the emailed code is entered (NULL: older accounts, verified)
    "timestamp" TEXT
);

CREATE TABLE IF NOT EXISTS verification_codes (
    "id" TEXT PRIMARY KEY,  -- user id (one live code per account)
    "codeHash" TEXT,
    "expiresAt" TEXT,
    "attempts" INTEGER DEFAULT 0,
    "sentAt" TEXT
);

CREATE TABLE IF NOT EXISTS sessions (
    "id" TEXT PRIMARY KEY,  -- SHA-256 of the bearer token (the token itself is never stored)
    "userId" TEXT,
    "timestamp" TEXT,
    "expiresAt" TEXT
);

-- Supabase also publishes every table through its public REST API (anon key).
-- Row Level Security with no policies closes that door: only our backend
-- (connecting as the postgres user) can read secretDetail, answers and tokens.
ALTER TABLE found_items    ENABLE ROW LEVEL SECURITY;
ALTER TABLE lost_reports   ENABLE ROW LEVEL SECURITY;
ALTER TABLE claims         ENABLE ROW LEVEL SECURITY;
ALTER TABLE claim_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications  ENABLE ROW LEVEL SECURITY;
ALTER TABLE users          ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions       ENABLE ROW LEVEL SECURITY;
ALTER TABLE verification_codes ENABLE ROW LEVEL SECURITY;
