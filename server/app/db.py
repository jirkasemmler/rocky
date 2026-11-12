"""SQLite storage (WAL, stdlib sqlite3). One connection per process guarded by a lock: the
server is single-user and writes are tiny, so serialising them is simpler than pooling."""

from __future__ import annotations

import sqlite3
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

SCHEMA = """
CREATE TABLE IF NOT EXISTS catalog_revisions (
    revision   INTEGER PRIMARY KEY,
    snapshot   TEXT    NOT NULL,          -- catalog JSON without "revision"
    author     TEXT    NOT NULL,          -- admin | agent:<token name> | seed
    message    TEXT    NOT NULL,
    created_at TEXT    NOT NULL
);
-- every exercise id ever used: ids are immutable and never reused (SERVER-SPEC §3)
CREATE TABLE IF NOT EXISTS exercise_ids (
    id TEXT PRIMARY KEY
);
CREATE TABLE IF NOT EXISTS records (
    kind         TEXT    NOT NULL,
    key          TEXT    NOT NULL,
    payload      BLOB,                    -- exact bytes received; NULL for tombstones
    deleted      INTEGER NOT NULL DEFAULT 0,
    version      INTEGER NOT NULL,
    change_seq   INTEGER NOT NULL UNIQUE,
    updated_at   TEXT    NOT NULL,
    s_date       REAL,                    -- indexed copies for sessions
    s_workout_id TEXT,
    s_kind       TEXT,
    s_completed  INTEGER,
    PRIMARY KEY (kind, key)
);
CREATE INDEX IF NOT EXISTS records_session_date ON records (kind, s_date);
CREATE TABLE IF NOT EXISTS tokens (
    id           INTEGER PRIMARY KEY,
    name         TEXT NOT NULL UNIQUE,
    scope        TEXT NOT NULL CHECK (scope IN ('device', 'agent', 'admin')),
    hash         TEXT NOT NULL UNIQUE,    -- sha256 hex of the secret
    created_at   TEXT NOT NULL,
    last_used_at TEXT,
    revoked_at   TEXT
);
CREATE TABLE IF NOT EXISTS audit (
    id       INTEGER PRIMARY KEY,
    at       TEXT NOT NULL,
    at_epoch REAL NOT NULL,
    token    TEXT NOT NULL,
    action   TEXT NOT NULL,
    target   TEXT,
    ref      TEXT                          -- catalog revision or record version
);
CREATE INDEX IF NOT EXISTS audit_token_time ON audit (token, at_epoch);
CREATE TABLE IF NOT EXISTS admin_sessions (
    id_hash    TEXT PRIMARY KEY,           -- sha256 of the cookie value
    token_id   INTEGER NOT NULL REFERENCES tokens (id),
    csrf       TEXT NOT NULL,
    created_at TEXT NOT NULL,
    expires_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS assets (
    sha256     TEXT PRIMARY KEY,
    mime       TEXT NOT NULL,
    size       INTEGER NOT NULL,
    width      INTEGER NOT NULL,
    height     INTEGER NOT NULL,
    frames     INTEGER NOT NULL,
    created_at TEXT NOT NULL
);
"""


class Database:
    def __init__(self, path: Path):
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None, timeout=10)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA foreign_keys=ON")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.lock = threading.RLock()
        with self.lock:
            self.conn.executescript(SCHEMA)

    @contextmanager
    def tx(self) -> Iterator[sqlite3.Connection]:
        """Write transaction (BEGIN IMMEDIATE), serialised in-process by the lock."""
        with self.lock:
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                yield self.conn
            except BaseException:
                self.conn.execute("ROLLBACK")
                raise
            else:
                self.conn.execute("COMMIT")

    @contextmanager
    def read(self) -> Iterator[sqlite3.Connection]:
        with self.lock:
            yield self.conn

    def close(self) -> None:
        with self.lock:
            self.conn.close()


def audit(conn: sqlite3.Connection, at: str, at_epoch: float, token: str, action: str, target: str | None,
          ref: str | int | None) -> None:
    conn.execute(
        "INSERT INTO audit (at, at_epoch, token, action, target, ref) VALUES (?, ?, ?, ?, ?, ?)",
        (at, at_epoch, token, action, target, None if ref is None else str(ref)),
    )
