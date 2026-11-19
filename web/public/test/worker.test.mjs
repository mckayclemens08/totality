// The homepage Worker serves only the site's own files and never touches the server's paths.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker, { ORIGIN, PATHS } from '../worker/worker.mjs';

const calls = [];
globalThis.fetch = async (url, init) => { calls.push([url, init]); return new Response('ok', { status: 200, headers: { 'content-security-policy': "default-src 'none'", 'set-cookie': 'x=1' } }); };

test('serves the site paths from Pages, path only', async () => {
  calls.length = 0;
  const r = await worker.fetch(new Request('https://usetotality.com/main.js?x=1', { headers: { cookie: 'a=b' } }));
  assert.equal(r.status, 200);
  assert.equal(calls[0][0], ORIGIN + '/main.js');
  assert.equal(calls[0][1].headers, undefined);
  assert.equal(r.headers.get('set-cookie'), null);
  assert.ok(r.headers.get('content-security-policy'));
});

test('never proxies the server paths', async () => {
  calls.length = 0;
  for (const p of ['/privacy', '/.well-known/matrix/server', '/mail/arrive', '/web/search', '/@mckay', '/blobs/usage', '/fonts/../mail/arrive', '/index.html']) {
    const r = await worker.fetch(new Request('https://usetotality.com' + p));
    assert.equal(r.status, 404, p);
  }
  assert.equal(calls.length, 0);
});

test('rejects writes', async () => {
  const r = await worker.fetch(new Request('https://usetotality.com/', { method: 'POST', body: 'x' }));
  assert.equal(r.status, 405);
});

test('every site file is allowed', () => {
  for (const p of ['/', '/styles.css', '/main.js', '/favicon.svg', '/fonts/Geist-Variable.woff2', '/fonts/GeistMono-Variable.woff2']) assert.ok(PATHS.has(p), p);
});
