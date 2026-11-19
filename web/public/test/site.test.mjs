// Checks the public site keeps the strict-CSP rules and the theme contrast rules.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';

const dir = new URL('../site/', import.meta.url);
const read = f => readFileSync(new URL(f, dir), 'utf8');
const html = read('index.html'), css = read('styles.css'), js = read('main.js'), headers = read('_headers');

test('no inline scripts, styles or event handlers', () => {
  for (const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)) {
    assert.match(m[1], /\bsrc="\/[^"]+"/, 'every script has a same-origin src');
    assert.equal(m[2].trim(), '', 'no inline script body');
  }
  assert.doesNotMatch(html, /<style\b/i);
  assert.doesNotMatch(html, /\sstyle="/i);
  assert.doesNotMatch(html, /\son[a-z]+="/i);
});

test('nothing loads from another origin', () => {
  const refs = [...html.matchAll(/(?:src|href)="([^"]+)"/g)].map(m => m[1]);
  for (const r of refs) {
    if (r.startsWith('/') || r.startsWith('#')) continue;
    assert.equal(r, 'https://app.usetotality.com', `only a plain link to the web app may leave the site: ${r}`);
  }
  for (const tag of html.matchAll(/<(?:script|link|img|iframe)\b[^>]*>/g)) {
    if (/<link\b/.test(tag[0]) && !/rel="(?:stylesheet|icon|preload)"/.test(tag[0])) continue;
    assert.doesNotMatch(tag[0], /https?:\/\//, `no remote resource: ${tag[0]}`);
  }
  assert.doesNotMatch(css, /url\(\s*["']?https?:/);
  assert.doesNotMatch(js, /\bfetch\(|XMLHttpRequest|WebSocket|sendBeacon|innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|new Function/);
});

test('fonts are self-hosted', () => {
  for (const f of ['fonts/Geist-Variable.woff2', 'fonts/GeistMono-Variable.woff2', 'fonts/OFL.txt']) assert.ok(existsSync(new URL(f, dir)), f);
});

test('strict headers', () => {
  const csp = headers.match(/Content-Security-Policy: (.+)/)[1];
  for (const d of ["default-src 'none'", "script-src 'self'", "style-src 'self'", "font-src 'self'", "connect-src 'none'", "frame-ancestors 'none'", "object-src 'none'", "require-trusted-types-for 'script'"]) assert.ok(csp.includes(d), d);
  assert.doesNotMatch(csp, /unsafe|\*|https?:/);
  assert.match(headers, /Strict-Transport-Security/);
  assert.match(headers, /X-Content-Type-Options: nosniff/);
});

// WCAG AA: body and muted text 4.5:1 on bg and surface, accent 4.5:1 on bg, text on accent 4.5:1.
const lum = h => { const c = [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16) / 255).map(v => v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4); return .2126 * c[0] + .7152 * c[1] + .0722 * c[2]; };
const ratio = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + .05) / (Math.min(x, y) + .05); };
test('every theme meets AA', () => {
  const themes = [...css.matchAll(/body\[data-skin="(\w+)"\]\{([^}]+)\}/g)];
  assert.equal(themes.length, 6);
  for (const [, name, body] of themes) {
    const v = k => body.match(new RegExp(`--${k}:(#[0-9A-Fa-f]{6})`))[1];
    for (const [fg, bg] of [['fg', 'bg'], ['muted', 'bg'], ['muted', 'surface'], ['fg', 'surface'], ['accent', 'bg'], ['on', 'accent'], ['fg', 'hls']])
      assert.ok(ratio(v(fg), v(bg)) >= 4.5, `${name}: ${fg} on ${bg} is ${ratio(v(fg), v(bg)).toFixed(2)}`);
  }
});
