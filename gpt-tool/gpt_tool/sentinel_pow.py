"""OpenAI sentinel proof-of-work token for auth.openai.com login APIs.

RECONSTRUCTED module (original source was lost). The shape follows the public
chatgpt/auth sentinel PoW algorithm: fetch chat-requirements, solve the hash
challenge, wrap the answer in a base64 payload with the "gAAAAA" prefix.
"""

from __future__ import annotations

import base64
import hashlib
import json
import time

SENTINEL_URL = "https://auth.openai.com/api/accounts/sentinel/chat-requirements"


def _solve_pow(seed: str, difficulty: str) -> str | None:
    """Find an answer whose sha3-512 hex starts with the difficulty prefix."""
    if not difficulty:
        return ""
    target = difficulty.lower()
    for i in range(500_000):
        candidate = json.dumps([seed, i])
        digest = hashlib.sha3_512(candidate.encode()).hexdigest()
        if digest[: len(target)] <= target:
            return candidate
    return None


def get_sentinel_token_pow(session, device_id: str, action: str, user_agent: str) -> str:
    """Fetch sentinel requirements for `action` and solve the PoW challenge.

    Returns the token string (or "" when the challenge cannot be solved —
    callers treat an empty token as an error).
    """
    del action  # kept for signature compatibility with login.py
    headers = {
        "user-agent": user_agent,
        "accept": "application/json",
        "oai-did": device_id,
    }
    try:
        resp = session.get(SENTINEL_URL, headers=headers)
        if resp.status_code != 200:
            return ""
        config = (resp.json() or {}).get("proofofwork") or {}
    except Exception:
        return ""

    if config.get("required") is False:
        # No PoW needed; still produce a minimal token payload.
        config = {}

    seed = str(config.get("seed") or "0.000000")
    difficulty = str(config.get("difficulty") or "")
    answer = _solve_pow(seed, difficulty)
    if answer is None:
        return ""

    payload = {
        "p": answer,
        "t": int(time.time() * 1000),
        "id": device_id,
        "c": [],
    }
    wrapped = base64.b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode()
    return "gAAAAAB" + wrapped
