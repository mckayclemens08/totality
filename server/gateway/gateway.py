"""The only way in to search. It checks a Totality sign-in, applies a limit per account, and passes the
search to SearXNG, which is never public. It keeps no record of what was searched: the only thing held
is a count per account, in memory, and nothing it logs contains a search."""
import hashlib
import hmac
import json
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 4_096
MAX_QUERY = 400
MAX_RESULTS = 40
MAX_IMAGE = 3_000_000
MAX_PAGE = 10
PER_MINUTE = 30
PER_DAY = 1_000
# A sign-out takes effect within this, so a token isn't checked with Supabase for every search.
SIGN_IN_SECONDS = 60
CATEGORIES = {"web": "general", "images": "images", "news": "news", "videos": "videos"}
TOKEN = re.compile(r"^[A-Za-z0-9._-]{1,4096}$")
JSON_HEADERS = {"Content-Type": "application/json", "Cache-Control": "no-store"}


def signature(secret, url):
    """What SearXNG's image proxy expects, so a thumbnail can only be one this gateway handed out."""
    return hmac.new(secret.encode(), url.encode(), hashlib.sha256).hexdigest()


def thumbnail(secret, url):
    if not isinstance(url, str) or not url.startswith(("http://", "https://")):
        return None
    return {"url": url, "signature": signature(secret, url)}


def trimmed(secret, answer):
    """Only what the app draws, and only links a browser should follow."""
    results = []
    for result in answer.get("results", []):
        url = result.get("url")
        if not isinstance(url, str) or not url.startswith(("http://", "https://")):
            continue
        host = urllib.parse.urlsplit(url).hostname
        if not host:
            continue
        results.append({
            "title": str(result.get("title") or host)[:300],
            "url": url,
            "site": host.removeprefix("www."),
            "snippet": str(result.get("content") or "")[:500],
            "thumbnail": thumbnail(secret, result.get("thumbnail") or result.get("img_src")),
        })
        if len(results) == MAX_RESULTS:
            break
    return {"results": results, "partial": bool(answer.get("unresponsive_engines"))}


