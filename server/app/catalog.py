"""Versioned exercise catalog (SERVER-SPEC §4.1): every change is a new revision holding a full
snapshot; every write carries `baseRevision`; rollback (admin only) = new revision with an old
snapshot."""

from __future__ import annotations

import copy
import json
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from pydantic import ValidationError

from .db import Database, audit
from .errors import AppError, NotFound, RevisionConflict, ValidationFailed
from .models import EXERCISE_ID_PATTERN, CatalogBody, Exercise, validate_catalog
from .timeutil import fmt

OPTIONAL_EXERCISE_FIELDS = ("instructions", "imageAssetID")


@dataclass(frozen=True)
class Actor:
    """Who writes: `author` goes into the revision, `token` into the audit log."""

    author: str  # admin | agent:<name> | seed
    token: str


def pydantic_errors(exc: ValidationError) -> list[str]:
    out = []
    for err in exc.errors():
        loc = ".".join(str(p) for p in err["loc"])
        out.append(f"{loc}: {err['msg']}" if loc else err["msg"])
    return out


def parse_catalog(data: dict[str, Any]) -> CatalogBody:
    try:
        return CatalogBody.model_validate(data)
    except ValidationError as exc:
        raise ValidationFailed(pydantic_errors(exc)) from exc


def merge_patch(target: Any, patch: Any) -> Any:
    """RFC 7396 JSON merge patch."""
    if not isinstance(patch, dict):
        return copy.deepcopy(patch)
    result = copy.deepcopy(target) if isinstance(target, dict) else {}
    for key, value in patch.items():
        if value is None:
            result.pop(key, None)
        else:
            result[key] = merge_patch(result.get(key), value)
    return result


