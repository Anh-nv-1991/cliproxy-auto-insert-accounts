"""Redact credentials from error/log text before it leaves the process."""

from __future__ import annotations

import re

_MARK = "***"

# Patterns that look like secrets inside error messages (values we handle).
_SECRET_PATTERNS = [
    re.compile(r"(password=)[^\s&|]+", re.I),
    re.compile(r"(password['\"]?\s*[:=]\s*)[^\s,;}]+", re.I),
    re.compile(r"(code_verifier=)[^\s&]+", re.I),
    re.compile(r"(refresh_token['\"]?\s*[:=]\s*)[\"']?[A-Za-z0-9._\-]{8,}", re.I),
    re.compile(r"(access_token['\"]?\s*[:=]\s*)[\"']?[A-Za-z0-9._\-]{8,}", re.I),
    re.compile(r"(session_token['\"]?\s*[:=]\s*)[\"']?[A-Za-z0-9._\-]{8,}", re.I),
]


def redact(text: str) -> str:
    """Replace secret-looking values with *** in a message."""
    if not text:
        return text
    for pat in _SECRET_PATTERNS:
        text = pat.sub(lambda m: m.group(1) + _MARK, text)
    return text


def short(text: str, limit: int = 160) -> str:
    """Truncate a body for error messages (after redaction)."""
    cleaned = redact(text or "")
    if len(cleaned) <= limit:
        return cleaned
    return cleaned[: limit - 3] + "..."
