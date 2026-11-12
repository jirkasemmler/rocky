"""Read-only session summaries for the agent (MCP `list_sessions`) and the admin."""

from __future__ import annotations

from typing import Any

from .timeutil import parse_swift_date


def _seconds(start: str | None, end: str | None) -> float | None:
    if not start or not end:
        return None
    try:
        return (parse_swift_date(end) - parse_swift_date(start)).total_seconds()
    except ValueError:
        return None


def summarize(session: dict[str, Any], catalog_names: dict[str, str] | None = None) -> dict[str, Any]:
    workout = session.get("workout") or {}
    names = {e.get("id"): e.get("name") for e in workout.get("exercises", []) if isinstance(e, dict)}
    if catalog_names:
        for k, v in catalog_names.items():
            names.setdefault(k, v)
    timings = []
    for t in session.get("timings") or []:
        if not isinstance(t, dict):
            continue
        actual = _seconds(t.get("startedAt"), t.get("endedAt"))
        if actual is not None:
            actual = max(0.0, actual - float(t.get("pausedSeconds") or 0))
        item = {
            "kind": t.get("kind"),
            "round": t.get("round"),
            "exerciseID": t.get("exerciseID"),
            "exerciseName": names.get(t.get("exerciseID")) if t.get("exerciseID") else None,
            "plannedSeconds": t.get("plannedSeconds"),
            "actualSeconds": actual,
            "pausedSeconds": t.get("pausedSeconds"),
            "endReason": t.get("endReason"),
        }
        timings.append({k: v for k, v in item.items() if v is not None})
    return {
        "id": session.get("id"),
        "date": session.get("date"),
        "finishedAt": session.get("finishedAt"),
        "workoutID": session.get("workoutID"),
        "workoutName": workout.get("name"),
        "kind": session.get("kind"),
        "completed": session.get("completed"),
        "rounds": session.get("rounds"),
        "weightKg": session.get("weight"),
        "difficulty": session.get("difficulty"),
        "note": session.get("note"),
        "plannedSeconds": session.get("plannedSeconds"),
        "actualSeconds": _seconds(session.get("date"), session.get("finishedAt")),
        "timings": timings,
    }
