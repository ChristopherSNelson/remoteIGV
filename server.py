#!/usr/bin/env python3
"""
remoteIGV — lightweight web app that serves IGV.js with BAM/CRAM files
from a Linux server. No local downloads needed.

Usage:
    python server.py --data-dir /path/to/bams --port 8080

Then open http://yourserver:8080 in a browser.
"""

import argparse
import os
import re
import mimetypes
from pathlib import Path

from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import (
    HTMLResponse,
    FileResponse,
    StreamingResponse,
    JSONResponse,
)
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
import uvicorn

app = FastAPI(title="remoteIGV")

# configured at startup
DATA_DIR: Path = Path(".")
ALLOWED_EXTENSIONS = {
    ".bam", ".bai", ".cram", ".crai", ".csi",
    ".bed", ".bed.gz", ".bed.gz.tbi",
    ".vcf", ".vcf.gz", ".vcf.gz.tbi",
    ".bw", ".bigwig", ".bigWig", ".bedgraph",
    ".gff", ".gff3", ".gff.gz", ".gtf", ".gtf.gz",
    ".tbi", ".idx",
}

templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))


# ── helpers ──────────────────────────────────────────────────────────

def _safe_path(rel: str) -> Path:
    """Resolve a relative path under DATA_DIR, preventing traversal."""
    clean = Path(rel).as_posix().lstrip("/")
    resolved = (DATA_DIR / clean).resolve()
    if not str(resolved).startswith(str(DATA_DIR.resolve())):
        raise HTTPException(status_code=403, detail="Path traversal blocked")
    if not resolved.is_file():
        raise HTTPException(status_code=404, detail="File not found")
    return resolved


def _has_allowed_ext(name: str) -> bool:
    lower = name.lower()
    return any(lower.endswith(ext) for ext in ALLOWED_EXTENSIONS)


def _parse_range(range_header: str, file_size: int):
    """Parse an HTTP Range header → (start, end) inclusive."""
    m = re.match(r"bytes=(\d+)-(\d*)", range_header)
    if not m:
        raise HTTPException(status_code=416, detail="Bad range")
    start = int(m.group(1))
    end = int(m.group(2)) if m.group(2) else file_size - 1
    end = min(end, file_size - 1)
    if start > end or start >= file_size:
        raise HTTPException(status_code=416, detail="Range not satisfiable")
    return start, end


# ── routes ───────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse(request, "index.html")


@app.get("/api/files")
async def list_files():
    """Return a tree of servable alignment / track files."""
    INDEX_FOR = {".bam": ".bai", ".cram": ".crai"}
    files = []
    for p in sorted(DATA_DIR.rglob("*")):
        if not p.is_file() or not _has_allowed_ext(p.name):
            continue
        # Skip BAM/CRAM files that have no index - IGV can't use them
        suffix = p.suffix.lower()
        if suffix in INDEX_FOR:
            idx_ext = INDEX_FOR[suffix]
            if not p.with_suffix(p.suffix + idx_ext).exists() \
               and not p.parent.joinpath(p.stem + idx_ext).exists():
                continue
        rel = str(p.relative_to(DATA_DIR))
        files.append({"path": rel, "name": p.name, "size": p.stat().st_size})
    return JSONResponse(files)


@app.get("/data/{file_path:path}")
async def serve_data(file_path: str, request: Request):
    """
    Serve BAM/CRAM/BED/etc with HTTP Range support.
    IGV.js (and htslib) need byte-range requests to seek into indexed files.
    """
    resolved = _safe_path(file_path)

    # content type
    ct, _ = mimetypes.guess_type(str(resolved))
    if ct is None:
        ct = "application/octet-stream"

    file_size = resolved.stat().st_size
    range_header = request.headers.get("range")

    if not range_header:
        return FileResponse(
            str(resolved),
            media_type=ct,
            headers={
                "Accept-Ranges": "bytes",
                "Content-Length": str(file_size),
                "Access-Control-Allow-Origin": "*",
            },
        )

    start, end = _parse_range(range_header, file_size)
    length = end - start + 1

    def _stream():
        with open(resolved, "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(65536, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
                yield chunk

    return StreamingResponse(
        _stream(),
        status_code=206,
        media_type=ct,
        headers={
            "Content-Range": f"bytes {start}-{end}/{file_size}",
            "Content-Length": str(length),
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*",
        },
    )


@app.options("/data/{file_path:path}")
async def cors_preflight(file_path: str):
    """Handle CORS preflight for range requests."""
    return JSONResponse(
        content={},
        headers={
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, OPTIONS",
            "Access-Control-Allow-Headers": "Range",
            "Access-Control-Expose-Headers": "Content-Range, Content-Length",
        },
    )


# ── static files ─────────────────────────────────────────────────────

static_dir = Path(__file__).parent / "static"
static_dir.mkdir(exist_ok=True)
app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")


# ── main ─────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="remoteIGV server")
    parser.add_argument(
        "--data-dir", "-d",
        default=".",
        help="Root directory containing BAM/CRAM/BED files",
    )
    parser.add_argument("--host", default="0.0.0.0", help="Bind address")
    parser.add_argument("--port", "-p", type=int, default=8080)
    args = parser.parse_args()

    global DATA_DIR
    DATA_DIR = Path(args.data_dir).resolve()
    if not DATA_DIR.is_dir():
        raise SystemExit(f"Data directory not found: {DATA_DIR}")

    print(f"remoteIGV serving files from: {DATA_DIR}")
    print(f"Open http://localhost:{args.port} in your browser")
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
