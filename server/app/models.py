"""Wire models (RockyCore Codable JSON, SERVER-SPEC §3/§4) and catalog validation (§4.1)."""

from __future__ import annotations

import re
import unicodedata
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from .timeutil import parse_swift_date

EXERCISE_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{1,39}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
UUID_UPPER = re.compile(r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")
DAY_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")
WORKOUT_IDS = ("A", "B", "C")


def text_length(s: str) -> int:
    """Approximates Swift `String.count` (grapheme clusters): NFC code points minus combining
    marks, zero-width joiners and variation selectors. Identical for ordinary Czech text."""
    n = 0
    for ch in unicodedata.normalize("NFC", s):
        if unicodedata.combining(ch) or ch == "‍" or "︀" <= ch <= "️":
            continue
        n += 1
    return n


# ---------------------------------------------------------------- catalog


class RepsRange(BaseModel):
    model_config = ConfigDict(extra="forbid")
    min: int
    max: int


class TimeRange(BaseModel):
    model_config = ConfigDict(extra="forbid")
    minSeconds: int
    maxSeconds: int


class ExerciseTarget(BaseModel):
    """`{"reps":{"min":12,"max":15}}` or `{"time":{"minSeconds":30,"maxSeconds":45}}`."""

    model_config = ConfigDict(extra="forbid")
    reps: RepsRange | None = None
    time: TimeRange | None = None

    @model_validator(mode="after")
    def _exactly_one(self) -> ExerciseTarget:
        if (self.reps is None) == (self.time is None):
            raise ValueError('target must be exactly one of {"reps":{min,max}} or {"time":{minSeconds,maxSeconds}}')
        return self


class Exercise(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str
    name: str
    techniqueTip: str
    target: ExerciseTarget
    equipment: Literal["bodyweight", "dumbbells"]
    perSide: bool = False
    # Swift's initializer defaults this to `perSide`.
    switchesSideMidway: bool | None = None
    instructions: str | None = None
    imageAssetID: str | None = None
    archived: bool = False

    @model_validator(mode="after")
    def _defaults(self) -> Exercise:
        if self.switchesSideMidway is None:
            self.switchesSideMidway = self.perSide
        return self

    @field_validator("imageAssetID")
    @classmethod
    def _sha(cls, v: str | None) -> str | None:
        if v is not None and not SHA256_PATTERN.match(v):
            raise ValueError("imageAssetID must be a lowercase sha256 hex digest")
        return v

    def wire(self) -> dict[str, Any]:
        """Swift-compatible dict: nil optionals omitted (like the Swift encoder)."""
        return self.model_dump(exclude_none=True)


class WorkoutEntry(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: Literal["A", "B", "C"]
    name: str
    exerciseIDs: list[str]


class CatalogBody(BaseModel):
    """Catalog document without `revision` (what a revision snapshot stores)."""

    model_config = ConfigDict(extra="ignore")
    warmUpDescription: str
    stretchDescription: str
    exercises: list[Exercise]
    workouts: list[WorkoutEntry]

    def wire(self, revision: int) -> dict[str, Any]:
        return {
            "revision": revision,
            "warmUpDescription": self.warmUpDescription,
            "stretchDescription": self.stretchDescription,
            "exercises": [e.wire() for e in self.exercises],
            "workouts": [w.model_dump() for w in self.workouts],
        }

    def snapshot(self) -> dict[str, Any]:
        d = self.wire(0)
        del d["revision"]
        return d

    def exercise(self, exercise_id: str) -> Exercise | None:
        return next((e for e in self.exercises if e.id == exercise_id), None)


def validate_catalog(c: CatalogBody) -> list[str]:
    """Same rules as RockyCore `Catalog.validate()` (Packages/RockyCore/.../Catalog.swift).
    Empty list = valid."""
    errors: list[str] = []
    seen: set[str] = set()
    for e in c.exercises:
        if not EXERCISE_ID_PATTERN.match(e.id):
            errors.append(f"exercise {e.id}: invalid id")
        if e.id in seen:
            errors.append(f"exercise {e.id}: duplicate id")
        seen.add(e.id)
        if not 1 <= text_length(e.name) <= 60:
            errors.append(f"exercise {e.id}: name length")
        if text_length(e.techniqueTip) > 200:
            errors.append(f"exercise {e.id}: tip too long")
        if e.instructions is not None and text_length(e.instructions) > 2000:
            errors.append(f"exercise {e.id}: instructions too long")
        if e.target.reps is not None:
            r = e.target.reps
            if not (1 <= r.min <= 100 and 1 <= r.max <= 100 and r.min <= r.max):
                errors.append(f"exercise {e.id}: reps range")
        elif e.target.time is not None:
            t = e.target.time
            if not (5 <= t.minSeconds <= 300 and 5 <= t.maxSeconds <= 300 and t.minSeconds <= t.maxSeconds):
                errors.append(f"exercise {e.id}: time range")
        if e.switchesSideMidway and not e.perSide:
            errors.append(f"exercise {e.id}: side switch without perSide")
    by_id = {e.id: e for e in c.exercises}
    seen_workouts: set[str] = set()
    for w in c.workouts:
        if w.id in seen_workouts:
            errors.append(f"workout {w.id}: duplicate")
        seen_workouts.add(w.id)
    for wid in WORKOUT_IDS:
        w = next((x for x in c.workouts if x.id == wid), None)
        if w is None:
            errors.append(f"workout {wid}: missing")
            continue
        if not 1 <= len(w.exerciseIDs) <= 8:
            errors.append(f"workout {wid}: 1–8 exercises")
        if len(set(w.exerciseIDs)) != len(w.exerciseIDs):
            errors.append(f"workout {wid}: duplicates")
        for ex_id in w.exerciseIDs:
            e = by_id.get(ex_id)
            if e is None:
                errors.append(f"workout {wid}: unknown exercise {ex_id}")
            elif e.archived:
                errors.append(f"workout {wid}: archived exercise {ex_id}")
        if not 1 <= text_length(w.name) <= 60:
            errors.append(f"workout {wid}: name length")
    for name, text in (("warmUpDescription", c.warmUpDescription), ("stretchDescription", c.stretchDescription)):
        if not 1 <= text_length(text) <= 500:
            errors.append(f"{name}: length")
    return errors


# ---------------------------------------------------------------- synced record payloads
# Structural checks only; unknown keys are allowed (the Swift side grows fields). The server
# stores the received bytes, never these models.


def _swift_date(v: Any) -> Any:
    parse_swift_date(v)
    return v


class SessionPayload(BaseModel):
    model_config = ConfigDict(extra="allow")
    id: str
    date: str
    workoutID: Literal["A", "B", "C"]
    kind: Literal["planned", "catchUp", "easyReturn", "bonus"]
    rounds: int
    weight: int
    difficulty: int | None = Field(default=None, ge=1, le=5)
    note: str
    completed: bool
    checklist: dict[str, Any]
    timings: list[dict[str, Any]]
    plannedSeconds: float
    finishedAt: str | None = None
    workout: dict[str, Any] | None = None

    @field_validator("id")
    @classmethod
    def _uuid(cls, v: str) -> str:
        if not UUID_UPPER.match(v):
            raise ValueError("id must be an uppercase UUID")
        return v

    @field_validator("date", "finishedAt")
    @classmethod
    def _dates(cls, v: str | None) -> str | None:
        return None if v is None else _swift_date(v)


class PostponementPayload(BaseModel):
    model_config = ConfigDict(extra="allow")
    date: str
    reason: Literal["illness", "injury", "travel"]
    day: str

    @field_validator("date")
    @classmethod
    def _date(cls, v: str) -> str:
        return _swift_date(v)


class ProfilePayload(BaseModel):
    model_config = ConfigDict(extra="allow")
    planStart: str
    settings: dict[str, Any]

    @field_validator("planStart")
    @classmethod
    def _date(cls, v: str) -> str:
        return _swift_date(v)


RecordKind = Literal["session", "postponement", "profile"]
RECORD_KINDS = ("session", "postponement", "profile")
