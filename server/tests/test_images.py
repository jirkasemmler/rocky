"""Image checks (SERVER-SPEC §10) and asset serving."""

from __future__ import annotations

import hashlib
import io

import pytest
from PIL import Image

from app.images import ImageRejected, check_image

from .conftest import png_bytes


def encode(im: Image.Image, fmt: str, **kw) -> bytes:
    buf = io.BytesIO()
    im.save(buf, fmt, **kw)
    return buf.getvalue()


@pytest.mark.parametrize("fmt, mime", [("PNG", "image/png"), ("JPEG", "image/jpeg"), ("WEBP", "image/webp"),
                                       ("GIF", "image/gif")])
def test_accepts_supported_formats(fmt, mime):
    info = check_image(encode(Image.new("RGB", (64, 32), (1, 2, 3)), fmt))
    assert (info.mime, info.width, info.height, info.frames) == (mime, 64, 32, 1)


def test_rejects_svg_and_unknown():
    svg = b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'
    for data in (svg, b"<?xml version='1.0'?>" + svg, b"BM" + b"\0" * 100, b"hello"):
        with pytest.raises(ImageRejected, match="SVG is not allowed"):
            check_image(data)
    with pytest.raises(ImageRejected):
        check_image(b"")


def test_rejects_oversize_file():
    data = png_bytes() + b"\0" * (2 * 1024 * 1024)
    with pytest.raises(ImageRejected, match="larger than 2 MB"):
        check_image(data)


def test_rejects_too_many_pixels_per_side_and_total():
    with pytest.raises(ImageRejected, match="2048 px"):
        check_image(encode(Image.new("1", (2049, 10)), "PNG"))
    with pytest.raises(ImageRejected, match="4 Mpx"):
        check_image(encode(Image.new("1", (2048, 2000)), "PNG"))  # 4.1 Mpx, small file


def test_decompression_bomb_header_is_rejected_before_decoding():
    """A tiny PNG whose header claims 30000x30000 px (900 Mpx)."""
    import struct
    import zlib

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", 30000, 30000, 1, 0, 0, 0, 0)
    bomb = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"\0" * 1000)) + chunk(b"IEND", b"")
    assert len(bomb) < 1000
    with pytest.raises(ImageRejected):
        check_image(bomb)


def gif(frames: int) -> bytes:
    images = [Image.new("RGB", (8, 8), (i * 2 % 256, 255 - i * 2 % 256, i % 7 * 30)) for i in range(frames)]
    return encode(images[0], "GIF", save_all=True, append_images=images[1:], duration=50, loop=0, disposal=2)


def test_animated_gif_frame_limit():
    assert check_image(gif(120)).frames == 120
    with pytest.raises(ImageRejected, match="120 frames"):
        check_image(gif(121))


def test_truncated_image_rejected():
    data = encode(Image.new("RGB", (200, 200), (9, 9, 9)), "JPEG")
    with pytest.raises(ImageRejected):
        check_image(data[: len(data) // 3])


def test_wrong_magic_for_content():
    with pytest.raises(ImageRejected):
        check_image(b"\x89PNG\r\n\x1a\n" + b"garbage" * 10)


def test_asset_storage_and_serving(client, ctx, device, admin):
    data = png_bytes(16, 16)
    r = admin.api("POST", "/admin/api/assets", files={"file": ("x.png", data, "image/svg+xml")})
    assert r.status_code == 201
    sha = r.json()["sha256"]
    assert sha == hashlib.sha256(data).hexdigest()
    assert (ctx.settings.assets_dir / sha).read_bytes() == data  # stored unchanged, content-addressed
    r = client.get(f"/api/v1/assets/{sha}", headers=device)
    assert r.status_code == 200 and r.content == data
    assert r.headers["content-type"] == "image/png"  # sniffed, not the uploaded content type
    assert r.headers["cache-control"] == "private, max-age=31536000, immutable"
    assert r.headers["x-content-type-options"] == "nosniff"
    assert r.headers["content-security-policy"] == "default-src 'none'"
    assert client.get("/api/v1/assets/" + "f" * 64, headers=device).status_code == 404
    assert client.get("/api/v1/assets/..%2Frocky.db", headers=device).status_code == 404
    # uploading the same bytes again is idempotent
    assert admin.api("POST", "/admin/api/assets", files={"file": ("y.png", data, "image/png")}).json()["sha256"] == sha
    r = admin.api("POST", "/admin/api/assets", files={"file": ("x.svg", b"<svg/>", "image/svg+xml")})
    assert r.status_code == 422 and r.headers["content-type"] == "application/problem+json"
