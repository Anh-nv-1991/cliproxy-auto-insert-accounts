"""TOTP helpers (pyotp wrapper) shared by parser and login."""

from __future__ import annotations

import base64
import re

import pyotp

_B32_RE = re.compile(r"[A-Z2-7]+")


def normalize_secret(secret: str) -> str:
    """Normalize a base32 TOTP secret: uppercase, strip spaces/dashes, validate."""
    cleaned = re.sub(r"[\s-]+", "", (secret or "").strip()).upper()
    if not cleaned:
        raise ValueError("totp secret is empty")
    if not _B32_RE.fullmatch(cleaned):
        raise ValueError("totp secret is not valid base32")
    try:
        base64.b32decode(cleaned + "=" * ((8 - len(cleaned) % 8) % 8))
    except Exception as exc:  # noqa: BLE001
        raise ValueError(f"totp secret invalid: {exc}") from exc
    return cleaned


def generate_code(secret: str) -> str:
    """Current TOTP code for a (normalized) base32 secret."""
    return pyotp.TOTP(secret).now()
