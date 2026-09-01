"""HTTP session factory: curl_cffi with Chrome impersonation + header builders.

Reconstructed module — signatures follow the calls in login.py.
"""

from __future__ import annotations

# Chrome 149 desktop user agent (matches the original tool docstring).
LOGIN_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
)

_SEC_FETCH_NAV = {
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Sec-Fetch-User": "?1",
    "Upgrade-Insecure-Requests": "1",
}


def build_client(proxy: str | None = None):
    """curl_cffi session with Chrome TLS fingerprint and optional proxy."""
    from curl_cffi.requests import Session

    try:
        session = Session(impersonate="chrome", proxy=proxy or None)
    except Exception:
        # Older curl_cffi: no impersonate kwarg or unsupported target.
        session = Session(proxy=proxy or None)
    return session


def chrome_nav_headers(referer: str, site: str = "none") -> dict[str, str]:
    """Headers for top-level document navigation."""
    headers = {
        "accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "user-agent": LOGIN_UA,
        "referer": referer,
    }
    headers.update(_SEC_FETCH_NAV)
    mapping = {
        "none": "none",
        "same-origin": "same-origin",
        "cross-site": "cross-site",
    }
    headers["Sec-Fetch-Site"] = mapping.get(site, "none")
    return headers


def chrome_xhr_headers(
    referer: str,
    origin: str,
    accept: str = "*/*",
    same_origin: bool = True,
    content_type: str | None = None,
) -> dict[str, str]:
    """Headers for same-site XHR/fetch calls."""
    headers = {
        "accept": accept,
        "user-agent": LOGIN_UA,
        "referer": referer,
        "origin": origin,
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-origin" if same_origin else "cross-site",
    }
    if content_type:
        headers["content-type"] = content_type
    return headers


def auth_api_headers(referer: str, nav_id: str) -> dict[str, str]:
    """Headers for auth.openai.com JSON APIs (password/verify, mfa, ...)."""
    headers = {
        "accept": "application/json",
        "user-agent": LOGIN_UA,
        "referer": referer,
        "origin": "https://auth.openai.com",
        "content-type": "application/json",
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-origin",
    }
    if nav_id:
        headers["x-openai-document-navigation-id"] = nav_id
    return headers
