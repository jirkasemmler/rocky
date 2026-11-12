"""Access tokens (SERVER-SPEC §4.3): exclusive scopes, only SHA-256 hashes stored."""

from __future__ import annotations

import base64
import hashlib
import re
import secrets
import sqlite3
from dataclasses import dataclass

from .db import Database, audit
from .errors import AppError
from .timeutil import fmt

SCOPES = ("device", "agent", "admin")
NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,39}$")


@dataclass(frozen=True)
class Token:
    id: int
    name: str
    scope: str


def hash_secret(secret: str) -> str:
    return hashlib.sha256(secret.encode()).hexdigest()


def new_secret() -> str:
    return base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()


class TokenStore:
    def __init__(self, db: Database, clock):
        self.db = db
        self.clock = clock

    def create(self, name: str, scope: str, actor: str = "cli") -> str:
        """Create a token and return its secret (shown once)."""
        name = name.strip()
        if scope not in SCOPES:
            raise AppError(f"scope must be one of {', '.join(SCOPES)}")
        if not NAME_PATTERN.match(name):
            raise AppError("name: 1–40 characters, letters, digits, space, . _ -")
        secret = new_secret()
        now = self.clock()
        try:
            with self.db.tx() as conn:
                conn.execute(
                    "INSERT INTO tokens (name, scope, hash, created_at) VALUES (?, ?, ?, ?)",
                    (name, scope, hash_secret(secret), fmt(now)),
                )
                audit(conn, fmt(now), now.timestamp(), actor, "token.create", name, scope)
        except sqlite3.IntegrityError as exc:
            raise AppError(f"a token named {name!r} already exists", status=409, title="Conflict") from exc
        return secret

    def verify(self, secret: str) -> Token | None:
        """Active token for the secret, or None. Updates lastUsedAt."""
        if not secret:
            return None
        h = hash_secret(secret)
        with self.db.read() as conn:
            row = conn.execute(
                "SELECT id, name, scope FROM tokens WHERE hash = ? AND revoked_at IS NULL", (h,)
            ).fetchone()
        if row is None:
            return None
        with self.db.tx() as conn:
            conn.execute("UPDATE tokens SET last_used_at = ? WHERE id = ?", (fmt(self.clock()), row["id"]))
        return Token(row["id"], row["name"], row["scope"])

    def get(self, token_id: int) -> Token | None:
        with self.db.read() as conn:
            row = conn.execute(
                "SELECT id, name, scope FROM tokens WHERE id = ? AND revoked_at IS NULL", (token_id,)
            ).fetchone()
        return None if row is None else Token(row["id"], row["name"], row["scope"])

    def list(self) -> list[dict]:
        with self.db.read() as conn:
            rows = conn.execute(
                "SELECT id, name, scope, created_at, last_used_at, revoked_at FROM tokens ORDER BY id"
            ).fetchall()
        return [dict(r) for r in rows]

    def revoke(self, name_or_id: str | int, actor: str = "cli") -> bool:
        now = self.clock()
        with self.db.tx() as conn:
            if isinstance(name_or_id, int):
                row = conn.execute("SELECT id, name FROM tokens WHERE id = ?", (name_or_id,)).fetchone()
            else:
                row = conn.execute("SELECT id, name FROM tokens WHERE name = ?", (name_or_id,)).fetchone()
            if row is None:
                return False
            conn.execute(
                "UPDATE tokens SET revoked_at = COALESCE(revoked_at, ?) WHERE id = ?", (fmt(now), row["id"])
            )
            # Revocation ends admin web sessions immediately (SERVER-SPEC §9).
            conn.execute("DELETE FROM admin_sessions WHERE token_id = ?", (row["id"],))
            audit(conn, fmt(now), now.timestamp(), actor, "token.revoke", row["name"], None)
        return True