class Limiter:
    """Counts per account, in memory. A restart forgets them, which is harmless."""

    def __init__(self, clock):
        self.clock = clock
        self.lock = threading.Lock()
        self.minutes = {}
        self.days = {}

    def allow(self, account):
        now = self.clock()
        minute, day = int(now // 60), int(now // 86_400)
        with self.lock:
            self.minutes = {key: value for key, value in self.minutes.items() if key[1] == minute}
            self.days = {key: value for key, value in self.days.items() if key[1] == day}
            if self.minutes.get((account, minute), 0) >= PER_MINUTE or self.days.get((account, day), 0) >= PER_DAY:
                return False
            self.minutes[(account, minute)] = self.minutes.get((account, minute), 0) + 1
            self.days[(account, day)] = self.days.get((account, day), 0) + 1
            return True


class Gateway:
    """No sockets in here, so every rule can be tested. `check_sign_in` returns an account ID or None,
    and raises if Supabase can't be reached. `search` and `fetch_image` talk to SearXNG."""

    def __init__(self, check_sign_in, search, fetch_image, secret, clock=time.time):
        self.check_sign_in = check_sign_in
        self.search = search
        self.fetch_image = fetch_image
        self.secret = secret
        self.clock = clock
        self.limiter = Limiter(clock)
        self.lock = threading.Lock()
        self.signed_in = {}

    def account(self, authorization):
        if not authorization or not authorization.startswith("Bearer "):
            return None
        token = authorization.removeprefix("Bearer ")
        if not TOKEN.match(token):
            return None
        # Hashed, so no usable token sits in memory longer than the request.
        key = hashlib.sha256(token.encode()).hexdigest()
        now = self.clock()
        with self.lock:
            known = self.signed_in.get(key)
        if known and known[1] > now:
            return known[0]
        account = self.check_sign_in(token)
        if account:
            with self.lock:
                if len(self.signed_in) > 2_000:
                    self.signed_in.clear()
                self.signed_in[key] = (account, now + SIGN_IN_SECONDS)
        return account

    def handle(self, method, path, authorization, body):
        """Returns status, headers, and body."""
        if method == "GET" and path == "/web/health":
            return 200, JSON_HEADERS, b"{}"
        if path not in ("/web/search", "/web/image"):
            return 404, JSON_HEADERS, b"{}"
        if method != "POST":
            return 405, JSON_HEADERS, b"{}"
        if len(body) > MAX_BODY:
            return 413, JSON_HEADERS, b"{}"
        try:
            account = self.account(authorization)
            if not account:
                return 401, JSON_HEADERS, b"{}"
            try:
                request = json.loads(body)
            except ValueError:
                return 400, JSON_HEADERS, b"{}"
            if not isinstance(request, dict):
                return 400, JSON_HEADERS, b"{}"
            if path == "/web/image":
                return self.image(request)
            return self.searched(account, request)
        except (OSError, ValueError):
            return 502, JSON_HEADERS, b"{}"

    def searched(self, account, request):
        query = request.get("query")
        category = request.get("category", "web")
        page = request.get("page", 1)
        safety = request.get("safety", 1)
        valid = (
            isinstance(query, str) and 0 < len(query.strip()) <= MAX_QUERY
            and category in CATEGORIES
            and type(page) is int and 1 <= page <= MAX_PAGE
            and type(safety) is int and 0 <= safety <= 2
        )
        if not valid:
            return 400, JSON_HEADERS, b"{}"
        if not self.limiter.allow(account):
            return 429, JSON_HEADERS, b"{}"
        answer = self.search(query.strip(), CATEGORIES[category], page, safety)
        return 200, JSON_HEADERS, json.dumps(trimmed(self.secret, answer)).encode()

    def image(self, request):
        url, given = request.get("url"), request.get("signature")
        if not isinstance(url, str) or not isinstance(given, str):
            return 400, JSON_HEADERS, b"{}"
        if not hmac.compare_digest(signature(self.secret, url), given):
            return 403, JSON_HEADERS, b"{}"
        kind, data = self.fetch_image(url, given)
        if not kind.startswith("image/") or kind.startswith("image/svg") or len(data) > MAX_IMAGE:
            return 502, JSON_HEADERS, b"{}"
        return 200, {"Content-Type": kind, "Cache-Control": "no-store"}, data


def live_gateway():
    """The real connections, from the environment."""
    supabase = os.environ["SUPABASE_URL"].rstrip("/")
    public_key = os.environ["SUPABASE_ANON_KEY"]
    secret = os.environ["SEARXNG_SECRET"]
    searxng = os.environ.get("SEARXNG_URL", "http://searxng:8080")

    def check_sign_in(token):
        headers = {"Authorization": f"Bearer {token}", "apikey": public_key}
        try:
            with urllib.request.urlopen(urllib.request.Request(f"{supabase}/auth/v1/user", headers=headers), timeout=6) as reply:
                return json.load(reply).get("id")
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                return None
            raise

    def search(query, category, page, safety):
        form = urllib.parse.urlencode({
            "q": query, "categories": category, "pageno": page, "safesearch": safety, "format": "json",
        }).encode()
        with urllib.request.urlopen(urllib.request.Request(f"{searxng}/search", form), timeout=12) as reply:
            return json.load(reply)

    def fetch_image(url, given):
        address = f"{searxng}/image?" + urllib.parse.urlencode({"url": url, "h": given})
        with urllib.request.urlopen(address, timeout=8) as reply:
            return reply.headers.get_content_type(), reply.read(MAX_IMAGE + 1)

    return Gateway(check_sign_in, search, fetch_image, secret)


def serve(gateway, port):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        timeout = 15

        def reply(self):
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = MAX_BODY + 1
            # An oversized body is refused unread, so the connection can't be reused after it.
            if length > MAX_BODY:
                self.close_connection = True
                body = bytes(MAX_BODY + 1)
            else:
                body = self.rfile.read(length)
            status, headers, content = gateway.handle(self.command, self.path, self.headers.get("Authorization"), body)
            self.send_response(status)
            for name, value in headers.items():
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        do_GET = do_POST = do_PUT = do_DELETE = reply

        def log_message(self, format, *args):
            """Silent, because a request line is the one place a search could end up in a log."""

    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    serve(live_gateway(), int(os.environ.get("PORT", "8080")))
