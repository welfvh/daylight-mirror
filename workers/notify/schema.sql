CREATE TABLE IF NOT EXISTS subscribers (
  email TEXT PRIMARY KEY,
  version TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'unknown',
  created_at TEXT NOT NULL,
  updated_at TEXT
);
