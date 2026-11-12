"""Dates in the RockyCore wire format: ISO 8601 without fractional seconds (SERVER-SPEC §3)."""

from __future__ import annotations

import re
from datetime import UTC, datetime

# What Swift's JSONDecoder `.iso8601` strategy accepts: no fractional seconds, Z or ±HH:MM.
_SWIFT_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:?\d{2})$")


def fmt(dt: datetime) -> str:
    """`2026-11-12T19:00:00Z` (UTC, seconds precision)."""
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_swift_date(value: str) -> datetime:
    """Parse a date the Swift side can decode; raise ValueError otherwise."""
    if not isinstance(value, str) or not _SWIFT_DATE.match(value):
        raise ValueError("date must be ISO 8601 without fractional seconds, e.g. 2026-11-12T19:00:00Z")
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    return datetime.fromisoformat(text).astimezone(UTC)


def parse_query_instant(value: str, end_of_day: bool = False) -> datetime:
    """Lenient parse for query parameters: `YYYY-MM-DD` or any ISO 8601 date-time (UTC if naive)."""
    value = value.strip()
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        d = datetime.fromisoformat(value).replace(tzinfo=UTC)
        if end_of_day:
            d = d.replace(hour=23, minute=59, second=59)
        return d
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    d = datetime.fromisoformat(text)
    if d.tzinfo is None:
        d = d.replace(tzinfo=UTC)
    return d.astimezone(UTC)
