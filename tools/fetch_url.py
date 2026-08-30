"""Fetch a web page and return its readable text.

Closes the gap where the assistant can search the web but not read what it
finds: `search_web` returns {title, snippet, url}, so anything whose answer
lives *on* a page dead-ends at a link the user cannot click on a screenless
device. See pollen-robotics/reachy_mini_conversation_app#543.

Loaded by the app's external-tool mechanism -- no fork required:

    REACHY_MINI_EXTERNAL_TOOLS_DIRECTORY=./tools
    AUTOLOAD_EXTERNAL_TOOLS=true

Uses only httpx (already an app dependency) and the standard library, so it
adds no packages that could conflict with the app's own pins.
"""

import ipaddress
import logging
import socket
from html.parser import HTMLParser
from typing import Any
from urllib.parse import urlparse

import httpx

from reachy_mini_conversation_app.tools.core_tools import Tool, ToolDependencies

logger = logging.getLogger(__name__)

TIMEOUT_S = 15.0
MAX_BYTES = 2_000_000        # stop reading the body past this
MAX_CHARS_DEFAULT = 4_000    # returned text budget; turns already run 7-9k tokens
MAX_CHARS_LIMIT = 20_000
ALLOWED_CONTENT = ("text/html", "text/plain", "application/xhtml+xml", "application/json")

# Dropped wholesale: their content is never useful as speech and <script>/<style>
# bodies would otherwise dominate the extracted text.
# "head" is deliberately absent: <title> lives there and is worth keeping. Its
# other children carry no text. nav/header/footer/aside are page chrome that
# would otherwise consume most of the character budget before the article does.
_SKIP_TAGS = {"script", "style", "noscript", "template", "svg",
              "nav", "header", "footer", "aside", "form"}
