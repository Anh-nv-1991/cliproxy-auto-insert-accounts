"""Probe refresh_token health WITHOUT password login.

Muc dich: kiem tra token con song khong bang 1 request refresh (grant_type=refresh_token)
- Giong het nhịp refresh binh thuong cua moi client -> khong tao signal de bi scan.
- KHONG co password login, KHONG sentinel PoW, KHONG browser flow.

Usage:
  python -X utf8 probe_refresh.py --manifest manifest.txt --out out [--delay 5] [--proxy URL]

Manifest lines: <email>|<path-to-auth-json>
Verdict per account (in ra stdout):
  OK        -> refresh thanh cong; auth JSON cap nhat (token moi) da ghi vao out dir (giu nguyen ten file)
  INVALID   -> refresh_token bi thu hoi (HTTP 401 invalidated/invalid_grant) -> re-login moi fix duoc
  TRANSIENT -> loi tam thoi (5xx/429/network) -> cho roi probe lai
"""
from __future__ import annotations

import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from gpt_tool.oauth import OAuthError, refresh_codex_token
from gpt_tool.redaction import redact, short


def main() -> int:
    args = sys.argv[1:]
    manifest: Path | None = None
    out_dir = Path("out")
    delay = 5.0
    proxy: str | None = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--manifest":
            i += 1; manifest = Path(args[i])
        elif a == "--out":
            i += 1; out_dir = Path(args[i])
        elif a == "--delay":
            i += 1; delay = float(args[i])
        elif a == "--proxy":
            i += 1; proxy = args[i] or None
        i += 1

    if manifest is None or not manifest.is_file():
        print("ERR|missing --manifest", flush=True)
        return 2
    out_dir.mkdir(parents=True, exist_ok=True)

    rows: list[tuple[str, Path]] = []
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        parts = raw.split("|", 1)
        if len(parts) != 2:
            continue
        rows.append((parts[0].strip().lower(), Path(parts[1].strip())))

    ok = 0
    for idx, (email, path) in enumerate(rows):
        verdict = "TRANSIENT"
        detail = ""
        try:
            body = json.loads(path.read_text(encoding="utf-8"))
            rt = str(body.get("refresh_token") or "")
            if not rt:
                raise OAuthError("auth json khong co refresh_token")
            tok = refresh_codex_token(rt, proxy)
            # QUAN TRONG: OpenAI co the rotate refresh_token -> luon luu token moi nguoc lai
            body["access_token"] = tok.access_token
            body["refresh_token"] = tok.refresh_token or rt
            if tok.id_token:
                body["id_token"] = tok.id_token
            body["last_refresh"] = datetime.now(timezone.utc).isoformat()
            dest = out_dir / path.name
            tmp = dest.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(body, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            tmp.replace(dest)
            verdict = "OK"
            detail = str(dest)
            ok += 1
        except OAuthError as exc:
            msg = str(exc)
            low = msg.lower()
            if "invalid" in low or "401" in low:
                verdict = "INVALID"
            detail = redact(short(msg))
        except Exception as exc:
            verdict = "TRANSIENT"
            detail = redact(short(str(exc)))
        print(f"{verdict}|{email}|{detail}", flush=True)
        if idx < len(rows) - 1 and delay > 0:
            time.sleep(delay)

    print(f"DONE|ok={ok}/{len(rows)}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
