"""Synced records (SERVER-SPEC §4.2, §5): sessions, postponements, profile.

Versions start at 1 and grow by one per write; `changeSeq` is global and monotonic (max over all
rows + 1; rows are never removed, tombstones are kept forever). Payloads are stored as the exact
bytes received and returned as embedded JSON objects.
"""

from __future__ import annotations

import json
import re
import sqlite3
from datetime import date
from typing import Any

from pydantic import BaseModel, ValidationError

from .catalog import pydantic_errors
from .db import Database, audit
from .errors import AppError, NotFound, RecordConflict, RecordGone, ValidationFailed
from .models import (
    DAY_PATTERN,
    RECORD_KINDS,
    UUID_UPPER,
    PostponementPayload,
    ProfilePayload,
    SessionPayload,
)
from .timeutil import fmt, parse_swift_date

PROFILE_KEY = "profile"
_PAYLOAD_MODELS: dict[str, type[BaseModel]] = {
    "session": SessionPayload,
    "postponement": PostponementPayload,
    "profile": ProfilePayload,
}
_VERSION = re.compile(r'^(?:W/)?"?(\d{1,18})"?$')


class PreconditionRequired(AppError):
    status = 428
    title = "Precondition Required"


class PreconditionFailed(AppError):
    status = 412
    title = "Precondition Failed"


def record_dict(row: sqlite3.Row) -> dict[str, Any]:
    """Wire `Record`: {kind, key, version, changeSeq, deleted, updatedAt, payload|null}."""
    payload = None if row["payload"] is None else json.loads(row["payload"])
    return {
        "kind": row["kind"],
        "key": row["key"],
        "version": row["version"],
        "changeSeq": row["change_seq"],
        "deleted": bool(row["deleted"]),
        "updatedAt": row["updated_at"],
        "payload": payload,
    }


def check_key(kind: str, key: str) -> None:
    if kind not in RECORD_KINDS:
        raise NotFound(f"unknown record kind {kind!r}")
    if kind == "session" and not UUID_UPPER.match(key):
        raise AppError("session key must be an uppercase UUID")
    if kind == "postponement":
        if not DAY_PATTERN.match(key):
            raise AppError("postponement key must be a day YYYY-MM-DD")
        try:
            date.fromisoformat(key)
        except ValueError as exc:
            raise AppError("postponement key is not a valid date") from exc
    if kind == "profile" and key != PROFILE_KEY:
        raise AppError('profile key must be "profile"')


def validate_payload(kind: str, key: str, body: bytes) -> dict[str, Any]:
    """Structural check of the received bytes; returns the parsed object (for indexing only)."""
    try:
        data = json.loads(body)
    except (ValueError, UnicodeDecodeError) as exc:
        raise AppError("body is not valid JSON") from exc
    if not isinstance(data, dict):
        raise AppError("body must be a JSON object")
    try:
        _PAYLOAD_MODELS[kind].model_validate(data)
    except ValidationError as exc:
        raise ValidationFailed(pydantic_errors(exc)) from exc
    if kind == "session" and data["id"] != key:
        raise AppError("key must equal the session id")
    if kind == "postponement" and data["day"] != key:
        raise AppError("key must equal the postponement day")
    return data


def parse_version(value: str) -> int | None:
    m = _VERSION.match(value.strip())
    return int(m.group(1)) if m else None


