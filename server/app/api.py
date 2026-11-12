"""Device REST API, `/api/v1` (SERVER-SPEC §5)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import JSONResponse, Response
from starlette.concurrency import run_in_threadpool

from .context import AppContext, bearer_token
from .errors import AppError
from .tokens import Token

router = APIRouter(prefix="/api/v1")


def get_ctx(request: Request) -> AppContext:
    return request.app.state.ctx


def note_token(request: Request, token: Token) -> None:
    """Remember the token name for the access log (never the secret)."""
    request.scope.setdefault("rocky", {})["token"] = token.name


def require_scope(scope: str):
    def dep(request: Request) -> Token:
        ctx = get_ctx(request)
        token, present = bearer_token(request.headers, ctx)
        if token is None:
            raise AppError(
                "invalid token" if present else "Authorization: Bearer <token> required",
                status=401, title="Unauthorized", headers={"WWW-Authenticate": "Bearer"},
            )
        note_token(request, token)
        if token.scope != scope:
            raise AppError(f"this endpoint needs a {scope} token", status=403, title="Forbidden")
        return token

    return dep


device = require_scope("device")


def _etag_matches(header: str | None, etag: str) -> bool:
    if not header:
        return False
    for part in header.split(","):
        p = part.strip()
        if p == "*" or p.removeprefix("W/") == etag:
            return True
    return False


@router.get("/catalog")
def get_catalog(request: Request, _: Token = Depends(device)) -> Response:
    ctx = get_ctx(request)
    body = ctx.catalog.current_wire()
    etag = f'"rev-{body["revision"]}"'
    headers = {"ETag": etag, "Cache-Control": "private, no-cache"}
    if _etag_matches(request.headers.get("if-none-match"), etag):
        return Response(status_code=304, headers=headers)
    return JSONResponse(body, headers=headers)


@router.get("/assets/{sha256}")
def get_asset(sha256: str, request: Request, _: Token = Depends(device)) -> Response:
    data, mime = get_ctx(request).assets.get(sha256)
    return Response(data, media_type=mime, headers=asset_headers())


def asset_headers() -> dict[str, str]:
    return {
        "Cache-Control": "private, max-age=31536000, immutable",
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'none'",
    }


@router.put("/records/{kind}/{key}")
async def put_record(kind: str, key: str, request: Request, token: Token = Depends(device)) -> JSONResponse:
    body = await request.body()
    status, result = await run_in_threadpool(
        get_ctx(request).records.put,
        kind, key, body, request.headers.get("if-match"), request.headers.get("if-none-match"), token.name,
    )
    return JSONResponse(result, status_code=status)


@router.delete("/records/{kind}/{key}")
def delete_record(kind: str, key: str, request: Request, token: Token = Depends(device)) -> JSONResponse:
    result = get_ctx(request).records.delete(kind, key, request.headers.get("if-match"), token.name)
    return JSONResponse(result)


@router.get("/changes")
def changes(request: Request, since: int = Query(0, ge=0), limit: int = Query(500, ge=1, le=1000),
            _: Token = Depends(device)) -> JSONResponse:
    return JSONResponse(get_ctx(request).records.changes(since, limit))
