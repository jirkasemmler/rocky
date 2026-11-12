"""Web admin `/admin` (SERVER-SPEC §9): server-rendered Czech HTML, cookie sessions bound to an
admin token (revoking the token ends the session), CSRF token on every form and admin API call,
Jinja autoescape, strict CSP, no JavaScript. Admin JSON API under `/admin/api`."""

from __future__ import annotations

import hashlib
import hmac
import secrets
from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from jinja2 import Environment, FileSystemLoader, select_autoescape
from starlette.concurrency import run_in_threadpool
from starlette.datastructures import UploadFile

from .api import asset_headers, note_token
from .catalog import Actor
from .context import AppContext
from .errors import AppError, RevisionConflict, ValidationFailed
from .images import MAX_BYTES, ImageRejected
from .sessions import summarize
from .timeutil import fmt
from .tokens import SCOPES, Token

HERE = Path(__file__).resolve().parent
COOKIE = "rocky_session"
LOGIN_CSRF_COOKIE = "rocky_login_csrf"
CSP = "default-src 'self'; img-src 'self'; style-src 'self'; script-src 'self'; frame-ancestors 'none'; form-action 'self'"

router = APIRouter()
templates = Environment(
    loader=FileSystemLoader(HERE / "templates"),
    autoescape=select_autoescape(default=True, default_for_string=True),
)
templates.filters["duration"] = lambda s: "" if s is None else f"{int(s) // 60}:{int(s) % 60:02d}"


class LoginRequired(AppError):
    status = 401
    title = "Login required"


@dataclass
class AdminSession:
    token: Token
    csrf: str

    @property
    def actor(self) -> Actor:
        return Actor(author="admin", token=self.token.name)


def ctx_of(request: Request) -> AppContext:
    return request.app.state.ctx


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def load_session(request: Request) -> AdminSession | None:
    sid = request.cookies.get(COOKIE)
    if not sid:
        return None
    ctx = ctx_of(request)
    now = ctx.settings.clock().timestamp()
    with ctx.db.read() as conn:
        row = conn.execute(
            "SELECT s.csrf, t.id, t.name, t.scope FROM admin_sessions s JOIN tokens t ON t.id = s.token_id "
            "WHERE s.id_hash = ? AND s.expires_at > ? AND t.revoked_at IS NULL AND t.scope = 'admin'",
            (_hash(sid), now),
        ).fetchone()
    if row is None:
        return None
    token = Token(row["id"], row["name"], row["scope"])
    note_token(request, token)
    return AdminSession(token, row["csrf"])


def require_page(request: Request) -> AdminSession:
    s = load_session(request)
    if s is None:
        raise LoginRequired("login required")
    return s


def check_csrf(session: AdminSession, value: str | None) -> None:
    if not value or not hmac.compare_digest(value, session.csrf):
        raise AppError("invalid CSRF token", status=403, title="Forbidden")


def require_api(request: Request) -> AdminSession:
    s = load_session(request)
    if s is None:
        raise AppError("admin session required (log in at /admin/login)", status=401, title="Unauthorized")
    if request.method not in ("GET", "HEAD"):
        check_csrf(s, request.headers.get("x-csrf-token"))
    return s


def security_headers(response: Response) -> Response:
    response.headers["Content-Security-Policy"] = CSP
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers.setdefault("Cache-Control", "no-store")
    return response


def render(name: str, status: int = 200, **values: Any) -> HTMLResponse:
    html = templates.get_template(name).render(**values)
    return security_headers(HTMLResponse(html, status_code=status))


def redirect(url: str) -> Response:
    return security_headers(RedirectResponse(url, status_code=303))


def html_error(request: Request, exc: AppError) -> Response:
    if isinstance(exc, LoginRequired):
        return redirect("/admin/login")
    session = load_session(request)
    return render("error.html", status=exc.status, session=session, title=exc.title, detail=exc.detail,
                  errors=getattr(exc, "errors", None))


def czech_error(exc: AppError) -> str:
    if isinstance(exc, RevisionConflict):
        return (f"Katalog se mezitím změnil (aktuální revize {exc.current}). Načti stránku znovu a změnu "
                "zopakuj.")
    if isinstance(exc, ValidationFailed):
        return "Neplatná data: " + "; ".join(exc.errors)
    if isinstance(exc, ImageRejected):
        return "Obrázek nelze použít: " + exc.detail
    return exc.detail


def _int(value: Any, field: str) -> int:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError) as exc:
        raise ValidationFailed([f"{field}: číslo"]) from exc