_BREAK_TAGS = {"p", "br", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article"}


class _TextExtractor(HTMLParser):
    """Minimal readable-text extractor: no bs4/lxml dependency."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.title: str = ""
        self._skip_depth = 0
        self._in_title = False

    def handle_starttag(self, tag: str, attrs: Any) -> None:
        if tag in _SKIP_TAGS:
            self._skip_depth += 1
        elif tag == "title":
            self._in_title = True
        elif tag in _BREAK_TAGS:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in _SKIP_TAGS:
            self._skip_depth = max(0, self._skip_depth - 1)
        elif tag == "title":
            self._in_title = False
        elif tag in _BREAK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self._skip_depth:
            return
        if self._in_title:
            self.title += data.strip()
            return
        if data.strip():
            self.parts.append(data)

    def text(self) -> str:
        raw = "".join(self.parts)
        # Collapse whitespace but keep paragraph breaks, so speech has pauses.
        lines = [" ".join(ln.split()) for ln in raw.splitlines()]
        return "\n".join(ln for ln in lines if ln)


def _reject_reason(url: str) -> str | None:
    """Return why this URL must not be fetched, or None if it is allowed.

    The tool runs on the same host as the Reachy daemon (:8000, which can drive
    the robot), the LLM server and any other local service. A model can be
    steered into requesting a URL -- by a prompt-injecting page, or simply by
    confusion -- so loopback and private ranges are refused rather than trusted.
    """
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        return f"only http/https are allowed, got {parsed.scheme or 'no scheme'}"
    host = parsed.hostname
    if not host:
        return "no host in URL"

    try:
        # Resolve first: blocking on the literal string alone would miss
        # hostnames that point at private space.
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror as exc:
        return f"could not resolve {host}: {exc}"

    for info in infos:
        try:
            ip = ipaddress.ip_address(info[4][0])
        except ValueError:
            continue
        if ip.is_loopback or ip.is_private or ip.is_link_local or ip.is_reserved or ip.is_multicast:
            return f"{host} resolves to a non-public address ({ip}); refusing"
    return None


class FetchUrlTool(Tool):
    """Fetch a URL and return its readable text."""

    name = "fetch_url"
    description = (
        "Fetch a public web page and return its readable text. Use this after "
        "search_web to actually read a result instead of only reporting its link. "
        "Returns plain text with markup removed, truncated to a length suitable "
        "for speaking aloud."
    )
    parameters_schema = {
        "type": "object",
        "properties": {
            "url": {
                "type": "string",
                "description": "Absolute http(s) URL of the page to read.",
            },
            "max_chars": {
                "type": "integer",
                "description": (
                    f"Maximum characters of text to return "
                    f"(default {MAX_CHARS_DEFAULT}, max {MAX_CHARS_LIMIT})."
                ),
            },
        },
        "required": ["url"],
    }

    async def __call__(self, deps: ToolDependencies, **kwargs: Any) -> dict[str, Any]:
        """Fetch the page and return {status, url, title, text, truncated}."""
        url = (kwargs.get("url") or "").strip()
        if not url:
            return {"status": "error", "reason": "no url provided"}

        max_chars = kwargs.get("max_chars") or MAX_CHARS_DEFAULT
        try:
            max_chars = max(200, min(int(max_chars), MAX_CHARS_LIMIT))
        except (TypeError, ValueError):
            max_chars = MAX_CHARS_DEFAULT

        reason = _reject_reason(url)
        if reason:
            logger.warning("fetch_url refused %s: %s", url, reason)
            return {"status": "error", "url": url, "reason": reason}

        logger.info("fetch_url: %s (max_chars=%d)", url, max_chars)
        try:
            async with httpx.AsyncClient(
                timeout=TIMEOUT_S,
                follow_redirects=True,
                headers={"User-Agent": "reachy-mini-fetch-url/1.0"},
            ) as client:
                async with client.stream("GET", url) as resp:
                    if resp.status_code >= 400:
                        return {
                            "status": "error",
                            "url": str(resp.url),
                            "reason": f"HTTP {resp.status_code}",
                        }
                    # Redirects can land somewhere private; re-check the final URL.
                    reason = _reject_reason(str(resp.url))
                    if reason:
                        return {"status": "error", "url": str(resp.url),
                                "reason": f"after redirect, {reason}"}

                    ctype = resp.headers.get("content-type", "").split(";")[0].strip()
                    if ctype and not any(ctype.startswith(c) for c in ALLOWED_CONTENT):
                        return {"status": "error", "url": str(resp.url),
                                "reason": f"unsupported content type {ctype}"}

                    chunks: list[bytes] = []
                    total = 0
                    async for chunk in resp.aiter_bytes():
                        chunks.append(chunk)
                        total += len(chunk)
                        if total >= MAX_BYTES:
                            break
                    body = b"".join(chunks)
                    final_url = str(resp.url)
                    encoding = resp.encoding or "utf-8"
        except httpx.TimeoutException:
            return {"status": "error", "url": url, "reason": f"timed out after {TIMEOUT_S:.0f}s"}
        except httpx.HTTPError as exc:
            return {"status": "error", "url": url, "reason": f"{type(exc).__name__}: {exc}"}

        html = body.decode(encoding, errors="replace")
        if ctype == "text/plain" or ctype == "application/json":
            title, text = "", " ".join(html.split())
        else:
            parser = _TextExtractor()
            try:
                parser.feed(html)
            except Exception as exc:  # malformed markup should not kill the turn
                logger.warning("fetch_url parse issue on %s: %s", final_url, exc)
            title, text = parser.title, parser.text()

        truncated = len(text) > max_chars
        if truncated:
            text = text[:max_chars].rsplit(" ", 1)[0] + " ..."

        if not text:
            return {"status": "error", "url": final_url,
                    "reason": "no readable text found on the page"}

        logger.info("fetch_url: %s -> %d chars%s", final_url, len(text),
                    " (truncated)" if truncated else "")
        return {
            "status": "success",
            "url": final_url,
            "title": title,
            "text": text,
            "truncated": truncated,
        }
