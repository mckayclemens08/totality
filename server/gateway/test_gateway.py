import json
import unittest

import gateway
from gateway import Gateway, signature

SECRET = "not-a-real-secret"
ALICE = "Bearer alice.token"
BOB = "Bearer bob.token"


class Clock:
    def __init__(self):
        self.now = 1_000_000.0

    def __call__(self):
        return self.now


class Fakes:
    def __init__(self):
        self.clock = Clock()
        self.checks = 0
        self.searches = []
        self.image = ("image/png", b"png")
        self.answer = {"results": [
            {"title": "Tram 28", "url": "https://www.carris.pt/28", "content": "The yellow tram.", "thumbnail": "https://img.example/a.jpg"},
        ]}
        self.gateway = Gateway(self.check, self.search, self.fetch, SECRET, self.clock)

    def check(self, token):
        self.checks += 1
        return {"alice.token": "alice", "bob.token": "bob"}.get(token)

    def search(self, query, category, page, safety):
        self.searches.append((query, category, page, safety))
        if isinstance(self.answer, Exception):
            raise self.answer
        return self.answer

    def fetch(self, url, given):
        return self.image

    def post(self, path="/web/search", auth=ALICE, **body):
        return self.gateway.handle("POST", path, auth, json.dumps(body).encode())


class Access(unittest.TestCase):
    def test_a_signed_out_caller_is_refused(self):
        fakes = Fakes()
        self.assertEqual(fakes.post(auth=None, query="tram")[0], 401)
        self.assertEqual(fakes.post(auth="Bearer nobody", query="tram")[0], 401)
        self.assertEqual(fakes.post(auth="Basic alice.token", query="tram")[0], 401)
        self.assertEqual(fakes.searches, [])

    def test_a_token_with_a_line_break_never_reaches_supabase(self):
        fakes = Fakes()
        self.assertEqual(fakes.post(auth="Bearer a\r\nX: y", query="tram")[0], 401)
        self.assertEqual(fakes.checks, 0)

    def test_sign_ins_are_checked_again_after_a_minute(self):
        fakes = Fakes()
        fakes.post(query="one")
        fakes.post(query="two")
        self.assertEqual(fakes.checks, 1)
        fakes.clock.now += gateway.SIGN_IN_SECONDS + 1
        fakes.post(query="three")
        self.assertEqual(fakes.checks, 2)

    def test_one_account_does_not_reuse_anothers_check(self):
        fakes = Fakes()
        fakes.post(query="one")
        fakes.post(auth=BOB, query="two")
        self.assertEqual(fakes.checks, 2)

    def test_only_the_two_paths_exist(self):
        fakes = Fakes()
        self.assertEqual(fakes.gateway.handle("POST", "/search", ALICE, b"{}")[0], 404)
        self.assertEqual(fakes.gateway.handle("POST", "/web/search?q=tram", ALICE, b"{}")[0], 404)
        self.assertEqual(fakes.gateway.handle("GET", "/web/search", ALICE, b"")[0], 405)

    def test_an_outage_at_supabase_is_not_a_sign_out(self):
        fakes = Fakes()

        def down(token):
            raise OSError()

        fakes.gateway.check_sign_in = down
        self.assertEqual(fakes.post(query="tram")[0], 502)