async def _form(request: Request, session: AdminSession) -> dict[str, Any]:
    form = await request.form()
    check_csrf(session, form.get("csrf"))
    return {k: form.get(k) for k in form.keys()}


# ------------------------------------------------------------------ login / logout


@router.get("/admin/login")
def login_page(request: Request) -> Response:
    if load_session(request):
        return redirect("/admin/exercises")
    csrf = secrets.token_urlsafe(24)
    resp = render("login.html", csrf=csrf, session=None)
    _set_cookie(request, resp, LOGIN_CSRF_COOKIE, csrf, max_age=3600, path="/admin/login")
    return resp


def _set_cookie(request: Request, resp: Response, name: str, value: str, max_age: int, path: str = "/admin"):
    resp.set_cookie(name, value, max_age=max_age, path=path, httponly=True,
                    secure=ctx_of(request).settings.cookie_secure, samesite="strict")


@router.post("/admin/login")
async def login(request: Request) -> Response:
    form = await request.form()
    cookie = request.cookies.get(LOGIN_CSRF_COOKIE)
    sent = form.get("csrf")
    if not cookie or not sent or not hmac.compare_digest(str(sent), cookie):
        raise AppError("Neplatný formulář, načti přihlášení znovu.", status=403, title="Forbidden")
    ctx = ctx_of(request)
    token = await run_in_threadpool(ctx.tokens.verify, str(form.get("token") or "").strip())
    if token is None or token.scope != "admin":
        csrf = secrets.token_urlsafe(24)
        resp = render("login.html", status=401 if token is None else 403, csrf=csrf, session=None,
                      error="Neplatný token." if token is None else "Token nemá oprávnění admin.")
        _set_cookie(request, resp, LOGIN_CSRF_COOKIE, csrf, max_age=3600, path="/admin/login")
        return resp
    sid = secrets.token_urlsafe(32)
    now = ctx.settings.clock()
    expires = now + timedelta(hours=ctx.settings.session_hours)
    with ctx.db.tx() as conn:
        conn.execute("DELETE FROM admin_sessions WHERE expires_at <= ?", (now.timestamp(),))
        conn.execute(
            "INSERT INTO admin_sessions (id_hash, token_id, csrf, created_at, expires_at) VALUES (?, ?, ?, ?, ?)",
            (_hash(sid), token.id, secrets.token_urlsafe(32), fmt(now), expires.timestamp()),
        )
    note_token(request, token)
    resp = redirect("/admin/exercises")
    _set_cookie(request, resp, COOKIE, sid, max_age=ctx.settings.session_hours * 3600)
    resp.delete_cookie(LOGIN_CSRF_COOKIE, path="/admin/login")
    return resp


@router.post("/admin/logout")
async def logout(request: Request) -> Response:
    session = require_page(request)
    await _form(request, session)
    ctx = ctx_of(request)
    with ctx.db.tx() as conn:
        conn.execute("DELETE FROM admin_sessions WHERE id_hash = ?", (_hash(request.cookies[COOKIE]),))
    resp = redirect("/admin/login")
    resp.delete_cookie(COOKIE, path="/admin")
    return resp


@router.get("/admin")
@router.get("/admin/")
def admin_home(request: Request) -> Response:
    require_page(request)
    return redirect("/admin/exercises")


@router.get("/admin/static/admin.css")
def admin_css() -> Response:
    css = (HERE / "static" / "admin.css").read_text()
    return security_headers(Response(css, media_type="text/css", headers={"Cache-Control": "private, max-age=3600"}))


@router.get("/admin/assets/{sha256}")
def admin_asset(sha256: str, request: Request) -> Response:
    require_page(request)
    data, mime = ctx_of(request).assets.get(sha256)
    return Response(data, media_type=mime, headers=asset_headers())


# ------------------------------------------------------------------ exercises


@router.get("/admin/exercises")
def exercises_page(request: Request) -> Response:
    session = require_page(request)
    rev, body = ctx_of(request).catalog.current()
    usage: dict[str, list[str]] = {}
    for w in body.workouts:
        for ex_id in w.exerciseIDs:
            usage.setdefault(ex_id, []).append(w.id)
    return render("exercises.html", session=session, revision=rev, exercises=body.exercises, usage=usage)


def _exercise_values(e) -> dict[str, Any]:
    target = e.target
    return {
        "id": e.id, "name": e.name, "techniqueTip": e.techniqueTip, "instructions": e.instructions or "",
        "equipment": e.equipment, "perSide": e.perSide, "switchesSideMidway": e.switchesSideMidway,
        "targetType": "time" if target.time else "reps",
        "min": target.time.minSeconds if target.time else target.reps.min,
        "max": target.time.maxSeconds if target.time else target.reps.max,
        "imageAssetID": e.imageAssetID, "archived": e.archived,
    }


