"""Output formats registry + canonical auth mapping.

RECONSTRUCTED module (original source was lost). The `cpa` format reproduces the
CLIProxyAPI Codex auth file exactly (type=codex, chatgpt_* claims from id_token).
Other formats are best-effort passthrough of the canonical payload.
"""

from __future__ import annotations

import json
import re
import time
from datetime import datetime, timedelta, timezone

from gpt_tool.jwtutil import claim, decode_jwt

# Formats offered by `cli.py --format` (README: cpa sub2api cockpit 9router codex axonhub codexmanager).
FORMATS: dict[str, object] = {
    "cpa": "cpa",
    "sub2api": "passthrough",
    "cockpit": "passthrough",
    "9router": "passthrough",
    "codex": "codex",
    "axonhub": "passthrough",
    "codexmanager": "passthrough",
}


def sanitize_file_token(value: str, fallback: str = "file") -> str:
    """Keep a value safe for filenames (plus-addressing keeps `+`); fall back when nothing survives."""
    cleaned = re.sub(r"[^A-Za-z0-9._+-]+", "_", (value or "").strip())
    return cleaned or fallback


def _plan_from_id_token(id_token: str) -> tuple[str, str, str]:
    """(plan_type, chatgpt_account_id, email) from id_token claims."""
    try:
        payload = decode_jwt(id_token)
    except Exception:
        return "free", "", ""
    auth = payload.get("https://api.openai.com/auth") or {}
    plan = str(auth.get("chatgpt_plan_type") or "free")
    account_id = str(auth.get("chatgpt_account_id") or "")
    email = str(payload.get("email") or "")
    return plan, account_id, email


def _expired_from_access(access_token: str) -> str:
    exp = claim(access_token, "exp", 0) or 0
    if not exp:
        return (datetime.now(timezone.utc) + timedelta(days=10)).strftime("%Y-%m-%dT%H:%M:%S%z")
    return datetime.fromtimestamp(int(exp), timezone.utc).strftime("%Y-%m-%dT%H:%M:%S%z")


def canonical_from_oauth(
    email: str,
    access_token: str,
    refresh_token: str,
    id_token: str,
    account_id: str,
    session_token: str = "",
) -> dict:
    """Normalized in-memory representation shared by all formats."""
    plan, chatgpt_account_id, token_email = _plan_from_id_token(id_token)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S%z")
    return {
        "email": email or token_email,
        "access_token": access_token,
        "refresh_token": refresh_token,
        "id_token": id_token,
        "account_id": account_id or chatgpt_account_id,
        "chatgpt_account_id": chatgpt_account_id or account_id,
        "plan_type": plan,
        "session_token": session_token,
        "last_refresh": now,
        "expired": _expired_from_access(access_token),
    }


def _to_cpa(canonical: dict) -> dict:
    """CLIProxyAPI Codex auth file (matches auths/*.json byte-for-byte shape)."""
    email = canonical.get("email") or ""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+07:00")
    return {
        "access_token": canonical.get("access_token") or "",
        "account_id": canonical.get("chatgpt_account_id") or "",
        "chatgpt_account_id": canonical.get("chatgpt_account_id") or "",
        "chatgpt_plan_type": canonical.get("plan_type") or "free",
        "disabled": False,
        "email": email,
        "expired": canonical.get("expired") or "",
        "id_token": canonical.get("id_token") or "",
        "last_refresh": now,
        "name": email,
        "plan_type": canonical.get("plan_type") or "free",
        "refresh_token": canonical.get("refresh_token") or "",
        "type": "codex",
    }


def _to_codex(canonical: dict) -> dict:
    """Codex CLI auth.json shape."""
    return {"OPENAI_API_KEY": canonical.get("access_token") or ""}


def convert_canonical(canonical: dict, fmt: str) -> object:
    kind = FORMATS.get(fmt.lower().strip())
    if kind is None:
        raise ValueError(f"unknown format: {fmt}")
    if kind == "cpa":
        return _to_cpa(canonical)
    if kind == "codex":
        return _to_codex(canonical)
    # passthrough formats: canonical payload as-is (schemas not reproduced)
    return {k: v for k, v in canonical.items() if k != "session_token"}


def _canonical_from_json(doc: dict) -> dict:
    """Map a foreign session/OAuth JSON doc into canonical fields."""
    access = doc.get("access_token") or doc.get("accessToken") or ""
    refresh = doc.get("refresh_token") or doc.get("refreshToken") or ""
    id_token = doc.get("id_token") or doc.get("idToken") or ""
    email = doc.get("email") or ""
    if not email and id_token:
        email = str(claim(id_token, "email") or "")
    session_token = doc.get("session_token") or doc.get("sessionToken") or ""
    return canonical_from_oauth(
        email=email,
        access_token=access,
        refresh_token=refresh,
        id_token=id_token,
        account_id=str(claim(access, "https://api.openai.com/auth", {}).get("chatgpt_account_id", "") or "") if access else "",
        session_token=session_token,
    )


def convert_text(text: str, fmt: str) -> list[tuple[str, object]]:
    """Convert a document (or whitespace-separated JSON docs) to a format."""
    decoder = json.JSONDecoder()
    pairs: list[tuple[str, object]] = []
    idx = 0
    raw = (text or "").strip()
    while idx < len(raw):
        while idx < len(raw) and raw[idx] in " \t\r\n":
            idx += 1
        if idx >= len(raw):
            break
        try:
            doc, end = decoder.raw_decode(raw, idx)
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid JSON at offset {idx}: {exc}") from exc
        idx = end
        if not isinstance(doc, dict):
            continue
        canonical = _canonical_from_json(doc)
        body = convert_canonical(canonical, fmt)
        pairs.append((canonical.get("email") or "", body))
    return pairs