class Searching(unittest.TestCase):
    def test_a_search_gets_only_what_the_app_draws(self):
        status, headers, body = Fakes().post(query=" tram ")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        result = json.loads(body)["results"][0]
        self.assertEqual(result["site"], "carris.pt")
        self.assertEqual(result["snippet"], "The yellow tram.")
        self.assertEqual(set(result), {"title", "url", "site", "snippet", "thumbnail"})
        self.assertEqual(result["thumbnail"]["signature"], signature(SECRET, "https://img.example/a.jpg"))

    def test_the_search_reaches_searxng_tidied(self):
        fakes = Fakes()
        fakes.post(query=" tram ", category="news", page=2, safety=0)
        self.assertEqual(fakes.searches, [("tram", "news", 2, 0)])

    def test_web_means_general_and_safe_search_defaults_to_moderate(self):
        fakes = Fakes()
        fakes.post(query="tram")
        self.assertEqual(fakes.searches, [("tram", "general", 1, 1)])

    def test_bad_requests_never_reach_searxng(self):
        fakes = Fakes()
        for body in (
            {}, {"query": ""}, {"query": "   "}, {"query": 5}, {"query": "x" * (gateway.MAX_QUERY + 1)},
            {"query": "tram", "category": "files"}, {"query": "tram", "page": 0},
            {"query": "tram", "page": gateway.MAX_PAGE + 1}, {"query": "tram", "page": True},
            {"query": "tram", "safety": 3}, {"query": "tram", "safety": "1"},
        ):
            self.assertEqual(fakes.post(**body)[0], 400, body)
        self.assertEqual(fakes.gateway.handle("POST", "/web/search", ALICE, b"[1]")[0], 400)
        self.assertEqual(fakes.gateway.handle("POST", "/web/search", ALICE, b"nope")[0], 400)
        self.assertEqual(fakes.searches, [])

    def test_a_large_body_is_refused_before_anything_else(self):
        fakes = Fakes()
        self.assertEqual(fakes.gateway.handle("POST", "/web/search", ALICE, b" " * (gateway.MAX_BODY + 1))[0], 413)
        self.assertEqual(fakes.checks, 0)

    def test_links_a_browser_should_not_follow_are_dropped(self):
        fakes = Fakes()
        fakes.answer = {"results": [
            {"title": "Bad", "url": "javascript:alert(1)"}, {"title": "Bad", "url": "file:///etc/passwd"},
            {"title": "Bad", "url": "https://"}, {"title": "Bad"}, {"title": "Good", "url": "http://example.com/"},
        ]}
        results = json.loads(fakes.post(query="tram")[2])["results"]
        self.assertEqual([result["title"] for result in results], ["Good"])

    def test_results_are_capped(self):
        fakes = Fakes()
        fakes.answer = {"results": [{"title": "Page", "url": f"https://example.com/{n}"} for n in range(100)]}
        self.assertEqual(len(json.loads(fakes.post(query="tram")[2])["results"]), gateway.MAX_RESULTS)

    def test_an_engine_that_stopped_answering_is_reported(self):
        fakes = Fakes()
        self.assertFalse(json.loads(fakes.post(query="tram")[2])["partial"])
        fakes.answer = {"results": [], "unresponsive_engines": [["brave", "CAPTCHA"]]}
        self.assertTrue(json.loads(fakes.post(query="tram")[2])["partial"])

    def test_searxng_being_down_is_a_502(self):
        fakes = Fakes()
        fakes.answer = OSError()
        self.assertEqual(fakes.post(query="tram")[0], 502)


class Limits(unittest.TestCase):
    def test_the_minute_limit_is_per_account_and_passes(self):
        fakes = Fakes()
        for _ in range(gateway.PER_MINUTE):
            self.assertEqual(fakes.post(query="tram")[0], 200)
        self.assertEqual(fakes.post(query="tram")[0], 429)
        self.assertEqual(fakes.post(auth=BOB, query="tram")[0], 200)
        fakes.clock.now += 60
        self.assertEqual(fakes.post(query="tram")[0], 200)

    def test_the_daily_limit_holds_across_minutes(self):
        fakes = Fakes()
        fakes.clock.now = 86_400 * 12.0
        for search in range(gateway.PER_DAY):
            self.assertEqual(fakes.post(query="tram")[0], 200)
            if search % gateway.PER_MINUTE == gateway.PER_MINUTE - 1:
                fakes.clock.now += 60
        self.assertEqual(fakes.post(query="tram")[0], 429)
        fakes.clock.now += 86_400
        self.assertEqual(fakes.post(query="tram")[0], 200)

    def test_a_refused_search_never_reaches_searxng(self):
        fakes = Fakes()
        for _ in range(gateway.PER_MINUTE + 5):
            fakes.post(query="tram")
        self.assertEqual(len(fakes.searches), gateway.PER_MINUTE)


class Images(unittest.TestCase):
    url = "https://img.example/a.jpg"

    def post(self, fakes, **body):
        return fakes.post(path="/web/image", **body)

    def test_a_thumbnail_the_gateway_handed_out_comes_back(self):
        status, headers, body = self.post(Fakes(), url=self.url, signature=signature(SECRET, self.url))
        self.assertEqual((status, headers["Content-Type"], body), (200, "image/png", b"png"))

    def test_any_other_address_is_refused(self):
        for address in ("http://169.254.169.254/latest", "http://tuwunel:8008/_matrix", self.url + "x"):
            self.assertEqual(self.post(Fakes(), url=address, signature=signature(SECRET, self.url))[0], 403)
        self.assertEqual(self.post(Fakes(), url=self.url, signature="0" * 64)[0], 403)

    def test_it_needs_a_sign_in(self):
        self.assertEqual(self.post(Fakes(), auth=None, url=self.url, signature=signature(SECRET, self.url))[0], 401)

    def test_only_images_come_back(self):
        for kind in ("text/html", "application/json", "image/svg+xml"):
            fakes = Fakes()
            fakes.image = (kind, b"<script>")
            self.assertEqual(self.post(fakes, url=self.url, signature=signature(SECRET, self.url))[0], 502)

    def test_an_oversized_image_is_refused(self):
        fakes = Fakes()
        fakes.image = ("image/png", b"0" * (gateway.MAX_IMAGE + 1))
        self.assertEqual(self.post(fakes, url=self.url, signature=signature(SECRET, self.url))[0], 502)

    def test_a_missing_field_is_a_bad_request(self):
        self.assertEqual(self.post(Fakes(), url=self.url)[0], 400)


if __name__ == "__main__":
    unittest.main()