@router.get("/admin/exercises/new")
def new_exercise_page(request: Request) -> Response:
    session = require_page(request)
    rev, _ = ctx_of(request).catalog.current()
    values = {"id": "", "name": "", "techniqueTip": "", "instructions": "", "equipment": "bodyweight",
              "perSide": False, "switchesSideMidway": False, "targetType": "reps", "min": 10, "max": 12,
              "imageAssetID": None, "archived": False}
    return render("exercise_form.html", session=session, revision=rev, values=values, is_new=True)


@router.get("/admin/exercises/{exercise_id}")
def edit_exercise_page(exercise_id: str, request: Request) -> Response:
    session = require_page(request)
    rev, body = ctx_of(request).catalog.current()
    e = body.exercise(exercise_id)
    if e is None:
        raise AppError("Cvik neexistuje.", status=404, title="Nenalezeno")
    return render("exercise_form.html", session=session, revision=rev, values=_exercise_values(e), is_new=False)


def _exercise_from_form(f: dict[str, Any]) -> dict[str, Any]:
    lo, hi = _int(f.get("min"), "min"), _int(f.get("max"), "max")
    target = ({"time": {"minSeconds": lo, "maxSeconds": hi}} if f.get("targetType") == "time"
              else {"reps": {"min": lo, "max": hi}})
    instructions = str(f.get("instructions") or "").replace("\r\n", "\n").strip()
    return {
        "name": str(f.get("name") or "").strip(),
        "techniqueTip": str(f.get("techniqueTip") or "").strip(),
        "instructions": instructions or None,
        "equipment": f.get("equipment") or "bodyweight",
        "perSide": f.get("perSide") == "on",
        "switchesSideMidway": f.get("switchesSideMidway") == "on",
        "target": target,
    }


async def _upload(request: Request, f: dict[str, Any]) -> str | None:
    image = f.get("image")
    if isinstance(image, UploadFile) and image.filename:
        data = await image.read(MAX_BYTES + 1)
        if data:
            return await run_in_threadpool(ctx_of(request).assets.put, data)
    return None


@router.post("/admin/exercises/new")
async def create_exercise_form(request: Request) -> Response:
    session = require_page(request)
    f = await _form(request, session)
    ctx = ctx_of(request)
    try:
        ex = _exercise_from_form(f)
        ex["id"] = str(f.get("id") or "").strip()
        sha = await _upload(request, f)
        if sha:
            ex["imageAssetID"] = sha
        base = _int(f.get("base_revision"), "base_revision")
        message = str(f.get("message") or "").strip() or f"Nový cvik {ex['id']}"
        await run_in_threadpool(ctx.catalog.create_exercise, ex, base, session.actor, message)
    except AppError as exc:
        return _form_error(request, session, f, exc, is_new=True)
    return redirect("/admin/exercises")


@router.post("/admin/exercises/{exercise_id}")
async def update_exercise_form(exercise_id: str, request: Request) -> Response:
    session = require_page(request)
    f = await _form(request, session)
    ctx = ctx_of(request)
    try:
        patch = _exercise_from_form(f)
        sha = await _upload(request, f)
        if sha:
            patch["imageAssetID"] = sha
        elif f.get("removeImage") == "on":
            patch["imageAssetID"] = None
        base = _int(f.get("base_revision"), "base_revision")
        message = str(f.get("message") or "").strip() or f"Úprava cviku {exercise_id}"
        await run_in_threadpool(ctx.catalog.update_exercise, exercise_id, patch, base, session.actor, message)
    except AppError as exc:
        f["id"] = exercise_id
        return _form_error(request, session, f, exc, is_new=False)
    return redirect("/admin/exercises")


def _form_error(request: Request, session: AdminSession, f: dict[str, Any], exc: AppError, is_new: bool):
    rev, body = ctx_of(request).catalog.current()
    current = body.exercise(str(f.get("id") or ""))
    values = {
        "id": f.get("id") or "", "name": f.get("name") or "", "techniqueTip": f.get("techniqueTip") or "",
        "instructions": f.get("instructions") or "", "equipment": f.get("equipment") or "bodyweight",
        "perSide": f.get("perSide") == "on", "switchesSideMidway": f.get("switchesSideMidway") == "on",
        "targetType": f.get("targetType") or "reps", "min": f.get("min") or "", "max": f.get("max") or "",
        "imageAssetID": current.imageAssetID if current and not is_new else None,
        "archived": current.archived if current else False,
    }
    return render("exercise_form.html", status=exc.status if exc.status != 401 else 400, session=session,
                  revision=rev, values=values, is_new=is_new, error=czech_error(exc))


