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
    const own = (process.env.SUPABASE_URL ?? "").replace(/^https?:\/\//, "");
    const allowed = ["www\\.w3\\.org", "usetotality\\.com/blobs/"].concat(own ? [own.replace(/\./g, "\\.")] : []).join("|");
    const hit = body.match(new RegExp("https?://(?!" + allowed + ")[a-z0-9][^\"'`\\s)]{0,60}"));
    assert.equal(hit, null, `${f} reaches another host: ${hit && hit[0]}`);
  }
});

test("CSP is strict", () => {
  const csp = headers.match(/Content-Security-Policy: (.+)/)[1];
  for (const needed of ["default-src 'none'", "script-src 'self'", "frame-ancestors 'none'", "object-src 'none'", "base-uri 'none'", "require-trusted-types-for 'script'"]) {
    assert.ok(csp.includes(needed), needed);
  }
  assert.doesNotMatch(csp, /unsafe-inline|unsafe-eval|\*/);
  // The page may talk to its own domain, the account server (when built with one) and the blob store. Nothing else.
  const hosts = [...csp.matchAll(/https?:\/\/[^\s;]+/g)].map((m) => m[0]);
  assert.deepEqual(hosts.filter((h) => h !== "https://usetotality.com"), process.env.SUPABASE_URL ? [process.env.SUPABASE_URL] : []);
  assert.doesNotMatch(csp.replace(/connect-src[^;]*/, ""), /https?:/, "only connect-src names another host");
});

test("security headers are present", () => {
  for (const h of ["Strict-Transport-Security", "X-Content-Type-Options: nosniff", "Referrer-Policy: no-referrer", "Cross-Origin-Opener-Policy: same-origin", "Permissions-Policy"]) {
    assert.ok(headers.includes(h), h);
  }
});

test("the password only goes to net.signIn, and nothing is logged or stored by it", () => {
  const files = readdirSync("src", { recursive: true }).filter((f) => /\.ts$/.test(f));
  for (const f of files) {
    const src = readFileSync(`src/${f}`, "utf8");
    assert.doesNotMatch(src, /console\./, `${f} logs`);
    assert.doesNotMatch(src, /setAttribute\(\s*["']style["']|cssText/, `${f} sets a style attribute, which the CSP forbids`);
    assert.doesNotMatch(src, /sendBeacon|WebSocket|XMLHttpRequest|eval\(|new Function|innerHTML|outerHTML|insertAdjacentHTML|document\.write/, f);
    if (f !== "net.ts") assert.doesNotMatch(src, /fetch\(/, `${f} calls the network directly`);
    if (!["net.ts", "main.ts"].includes(f)) assert.doesNotMatch(src, /password/i, `${f} touches the password`);
  }
  const main = readFileSync("src/main.ts", "utf8");
  const uses = (main.match(/pass\.value(?! = "")/g) ?? []);
  assert.equal(uses.length, 1, "the password field is read once, and the rest only clear it");
  assert.match(main, /net\.signIn\(user\.value, pass\.value\)/);
  // The only thing written to localStorage is the theme name.
  for (const f of files) for (const m of readFileSync(`src/${f}`, "utf8").matchAll(/(local|session)Storage\.\w+\(([^)]*)\)/g)) assert.match(m[2], /totality\.theme/);
});

test("the content key is never made extractable or written out", () => {
  const ks = readFileSync("src/keystore.ts", "utf8");
  assert.match(ks, /importKey\("raw", raw[^,]*, "HKDF", false/);
  assert.doesNotMatch(ks, /exportKey|extractable: true/);
});

test("blob: is allowed for images only, and every blob URL is tracked and revoked", () => {
  const csp = headers.match(/Content-Security-Policy: (.+)/)[1];
  assert.match(csp, /img-src 'self' blob:;/);
  assert.equal((csp.match(/blob:/g) ?? []).length, 1);
  const files = readdirSync("src", { recursive: true }).filter((f) => /\.ts$/.test(f));
  const makers = files.filter((f) => /createObjectURL/.test(readFileSync(`src/${f}`, "utf8")));
  assert.deepEqual(makers.map((f) => f.replaceAll("\\", "/")), ["photos/view.ts"]);
  const src = readFileSync("src/photos/view.ts", "utf8");
  assert.match(src, /urls\.add\(url\)/);
  assert.match(src, /revokeObjectURL/);
  assert.match(src, /stopPhotos = \(\): void => \{ run\+\+; revokeAll\(\)/);
});
