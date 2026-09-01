"""Minimal JWT helpers (decode only — no signature verification needed here)."""

from __future__ import annotations

import base64
import json


def _b64url_decode(data: str) -> bytes:
    padding = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + padding)


def decode_jwt(token: str) -> dict:
    """Decode a JWT payload without verifying the signature."""
    parts = (token or "").split(".")
    if len(parts) != 3:
        raise ValueError("not a JWT (expected 3 segments)")
    payload = json.loads(_b64url_decode(parts[1]))
    if not isinstance(payload, dict):
        raise ValueError("jwt payload is not an object")
    return payload


def claim(token: str, key: str, default=None):
    """One claim from a JWT payload (or default)."""
    try:
        return decode_jwt(token).get(key, default)
    except Exception:
        return default