@router.post("/admin/exercises/{exercise_id}/archive")
async def archive_form(exercise_id: str, request: Request) -> Response:
    session = require_page(request)
    f = await _form(request, session)
    archived = f.get("archived") == "1"
    base = _int(f.get("base_revision"), "base_revision")
    msg = f"{'Archivace' if archived else 'Obnovení'} cviku {exercise_id}"
    try:
        await run_in_threadpool(ctx_of(request).catalog.set_archived, exercise_id, archived, base, session.actor,
                                msg)
    except AppError as exc:
        raise AppError(czech_error(exc), status=exc.status, title="Nelze uložit") from exc
    return redirect("/admin/exercises")


# ------------------------------------------------------------------ workouts, descriptions


@router.get("/admin/workouts")
def workouts_page(request: Request) -> Response:
    session = require_page(request)
    rev, body = ctx_of(request).catalog.current()
    available = [e for e in body.exercises if not e.archived]
    return render("workouts.html", session=session, revision=rev, workouts=body.workouts, available=available)


@router.post("/admin/workouts/{workout_id}")
async def workout_form(workout_id: str, request: Request) -> Response:
    session = require_page(request)
    f = await _form(request, session)
    ids = [x.strip() for x in str(f.get("exerciseIDs") or "").replace("\n", ",").split(",") if x.strip()]
    base = _int(f.get("base_revision"), "base_revision")
    try:
        await run_in_threadpool(ctx_of(request).catalog.set_workout, workout_id, str(f.get("name") or ""), ids,
                                base, session.actor, f"Úprava tréninku {workout_id}")
    except AppError as exc:
        raise AppError(czech_error(exc), status=exc.status, title="Nelze uložit") from exc
    return redirect("/admin/workouts")


@router.get("/admin/descriptions")
def descriptions_page(request: Request) -> Response:
    session = require_page(request)
    rev, body = ctx_of(request).catalog.current()
    return render("descriptions.html", session=session, revision=rev, warm_up=body.warmUpDescription,
                  stretch=body.stretchDescription)


@router.post("/admin/descriptions")
async def descriptions_form(request: Request) -> Response:
    session = require_page(request)
    f = await _form(request, session)
    base = _int(f.get("base_revision"), "base_revision")
    try:
        await run_in_threadpool(ctx_of(request).catalog.set_descriptions, str(f.get("warmUp") or ""),
                                str(f.get("stretch") or ""), base, session.actor, "Úprava popisů")
    except AppError as exc:
        raise AppError(czech_error(exc), status=exc.status, title="Nelze uložit") from exc
    return redirect("/admin/descriptions")


# ------------------------------------------------------------------ revisions, sessions


@router.get("/admin/revisions")
def revisions_page(request: Request) -> Response:
    session = require_page(request)
    ctx = ctx_of(request)
    rev, _ = ctx.catalog.current()
    return render("revisions.html", session=session, revision=rev, revisions=ctx.catalog.revisions(200))


@router.post("/admin/revisions/{target}/rollback")
async def rollback_form(target: int, request: Request) -> Response:
    session = require_page(request)
    f = await _form(request, session)
    base = _int(f.get("base_revision"), "base_revision")
    try:
        await run_in_threadpool(ctx_of(request).catalog.rollback, target, base, session.actor, None)
    except AppError as exc:
        raise AppError(czech_error(exc), status=exc.status, title="Nelze vrátit") from exc
    return redirect("/admin/revisions")


@router.get("/admin/sessions")
def sessions_page(request: Request) -> Response:
    session = require_page(request)
    ctx = ctx_of(request)
    _, body = ctx.catalog.current()
    names = {e.id: e.name for e in body.exercises}
    items = [summarize(s, names) for s in ctx.records.sessions(None, None, 500)]
    return render("sessions.html", session=session, sessions=items)


# ------------------------------------------------------------------ tokens


@router.get("/admin/tokens")
def tokens_page(request: Request) -> Response:
    session = require_page(request)
    return render("tokens.html", session=session, tokens=ctx_of(request).tokens.list(), scopes=SCOPES)


