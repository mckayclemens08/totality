import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

const html = readFileSync("dist/index.html", "utf8");
const headers = readFileSync("dist/_headers", "utf8");

test("no inline scripts, inline styles or event handlers", () => {
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/i);
  assert.doesNotMatch(html, /<style/i);
  assert.doesNotMatch(html, /\sstyle=/i);
  assert.doesNotMatch(html, /\son[a-z]+=/i);
});

test("everything loads from our own domain, with integrity", () => {
  assert.doesNotMatch(html, /(src|href)="(https?:)?\/\//);
  for (const m of html.matchAll(/<(script|link rel="stylesheet")[^>]*>/g)) {
    assert.match(m[0], /integrity="sha384-/);
  }
  for (const f of readdirSync("dist").filter((f) => /\.(js|css)$/.test(f))) {
    const body = readFileSync(`dist/${f}`, "utf8");
    assert.doesNotMatch(body, /https?:\/\/(?!www\.w3\.org)/, `${f} reaches another host`);
  }
});

test("CSP is strict", () => {
  const csp = headers.match(/Content-Security-Policy: (.+)/)[1];
  for (const needed of ["default-src 'none'", "script-src 'self'", "frame-ancestors 'none'", "object-src 'none'", "base-uri 'none'", "require-trusted-types-for 'script'"]) {
    assert.ok(csp.includes(needed), needed);
  }
  assert.doesNotMatch(csp, /unsafe-inline|unsafe-eval|\*|https?:/);
});

test("security headers are present", () => {
  for (const h of ["Strict-Transport-Security", "X-Content-Type-Options: nosniff", "Referrer-Policy: no-referrer", "Cross-Origin-Opener-Policy: same-origin", "Permissions-Policy"]) {
    assert.ok(headers.includes(h), h);
  }
});

test("the password is never read or sent from the frame", () => {
  const js = readdirSync("dist").filter((f) => f.endsWith(".js")).map((f) => readFileSync(`dist/${f}`, "utf8")).join("");
  assert.doesNotMatch(js, /fetch\(|XMLHttpRequest|sendBeacon|WebSocket|\.password|FormData/);
});