class CatalogStore:
    def __init__(self, db: Database, clock, asset_exists: Callable[[str], bool]):
        self.db = db
        self.clock = clock
        self.asset_exists = asset_exists

    # ------------------------------------------------------------ reads

    def current(self) -> tuple[int, CatalogBody]:
        with self.db.read() as conn:
            return self._current(conn)

    def _current(self, conn: sqlite3.Connection) -> tuple[int, CatalogBody]:
        row = conn.execute(
            "SELECT revision, snapshot FROM catalog_revisions ORDER BY revision DESC LIMIT 1"
        ).fetchone()
        if row is None:
            raise NotFound("catalog has not been seeded")
        return row["revision"], CatalogBody.model_validate_json(row["snapshot"])

    def current_wire(self) -> dict[str, Any]:
        rev, body = self.current()
        return body.wire(rev)

    def revision_wire(self, revision: int) -> dict[str, Any]:
        with self.db.read() as conn:
            row = conn.execute("SELECT snapshot FROM catalog_revisions WHERE revision = ?", (revision,)).fetchone()
        if row is None:
            raise NotFound(f"revision {revision} does not exist")
        return CatalogBody.model_validate_json(row["snapshot"]).wire(revision)

    def revisions(self, limit: int = 20) -> list[dict[str, Any]]:
        limit = max(1, min(limit, 500))
        with self.db.read() as conn:
            rows = conn.execute(
                "SELECT revision, author, message, created_at FROM catalog_revisions ORDER BY revision DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [
            {"revision": r["revision"], "author": r["author"], "message": r["message"], "createdAt": r["created_at"]}
            for r in rows
        ]

    # ------------------------------------------------------------ seed

    def seed_if_empty(self, seed_path: Path) -> bool:
        with self.db.read() as conn:
            if conn.execute("SELECT 1 FROM catalog_revisions LIMIT 1").fetchone():
                return False
        data = json.loads(seed_path.read_bytes())
        body = parse_catalog(data)
        errors = validate_catalog(body)
        if errors:
            raise ValidationFailed(errors)
        now = self.clock()
        with self.db.tx() as conn:
            if conn.execute("SELECT 1 FROM catalog_revisions LIMIT 1").fetchone():
                return False
            self._insert(conn, 1, body, "seed", "Výchozí katalog (seed)", now)
            audit(conn, fmt(now), now.timestamp(), "seed", "catalog.seed", None, 1)
        return True

    def _insert(self, conn: sqlite3.Connection, revision: int, body: CatalogBody, author: str, message: str,
                now) -> None:
        conn.execute(
            "INSERT INTO catalog_revisions (revision, snapshot, author, message, created_at) VALUES (?, ?, ?, ?, ?)",
            (revision, json.dumps(body.snapshot(), ensure_ascii=False, separators=(",", ":")), author, message,
             fmt(now)),
        )
        conn.executemany("INSERT OR IGNORE INTO exercise_ids (id) VALUES (?)", [(e.id,) for e in body.exercises])

    # ------------------------------------------------------------ writes

    def check_base(self, base_revision: int) -> int:
        rev, _ = self.current()
        if base_revision != rev:
            raise RevisionConflict(base_revision, rev)
        return rev

    def mutate(self, base_revision: int, actor: Actor, message: str, action: str, target: str | None,
               fn: Callable[[dict[str, Any], sqlite3.Connection], dict[str, Any]]) -> int:
        """Apply `fn` to the live catalog (as a snapshot dict) and commit a new revision."""
        message = (message or "").strip()
        if not message:
            raise ValidationFailed(["message: required"])
        if len(message) > 500:
            raise ValidationFailed(["message: at most 500 characters"])
        if not isinstance(base_revision, int) or isinstance(base_revision, bool):
            raise ValidationFailed(["baseRevision: integer required"])
        now = self.clock()
        with self.db.tx() as conn:
            rev, body = self._current(conn)
            if base_revision != rev:
                raise RevisionConflict(base_revision, rev)
            new = parse_catalog(fn(body.snapshot(), conn))
            errors = validate_catalog(new)
            for e in new.exercises:
                if e.imageAssetID and not self.asset_exists(e.imageAssetID):
                    errors.append(f"exercise {e.id}: unknown imageAssetID")
            if errors:
                raise ValidationFailed(errors)
            new_rev = rev + 1
            self._insert(conn, new_rev, new, actor.author, message, now)
            audit(conn, fmt(now), now.timestamp(), actor.token, action, target, new_rev)
        return new_rev

    @staticmethod
    def _find(snap: dict[str, Any], exercise_id: str) -> dict[str, Any]:
        for e in snap["exercises"]:
            if e["id"] == exercise_id:
                return e
        raise NotFound(f"exercise {exercise_id} does not exist")

    def create_exercise(self, exercise: dict[str, Any], base_revision: int, actor: Actor, message: str) -> int:
        if not isinstance(exercise, dict):
            raise ValidationFailed(["exercise: object required"])
        try:
            ex = Exercise.model_validate(exercise)
        except ValidationError as exc:
            raise ValidationFailed(pydantic_errors(exc)) from exc
        if not EXERCISE_ID_PATTERN.match(ex.id):
            raise ValidationFailed([f"exercise {ex.id}: invalid id (pattern ^[a-z0-9][a-z0-9-]{{1,39}}$)"])

        def fn(snap: dict[str, Any], conn: sqlite3.Connection) -> dict[str, Any]:
            if any(e["id"] == ex.id for e in snap["exercises"]):
                raise AppError(f"exercise {ex.id} already exists", status=409, title="Conflict")
            if conn.execute("SELECT 1 FROM exercise_ids WHERE id = ?", (ex.id,)).fetchone():
                raise AppError(f"exercise id {ex.id} was used before and cannot be reused", status=409,
                               title="Conflict")
            snap["exercises"].append(ex.wire())
            return snap

        return self.mutate(base_revision, actor, message, "catalog.exercise.create", ex.id, fn)

    def update_exercise(self, exercise_id: str, patch: dict[str, Any], base_revision: int, actor: Actor,
                        message: str) -> int:
        if not isinstance(patch, dict) or not patch:
            raise ValidationFailed(["patch: non-empty object required"])
        if "id" in patch and patch["id"] != exercise_id:
            raise ValidationFailed(["id: exercise ids are immutable"])
        for key in ("name", "techniqueTip", "target", "equipment", "perSide", "switchesSideMidway", "archived"):
            if key in patch and patch[key] is None:
                raise ValidationFailed([f"{key}: cannot be null (only {', '.join(OPTIONAL_EXERCISE_FIELDS)} can)"])

        def fn(snap: dict[str, Any], conn: sqlite3.Connection) -> dict[str, Any]:
            current = self._find(snap, exercise_id)
            p = dict(patch)
            new_target = p.pop("target", None)
            updated = merge_patch(current, p)
            if new_target is not None:
                updated["target"] = new_target  # replaced wholesale (reps <-> time switch)
            if updated.get("archived") and not current.get("archived"):
                self._ensure_unused(snap, exercise_id)
            snap["exercises"] = [updated if e["id"] == exercise_id else e for e in snap["exercises"]]
            return snap

        return self.mutate(base_revision, actor, message, "catalog.exercise.update", exercise_id, fn)

    @staticmethod
    def _ensure_unused(snap: dict[str, Any], exercise_id: str) -> None:
        used = [w["id"] for w in snap["workouts"] if exercise_id in w["exerciseIDs"]]
        if used:
            raise ValidationFailed([f"exercise {exercise_id} is used in workout {', '.join(used)}; remove it first"])

    def set_archived(self, exercise_id: str, archived: bool, base_revision: int, actor: Actor, message: str) -> int:
        def fn(snap: dict[str, Any], conn: sqlite3.Connection) -> dict[str, Any]:
            e = self._find(snap, exercise_id)
            if archived:
                self._ensure_unused(snap, exercise_id)
            e["archived"] = archived
            return snap

        action = "catalog.exercise.archive" if archived else "catalog.exercise.unarchive"
        return self.mutate(base_revision, actor, message, action, exercise_id, fn)

    def set_workout(self, workout_id: str, name: str | None, exercise_ids: list[str] | None, base_revision: int,
                    actor: Actor, message: str) -> int:
        if name is None and exercise_ids is None:
            raise ValidationFailed(["name or exerciseIDs required"])
        if exercise_ids is not None and (
            not isinstance(exercise_ids, list) or not all(isinstance(x, str) for x in exercise_ids)
        ):
            raise ValidationFailed(["exerciseIDs: list of exercise ids required"])

        def fn(snap: dict[str, Any], conn: sqlite3.Connection) -> dict[str, Any]:
            w = next((x for x in snap["workouts"] if x["id"] == workout_id), None)
            if w is None:
                raise NotFound(f"workout {workout_id} does not exist (A, B or C)")
            if name is not None:
                w["name"] = name.strip()
            if exercise_ids is not None:
                w["exerciseIDs"] = list(exercise_ids)
            return snap

        return self.mutate(base_revision, actor, message, "catalog.workout.set", workout_id, fn)

    def set_descriptions(self, warm_up: str | None, stretch: str | None, base_revision: int, actor: Actor,
                         message: str) -> int:
        if warm_up is None and stretch is None:
            raise ValidationFailed(["warmUpDescription or stretchDescription required"])

        def fn(snap: dict[str, Any], conn: sqlite3.Connection) -> dict[str, Any]:
            if warm_up is not None:
                snap["warmUpDescription"] = warm_up.strip()
            if stretch is not None:
                snap["stretchDescription"] = stretch.strip()
            return snap

        return self.mutate(base_revision, actor, message, "catalog.descriptions.set", None, fn)

    def rollback(self, to_revision: int, base_revision: int, actor: Actor, message: str | None = None) -> int:
        old = self.revision_wire(to_revision)
        old.pop("revision")

        def fn(snap: dict[str, Any], conn: sqlite3.Connection) -> dict[str, Any]:
            return old

        return self.mutate(base_revision, actor, message or f"Návrat na revizi {to_revision}", "catalog.rollback",
                           str(to_revision), fn)