@router.post("/admin/tokens")
async def create_token_form(request: Request) -> Response:
    session = require_page(request)
    f = await _form(request, session)
    ctx = ctx_of(request)
    name, scope = str(f.get("name") or ""), str(f.get("scope") or "")
    try:
        secret = await run_in_threadpool(ctx.tokens.create, name, scope, session.token.name)
    except AppError as exc:
        return render("tokens.html", status=exc.status, session=session, tokens=ctx.tokens.list(), scopes=SCOPES,
                      error=exc.detail)
    return render("tokens.html", session=session, tokens=ctx.tokens.list(), scopes=SCOPES,
                  created={"name": name.strip(), "scope": scope, "secret": secret})


@router.post("/admin/tokens/{token_id}/revoke")
async def revoke_token_form(token_id: int, request: Request) -> Response:
    session = require_page(request)
    await _form(request, session)
    await run_in_threadpool(ctx_of(request).tokens.revoke, token_id, session.token.name)
    if token_id == session.token.id:
        return redirect("/admin/login")
    return redirect("/admin/tokens")


# ------------------------------------------------------------------ admin JSON API (cookie + X-CSRF-Token)


async def _json(request: Request) -> dict[str, Any]:
    try:
        data = await request.json()
    except ValueError as exc:
        raise AppError("body is not valid JSON") from exc
    if not isinstance(data, dict):
        raise AppError("body must be a JSON object")
    return data


def _base(data: dict[str, Any]) -> int:
    base = data.get("baseRevision")
    if not isinstance(base, int) or isinstance(base, bool):
        raise ValidationFailed(["baseRevision: integer required"])
    return base


@router.get("/admin/api/session")
def api_session(request: Request) -> JSONResponse:
    s = require_api(request)
    return JSONResponse({"token": s.token.name, "csrfToken": s.csrf})


@router.get("/admin/api/catalog")
def api_catalog(request: Request) -> JSONResponse:
    require_api(request)
    return JSONResponse(ctx_of(request).catalog.current_wire())


@router.get("/admin/api/exercises")
def api_exercises(request: Request) -> JSONResponse:
    require_api(request)
    rev, body = ctx_of(request).catalog.current()
    return JSONResponse({"revision": rev, "exercises": [e.wire() for e in body.exercises]})


@router.post("/admin/api/exercises")
async def api_create_exercise(request: Request) -> JSONResponse:
    s = require_api(request)
    d = await _json(request)
    rev = await run_in_threadpool(ctx_of(request).catalog.create_exercise, d.get("exercise"), _base(d), s.actor,
                                  d.get("message") or "Nový cvik")
    return JSONResponse({"revision": rev}, status_code=201)


@router.patch("/admin/api/exercises/{exercise_id}")
async def api_update_exercise(exercise_id: str, request: Request) -> JSONResponse:
    s = require_api(request)
    d = await _json(request)
    rev = await run_in_threadpool(ctx_of(request).catalog.update_exercise, exercise_id, d.get("patch"), _base(d),
                                  s.actor, d.get("message") or f"Úprava cviku {exercise_id}")
    return JSONResponse({"revision": rev})


@router.put("/admin/api/workouts/{workout_id}")
async def api_set_workout(workout_id: str, request: Request) -> JSONResponse:
    s = require_api(request)
    d = await _json(request)
    rev = await run_in_threadpool(ctx_of(request).catalog.set_workout, workout_id, d.get("name"),
                                  d.get("exerciseIDs"), _base(d), s.actor,
                                  d.get("message") or f"Úprava tréninku {workout_id}")
    return JSONResponse({"revision": rev})


@router.put("/admin/api/descriptions")
async def api_set_descriptions(request: Request) -> JSONResponse:
    s = require_api(request)
    d = await _json(request)
    rev = await run_in_threadpool(ctx_of(request).catalog.set_descriptions, d.get("warmUpDescription"),
                                  d.get("stretchDescription"), _base(d), s.actor, d.get("message") or "Úprava popisů")
    return JSONResponse({"revision": rev})


@router.post("/admin/api/assets")
async def api_upload_asset(request: Request) -> JSONResponse:
    require_api(request)
    form = await request.form()
    file = form.get("file")
    if not isinstance(file, UploadFile):
        raise AppError("multipart field 'file' required")
    data = await file.read(MAX_BYTES + 1)
    sha = await run_in_threadpool(ctx_of(request).assets.put, data)
    return JSONResponse({"sha256": sha}, status_code=201)


@router.post("/admin/api/rollback")
async def api_rollback(request: Request) -> JSONResponse:
    s = require_api(request)
    d = await _json(request)
    target = d.get("revision")
    if not isinstance(target, int) or isinstance(target, bool):
        raise ValidationFailed(["revision: integer required"])
    rev = await run_in_threadpool(ctx_of(request).catalog.rollback, target, _base(d), s.actor, d.get("message"))
    return JSONResponse({"revision": rev})
