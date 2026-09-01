"""Codex OAuth: password login -> authorize -> code -> token exchange -> refresh.

RECONSTRUCTED module (original source was lost). Public interface follows the
calls in login.py / export.py. OAuth parameters mirror CLIProxyAPI's own Codex
auth (internal/auth/codex/openai_auth.go) so exported tokens stay compatible.
"""

from __future__ import annotations

import base64
import hashlib
import secrets
import uuid
from dataclasses import dataclass
from urllib.parse import parse_qs, urlencode, urlparse

from gpt_tool.jwtutil import claim, decode_jwt

AUTH = "https://auth.openai.com"
TOKEN_URL = f"{AUTH}/oauth/token"
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
REDIRECT_URI = "http://localhost:1455/auth/callback"
AUTHORIZE_SCOPE = "openid email profile offline_access"
REFRESH_SCOPE = "openid profile email"


class OAuthError(Exception):
    pass


class AddPhoneRequired(Exception):
    """OpenAI asked for phone binding during Codex OAuth (cannot auto-fix)."""


@dataclass
class CodexTokens:
    id_token: str
    access_token: str
    refresh_token: str


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def _pkce() -> tuple[str, str]:
    verifier = _b64url(secrets.token_bytes(32))
    challenge = _b64url(hashlib.sha256(verifier.encode()).digest())
    return verifier, challenge


def _authorize_url(state: str, challenge: str) -> str:
    params = {
        "client_id": CLIENT_ID,
        "response_type": "code",
        "redirect_uri": REDIRECT_URI,
        "scope": AUTHORIZE_SCOPE,
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "prompt": "login",
    }
    return f"{AUTH}/oauth/authorize?{urlencode(params)}"


def _codex_authorize_get_code(session, device_id: str) -> tuple[str, str]:
    """Run the Codex authorize on an authenticated session; capture the code
    from the localhost redirect Location (never actually followed)."""
    from gpt_tool.http_client import chrome_nav_headers

    state = str(uuid.uuid4())
    verifier, challenge = _pkce()
    url = _authorize_url(state, challenge)
    headers = chrome_nav_headers("https://chatgpt.com/", "cross-site")
    headers["oai-did"] = device_id

    current = url
    for _ in range(12):
        resp = session.get(current, headers=headers, allow_redirects=False)
        loc = resp.headers.get("location") or ""
        if resp.status_code in {301, 302, 303, 307, 308} and loc:
            if loc.startswith(REDIRECT_URI):
                q = parse_qs(urlparse(loc).query)
                code = (q.get("code") or [""])[0]
                if not code:
                    raise OAuthError("authorize redirect missing code")
                if (q.get("state") or [""])[0] != state:
                    raise OAuthError("authorize state mismatch")
                return code, verifier
            if loc.startswith("/"):
                from urllib.parse import urljoin

                current = urljoin(current, loc)
            else:
                current = loc
            continue
        body = (resp.text or "").lower()
        if resp.status_code in {400, 403} and ("phone" in body or "add-phone" in body or "verify" in body and "num" in body):
            raise AddPhoneRequired("phone binding required by OpenAI")
        if "add-phone" in body or ("phone" in body and "verif" in body):
            raise AddPhoneRequired("phone binding required by OpenAI")
        raise OAuthError(f"authorize HTTP {resp.status_code}: {resp.text[:160]}")
    raise OAuthError("authorize redirect loop exceeded")


def _token_request(data: dict, proxy: str | None = None) -> CodexTokens:
    from gpt_tool.http_client import build_client

    try:
        client = build_client(proxy)
        resp = client.post(TOKEN_URL, data=data, headers={"content-type": "application/x-www-form-urlencoded"})
    finally:
        try:
            client.close()
        except Exception:
            pass
    if resp.status_code != 200:
        raise OAuthError(f"token HTTP {resp.status_code}: {resp.text[:200]}")
    payload = resp.json() or {}
    access = str(payload.get("access_token") or "")
    if not access:
        raise OAuthError(f"token response missing access_token: {payload}")
    return CodexTokens(
        id_token=str(payload.get("id_token") or ""),
        access_token=access,
        refresh_token=str(payload.get("refresh_token") or ""),
    )


def _token_exchange(code: str, verifier: str, proxy: str | None = None) -> CodexTokens:
    return _token_request(
        {
            "grant_type": "authorization_code",
            "code": code,
            "client_id": CLIENT_ID,
            "redirect_uri": REDIRECT_URI,
            "code_verifier": verifier,
        },
        proxy,
    )


def oauth_codex_with_password(session, creds, device_id: str) -> CodexTokens:
    """Full flow on a FRESH session: ChatGPT password login -> Codex OAuth."""
    from gpt_tool.login import (
        _consume_callback,
        _csrf,
        _follow_html,
        _prime,
        _session_token_from_jar,
        _signin,
        open_authorize,
        submit_auth_password_mfa,
    )

    _prime(session)
    csrf = _csrf(session)
    url = _signin(session, csrf, device_id, creds.email)
    landing = open_authorize(session, url)
    if "phone" in landing.lower() and "verif" in landing.lower():
        raise AddPhoneRequired("phone binding required by OpenAI")

    res = submit_auth_password_mfa(session, creds, device_id)
    continue_url = res["continue_url"]

    final, _body = _follow_html(session, continue_url)
    if not _session_token_from_jar(session):
        _consume_callback(session, final)

    code, verifier = _codex_authorize_get_code(session, device_id)
    return _token_exchange(code, verifier)


def oauth_codex_rt_exchange(session, device_id: str, creds) -> CodexTokens:
    """Second authorize pass (session already logged in) to obtain a refresh token."""
    from gpt_tool.login import _session_token_from_jar

    if not _session_token_from_jar(session):
        raise OAuthError("rt exchange requires an authenticated session")
    code, verifier = _codex_authorize_get_code(session, device_id)
    return _token_exchange(code, verifier)


def refresh_codex_token(refresh_token: str, proxy: str | None = None) -> CodexTokens:
    """Standard refresh_token grant."""
    if not refresh_token:
        raise OAuthError("refresh token is empty")
    return _token_request(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": CLIENT_ID,
            "scope": REFRESH_SCOPE,
        },
        proxy,
    )


def account_id_from_access(access_token: str) -> str:
    """chatgpt_account_id claim embedded in the access token."""
    auth = claim(access_token, "https://api.openai.com/auth", {}) or {}
    account_id = auth.get("chatgpt_account_id") or ""
    if not account_id:
        try:
            payload = decode_jwt(access_token)
            auth = payload.get("https://api.openai.com/auth") or {}
            account_id = auth.get("chatgpt_account_id") or ""
        except Exception:
            account_id = ""
    return str(account_id or "")