class RecordStore:
    def __init__(self, db: Database, clock):
        self.db = db
        self.clock = clock

    def _row(self, conn: sqlite3.Connection, kind: str, key: str) -> sqlite3.Row | None:
        return conn.execute("SELECT * FROM records WHERE kind = ? AND key = ?", (kind, key)).fetchone()

    def get(self, kind: str, key: str) -> dict[str, Any] | None:
        with self.db.read() as conn:
            row = self._row(conn, kind, key)
        return None if row is None else record_dict(row)

    @staticmethod
    def _next_seq(conn: sqlite3.Connection) -> int:
        return conn.execute("SELECT COALESCE(MAX(change_seq), 0) + 1 FROM records").fetchone()[0]

    def put(self, kind: str, key: str, body: bytes, if_match: str | None, if_none_match: str | None,
            token: str) -> tuple[int, dict[str, int]]:
        """Upsert. Returns (HTTP status, {version, changeSeq})."""
        check_key(kind, key)
        data = validate_payload(kind, key, body)
        if if_match is None and if_none_match is None:
            existing = self.get(kind, key)
            if existing is not None and existing["deleted"]:
                raise RecordGone("record was deleted", current=existing)  # tombstone: 410 (SPEC §5)
            raise PreconditionRequired("If-Match: <version> or If-None-Match: * is required")
        if if_match is not None and if_none_match is not None:
            raise AppError("send either If-Match or If-None-Match, not both")
        if if_none_match is not None and if_none_match.strip() != "*":
            raise AppError("If-None-Match must be *")
        expected = None
        if if_match is not None:
            expected = parse_version(if_match)
            if expected is None:
                raise AppError("If-Match must be the record version (an integer)")

        index = self._index(kind, data)
        now = self.clock()
        with self.db.tx() as conn:
            row = self._row(conn, kind, key)
            if row is None:
                if expected is not None:
                    raise PreconditionFailed(
                        "record does not exist on the server; create it with If-None-Match: *"
                    )
                version, status = 1, 201
            elif row["deleted"]:
                # Tombstones win, except a client that has seen the tombstone revives the record
                # with If-Match: <tombstone version> (SERVER-SPEC §5; postponement re-created for
                # the same day). Same rule for every kind.
                if expected != row["version"]:
                    raise RecordGone("record was deleted", current=record_dict(row))
                version, status = row["version"] + 1, 200
            else:
                if expected is None or expected != row["version"]:
                    raise RecordConflict(record_dict(row))
                version, status = row["version"] + 1, 200
            seq = self._next_seq(conn)
            conn.execute(
                "INSERT INTO records (kind, key, payload, deleted, version, change_seq, updated_at, "
                "s_date, s_workout_id, s_kind, s_completed) VALUES (?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT (kind, key) DO UPDATE SET payload = excluded.payload, deleted = 0, "
                "version = excluded.version, change_seq = excluded.change_seq, updated_at = excluded.updated_at, "
                "s_date = excluded.s_date, s_workout_id = excluded.s_workout_id, s_kind = excluded.s_kind, "
                "s_completed = excluded.s_completed",
                (kind, key, body, version, seq, fmt(now), *index),
            )
            audit(conn, fmt(now), now.timestamp(), token, f"record.put", f"{kind}/{key}", version)
        return status, {"version": version, "changeSeq": seq}

    @staticmethod
    def _index(kind: str, data: dict[str, Any]) -> tuple[Any, Any, Any, Any]:
        if kind != "session":
            return (None, None, None, None)
        return (parse_swift_date(data["date"]).timestamp(), data["workoutID"], data["kind"], int(data["completed"]))

    def delete(self, kind: str, key: str, if_match: str | None, token: str) -> dict[str, int]:
        check_key(kind, key)
        if if_match is None:
            raise PreconditionRequired("If-Match: <version> (or * if the version is unknown) is required")
        wildcard = if_match.strip() == "*"
        expected = None if wildcard else parse_version(if_match)
        if not wildcard and expected is None:
            raise AppError("If-Match must be the record version (an integer) or *")
        now = self.clock()
        with self.db.tx() as conn:
            row = self._row(conn, kind, key)
            if row is not None and row["deleted"]:
                return {"version": row["version"], "changeSeq": row["change_seq"]}  # idempotent
            if row is not None and not wildcard and expected != row["version"]:
                raise RecordConflict(record_dict(row))
            version = 1 if row is None else row["version"] + 1
            seq = self._next_seq(conn)
            conn.execute(
                "INSERT INTO records (kind, key, payload, deleted, version, change_seq, updated_at) "
                "VALUES (?, ?, NULL, 1, ?, ?, ?) ON CONFLICT (kind, key) DO UPDATE SET payload = NULL, deleted = 1, "
                "version = excluded.version, change_seq = excluded.change_seq, updated_at = excluded.updated_at, "
                "s_date = NULL, s_workout_id = NULL, s_kind = NULL, s_completed = NULL",
                (kind, key, version, seq, fmt(now)),
            )
            audit(conn, fmt(now), now.timestamp(), token, "record.delete", f"{kind}/{key}", version)
        return {"version": version, "changeSeq": seq}

    def changes(self, since: int, limit: int) -> dict[str, Any]:
        with self.db.read() as conn:
            rows = conn.execute(
                "SELECT * FROM records WHERE change_seq > ? ORDER BY change_seq LIMIT ?", (since, limit + 1)
            ).fetchall()
        has_more = len(rows) > limit
        items = [record_dict(r) for r in rows[:limit]]
        return {"items": items, "nextSince": items[-1]["changeSeq"] if items else since, "hasMore": has_more}

    def sessions(self, start: float | None, end: float | None, limit: int) -> list[dict[str, Any]]:
        q = "SELECT payload FROM records WHERE kind = 'session' AND deleted = 0"
        args: list[Any] = []
        if start is not None:
            q += " AND s_date >= ?"
            args.append(start)
        if end is not None:
            q += " AND s_date <= ?"
            args.append(end)
        q += " ORDER BY s_date DESC LIMIT ?"
        args.append(limit)
        with self.db.read() as conn:
            rows = conn.execute(q, args).fetchall()
        return [json.loads(r["payload"]) for r in rows]
