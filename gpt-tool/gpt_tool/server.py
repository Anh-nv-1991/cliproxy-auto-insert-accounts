"""Localhost GUI server (127.0.0.1 only)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import uuid
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

from gpt_tool.convert import FORMATS
from gpt_tool.export import convert_bulk, export_bulk, outcome_dict

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
OUT = ROOT / "out"
HOST = "127.0.0.1"
PORT = int(os.environ.get("GPT_TOOL_PORT", "8765"))

_jobs: dict[str, dict] = {}
_lock = threading.Lock()


def _json(handler: BaseHTTPRequestHandler, status: int, payload: object) -> None:
    raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(raw)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(raw)


def _read_json(handler: BaseHTTPRequestHandler) -> dict:
    n = int(handler.headers.get("Content-Length") or 0)
    raw = handler.rfile.read(n) if n else b"{}"
    return json.loads(raw.decode("utf-8") or "{}")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("gui: " + (fmt % args) + "\n")

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/api/health":
            _json(self, 200, {"ok": True, "formats": list(FORMATS)})
            return
        if path.startswith("/api/jobs/"):
            job_id = path.rsplit("/", 1)[-1]
            with _lock:
                job = _jobs.get(job_id)
            if not job:
                _json(self, 404, {"error": "job not found"})
                return
            _json(self, 200, job)
            return
        rel = "index.html" if path in {"/", "/index.html"} else path.lstrip("/")
        target = (WEB / rel).resolve()
        if not str(target).startswith(str(WEB.resolve())) or not target.is_file():
            self.send_error(404)
            return
        data = target.read_bytes()
        ctype = "text/html; charset=utf-8"
        if target.suffix == ".js":
            ctype = "application/javascript; charset=utf-8"
        elif target.suffix == ".css":
            ctype = "text/css; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        try:
            body = _read_json(self)
        except json.JSONDecodeError:
            _json(self, 400, {"error": "invalid JSON"})
            return
        if path == "/api/open-out":
            OUT.mkdir(parents=True, exist_ok=True)
            _open_folder(OUT)
            _json(self, 200, {"ok": True, "path": str(OUT)})
            return
        if path == "/api/convert":
            fmt = (body.get("format") or "").strip()
            text = body.get("text") or ""
            if fmt not in FORMATS:
                _json(self, 400, {"error": "chọn format trước khi chạy"})
                return
            try:
                results = [outcome_dict(o) for o in convert_bulk(text, fmt, OUT)]
            except Exception as exc:
                _json(self, 400, {"error": str(exc)})
                return
            _json(self, 200, {"ok": True, "results": results})
            return
        if path == "/api/export":
            fmt = (body.get("format") or "").strip()
            if fmt not in FORMATS:
                _json(self, 400, {"error": "chọn format trước khi chạy"})
                return
            lines = (body.get("lines") or "").splitlines()
            proxy = (body.get("proxy") or "").strip() or None
            workers = max(1, min(8, int(body.get("workers") or 2)))
            job_id = uuid.uuid4().hex[:12]
            jobs = [ln for ln in lines if ln.strip() and not ln.strip().startswith("#")]
            with _lock:
                _jobs[job_id] = {
                    "id": job_id,
                    "done": False,
                    "results": [],
                    "running": {},
                    "total": len(jobs),
                    "workers": workers,
                    "error": None,
                }

            def run() -> None:
                def on_step(email: str, step: str, index=None) -> None:
                    with _lock:
                        key = str(index) if index is not None else email
                        _jobs[job_id]["running"][key] = {"email": email, "step": step, "index": index}

                def on_progress(outcome) -> None:
                    with _lock:
                        running = _jobs[job_id]["running"]
                        if outcome.index is not None:
                            running.pop(str(outcome.index), None)
                        running.pop(outcome.email, None)
                        _jobs[job_id]["results"].append(outcome_dict(outcome))

                try:
                    export_bulk(lines, fmt, OUT, proxy, workers, on_progress, on_step)
                except Exception as exc:
                    with _lock:
                        _jobs[job_id]["error"] = str(exc)
                finally:
                    with _lock:
                        _jobs[job_id]["done"] = True
                        _jobs[job_id]["running"] = {}

            threading.Thread(target=run, daemon=True).start()
            _json(self, 200, {"id": job_id})
            return
        self.send_error(404)


def _open_folder(path: Path) -> None:
    if sys.platform == "darwin":
        subprocess.run(["open", str(path)], check=False)
    elif sys.platform == "win32":
        os.startfile(path)  # type: ignore[attr-defined]
    else:
        subprocess.run(["xdg-open", str(path)], check=False)


def _bind(host: str, start_port: int, attempts: int = 20) -> tuple[ThreadingHTTPServer, int]:
    last: OSError | None = None
    for port in range(start_port, start_port + max(1, attempts)):
        try:
            return ThreadingHTTPServer((host, port), Handler), port
        except OSError as exc:
            last = exc
            if getattr(exc, "errno", None) not in {48, 98, 10048}:
                raise
    raise OSError(f"hết cổng trống từ {start_port}–{start_port + attempts - 1}") from last


def main() -> None:
    from gpt_tool.ensure_deps import ensure_deps

    ensure_deps()
    WEB.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    httpd, port = _bind(HOST, PORT)
    url = f"http://{HOST}:{port}/"
    if port != PORT:
        print(f"Cổng {PORT} bận → dùng {port}.", flush=True)
    print(f"GPT-Tool GUI → {url}", flush=True)
    threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
