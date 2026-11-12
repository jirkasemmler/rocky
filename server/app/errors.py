"""Domain errors and RFC 9457 problem responses."""

from __future__ import annotations

from typing import Any

from fastapi.responses import JSONResponse

PROBLEM_JSON = "application/problem+json"


class AppError(Exception):
    """An error with an HTTP status and a problem body. `extra` members are added to the body."""

    status = 400
    title = "Bad Request"

    def __init__(self, detail: str, *, status: int | None = None, title: str | None = None,
                 headers: dict[str, str] | None = None, **extra: Any):
        super().__init__(detail)
        self.detail = detail
        if status is not None:
            self.status = status
        if title is not None:
            self.title = title
        self.headers = headers
        self.extra = extra


class NotFound(AppError):
    status = 404
    title = "Not Found"


class ValidationFailed(AppError):
    status = 422
    title = "Validation failed"

    def __init__(self, errors: list[str]):
        super().__init__("; ".join(errors), errors=errors)
        self.errors = errors


class RevisionConflict(AppError):
    """`baseRevision` does not match the live catalog (SERVER-SPEC §5)."""

    status = 409
    title = "Catalog revision conflict"

    def __init__(self, base: int, current: int):
        super().__init__(
            f"baseRevision {base} does not match the current catalog revision {current}",
            currentRevision=current,
        )
        self.current = current


class RecordConflict(AppError):
    """Version mismatch on a synced record: body carries `current` (SERVER-SPEC §5)."""

    status = 409
    title = "Record version conflict"

    def __init__(self, current: dict[str, Any]):
        super().__init__("record version does not match", current=current)


class RecordGone(AppError):
    status = 410
    title = "Record deleted"


def problem(status: int, title: str, detail: str | None = None, headers: dict[str, str] | None = None,
            **extra: Any) -> JSONResponse:
    body: dict[str, Any] = {"type": "about:blank", "title": title, "status": status}
    if detail:
        body["detail"] = detail
    body.update(extra)
    return JSONResponse(body, status_code=status, media_type=PROBLEM_JSON, headers=headers)


def app_error_response(exc: AppError) -> JSONResponse:
    return problem(exc.status, exc.title, exc.detail, exc.headers, **exc.extra)
