"""ASGI application: REST API, MCP, web admin, middleware (body limit, access log, problems)."""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import time

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from . import admin, api
from .backup import nightly
from .config import Settings
from .context import AppContext
from .errors import AppError, app_error_response, problem
from .mcp_server import MCPEndpoint

log = logging.getLogger("rocky.access")
MAX_BODY = 4 * 1024 * 1024


class BodyLimitMiddleware:
    """Rejects request bodies over 4 MB (SERVER-SPEC §5), by Content-Length and while streaming."""

    def __init__(self, app, limit: int = MAX_BODY):
        self.app = app
        self.limit = limit

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        for k, v in scope["headers"]:
            if k == b"content-length" and v.isdigit() and int(v) > self.limit:
                return await _send_problem(send, 413, "Content Too Large", "request body is larger than 4 MB")
        seen = 0

        async def limited_receive():
            nonlocal seen
            message = await receive()
            if message["type"] == "http.request":
                seen += len(message.get("body", b""))
                if seen > self.limit:
                    raise _TooLarge()
            return message

        try:
            await self.app(scope, limited_receive, send)
        except _TooLarge:
            await _send_problem(send, 413, "Content Too Large", "request body is larger than 4 MB")


class _TooLarge(Exception):
    pass


async def _send_problem(send, status: int, title: str, detail: str) -> None:
    body = json.dumps({"type": "about:blank", "title": title, "status": status, "detail": detail}).encode()
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-type", b"application/problem+json"),
                            (b"content-length", str(len(body)).encode())]})
    await send({"type": "http.response.body", "body": body})


class AccessLogMiddleware:
    """method, path, status, token name, duration — no bodies, no tokens (SERVER-SPEC §11)."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        start = time.perf_counter()
        status = 0

        async def send_wrapper(message):
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            token = scope.get("rocky", {}).get("token", "-")
            log.info("%s %s %s %s %.1fms", scope["method"], scope["path"], status, token,
                     (time.perf_counter() - start) * 1000)


class MCPRouter:
    """Sends `/mcp` (with or without the trailing slash, no redirect) to the MCP endpoint."""

    def __init__(self, app, mcp: MCPEndpoint):
        self.app = app
        self.mcp = mcp

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and scope["path"] in ("/mcp", "/mcp/"):
            return await self.mcp(scope, receive, send)
        return await self.app(scope, receive, send)


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    ctx = AppContext.open(settings)
    ctx.catalog.seed_if_empty(settings.seed_path)
    mcp = MCPEndpoint(ctx)

    @contextlib.asynccontextmanager
    async def lifespan(app: FastAPI):
        backup_task = asyncio.create_task(nightly(settings)) if settings.backups_enabled else None
        async with mcp.session_manager.run():
            yield
        if backup_task:
            backup_task.cancel()

    app = FastAPI(title="Rocky server", version="1", lifespan=lifespan, docs_url=None, redoc_url=None,
                  openapi_url=None)
    app.state.ctx = ctx
    app.state.mcp = mcp

    @app.exception_handler(AppError)
    async def _app_error(request: Request, exc: AppError):
        if request.url.path.startswith("/admin") and not request.url.path.startswith("/admin/api"):
            return admin.html_error(request, exc)
        return app_error_response(exc)

    @app.exception_handler(HTTPException)
    async def _http_error(request: Request, exc: HTTPException):
        return problem(exc.status_code, _title(exc.status_code), str(exc.detail) if exc.detail else None,
                       getattr(exc, "headers", None))

    @app.exception_handler(RequestValidationError)
    async def _validation_error(request: Request, exc: RequestValidationError):
        errors = [f"{'.'.join(str(p) for p in e['loc'])}: {e['msg']}" for e in exc.errors()]
        return problem(422, "Validation failed", "; ".join(errors), errors=errors)

    @app.get("/healthz")
    def healthz() -> JSONResponse:
        return JSONResponse({"ok": True})

    app.include_router(api.router)
    app.include_router(admin.router)
    # Starlette: the middleware added last is the outermost.
    app.add_middleware(MCPRouter, mcp=mcp)
    app.add_middleware(BodyLimitMiddleware)
    app.add_middleware(AccessLogMiddleware)
    return app


def _title(status: int) -> str:
    from http import HTTPStatus

    try:
        return HTTPStatus(status).phrase
    except ValueError:
        return "Error"


def run() -> None:
    """`rocky-server`: uvicorn on 0.0.0.0:8787 (inside the container; compose publishes 127.0.0.1)."""
    import os

    import uvicorn

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    logging.getLogger("mcp").setLevel(logging.WARNING)  # per-request session chatter
    uvicorn.run(create_app(), host=os.environ.get("ROCKY_HOST", "0.0.0.0"),
                port=int(os.environ.get("ROCKY_PORT", "8787")), access_log=False, proxy_headers=True,
                forwarded_allow_ips="127.0.0.1")
