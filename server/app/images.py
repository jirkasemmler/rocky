"""Exercise images (SERVER-SPEC §10): PNG, JPEG, WebP, GIF; checked with Pillow; stored unchanged
under the sha256 of the bytes."""

from __future__ import annotations

import hashlib
import io
import os
import warnings
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

from .db import Database
from .errors import AppError, NotFound
from .timeutil import fmt

MAX_BYTES = 2 * 1024 * 1024
MAX_SIDE = 2048
MAX_PIXELS = 4_000_000
MAX_FRAMES = 120

_PILLOW_FORMAT = {"image/png": "PNG", "image/jpeg": "JPEG", "image/gif": "GIF", "image/webp": "WEBP"}


class ImageRejected(AppError):
    status = 422
    title = "Image rejected"


@dataclass(frozen=True)
class ImageInfo:
    mime: str
    width: int
    height: int
    frames: int


def sniff(data: bytes) -> str | None:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def check_image(data: bytes) -> ImageInfo:
    """Validate uploaded bytes; raise ImageRejected with a Czech-friendly English message."""
    if len(data) == 0:
        raise ImageRejected("empty file")
    if len(data) > MAX_BYTES:
        raise ImageRejected(f"image is larger than {MAX_BYTES // (1024 * 1024)} MB")
    mime = sniff(data)
    if mime is None:
        raise ImageRejected("unsupported image type (allowed: PNG, JPEG, WebP, GIF; SVG is not allowed)")
    with warnings.catch_warnings():
        warnings.simplefilter("error", Image.DecompressionBombWarning)
        try:
            im = Image.open(io.BytesIO(data), formats=[_PILLOW_FORMAT[mime]])
        except (Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
            raise ImageRejected("image has too many pixels") from exc
        except Exception as exc:  # noqa: BLE001 - any parser failure is a rejection
            raise ImageRejected("image cannot be decoded") from exc
        with im:
            # Check the declared size before decoding anything (decompression-bomb guard).
            w, h = im.size
            if w < 1 or h < 1 or w > MAX_SIDE or h > MAX_SIDE:
                raise ImageRejected(f"image must be at most {MAX_SIDE} px per side")
            if w * h > MAX_PIXELS:
                raise ImageRejected("image has more than 4 Mpx")
            frames = int(getattr(im, "n_frames", 1))
            if frames > MAX_FRAMES:
                raise ImageRejected(f"animation has more than {MAX_FRAMES} frames")
            try:
                for i in range(frames):
                    im.seek(i)
                    if im.size[0] * im.size[1] > MAX_PIXELS:
                        raise ImageRejected("image has more than 4 Mpx")
                    im.load()
            except ImageRejected:
                raise
            except Exception as exc:  # noqa: BLE001
                raise ImageRejected("image cannot be decoded") from exc
    return ImageInfo(mime, w, h, frames)


class AssetStore:
    def __init__(self, db: Database, assets_dir: Path, clock):
        self.db = db
        self.dir = assets_dir
        self.clock = clock
        self.dir.mkdir(parents=True, exist_ok=True)

    def put(self, data: bytes) -> str:
        """Validate and store; returns the sha256 (idempotent)."""
        info = check_image(data)
        sha = hashlib.sha256(data).hexdigest()
        path = self.dir / sha
        if not path.exists():
            tmp = self.dir / f".{sha}.tmp"
            tmp.write_bytes(data)
            os.replace(tmp, path)
        with self.db.tx() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO assets (sha256, mime, size, width, height, frames, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (sha, info.mime, len(data), info.width, info.height, info.frames, fmt(self.clock())),
            )
        return sha

    def exists(self, sha: str) -> bool:
        with self.db.read() as conn:
            return conn.execute("SELECT 1 FROM assets WHERE sha256 = ?", (sha,)).fetchone() is not None

    def get(self, sha: str) -> tuple[bytes, str]:
        with self.db.read() as conn:
            row = conn.execute("SELECT mime FROM assets WHERE sha256 = ?", (sha,)).fetchone()
        path = self.dir / sha
        if row is None or not path.is_file():
            raise NotFound("asset not found")
        return path.read_bytes(), row["mime"]
