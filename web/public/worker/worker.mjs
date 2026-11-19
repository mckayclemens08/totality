// Serves the public homepage at usetotality.com from the totality-public Pages project.
// It runs only on the routes in wrangler.toml. Every other path on the apex (Matrix, mail, search,
// blobs, profiles, /privacy) stays on the server tunnel and never reaches this Worker.
export const ORIGIN = 'https://totality-public.pages.dev';
export const PATHS = new Set(['/', '/styles.css', '/main.js', '/favicon.svg', '/fonts/Geist-Variable.woff2', '/fonts/GeistMono-Variable.woff2', '/fonts/OFL.txt']);

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (!PATHS.has(url.pathname)) return new Response('Not found', { status: 404 });
    if (request.method !== 'GET' && request.method !== 'HEAD') return new Response('Method not allowed', { status: 405, headers: { allow: 'GET, HEAD' } });
    // Only the path goes to Pages: no query, cookies or client headers are passed on.
    const res = await fetch(ORIGIN + url.pathname, { method: request.method, redirect: 'manual' });
    const headers = new Headers(res.headers);
    headers.delete('set-cookie');
    return new Response(request.method === 'HEAD' ? null : res.body, { status: res.status, headers });
  }
};
