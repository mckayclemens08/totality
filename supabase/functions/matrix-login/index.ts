// Turns a Totality sign-in into a one-minute pass for the Matrix server. Supabase knows a person by an
// internal ID and Matrix needs their handle, so this checks who's asking and signs a token saying so.
// It has no other job: the private key stays in Supabase's secrets and the handle comes from the
// caller's own profile row, so nobody can ask for someone else's.
const supabaseURL = Deno.env.get("SUPABASE_URL");
const publicKey = Deno.env.get("SUPABASE_ANON_KEY");
const signingKey = Deno.env.get("MATRIX_JWT_KEY");

const lifetimeSeconds = 60;
const handleRule = /^[a-z0-9_]{3,24}$/;

const encoder = new TextEncoder();

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

async function sign(handle: string): Promise<string> {
  const der = Uint8Array.from(atob(signingKey!), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", typ: "JWT" };
  const claims = {
    iss: "totality",
    aud: "matrix.usetotality.com",
    sub: handle,
    iat: now,
    nbf: now,
    exp: now + lifetimeSeconds,
  };
  const body = `${base64url(encoder.encode(JSON.stringify(header)))}.${base64url(encoder.encode(JSON.stringify(claims)))}`;
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(body));
  return `${body}.${base64url(new Uint8Array(signature))}`;
}

function reply(status: number, body?: unknown): Response {
  return new Response(body === undefined ? null : JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (request) => {
  if (!supabaseURL || !publicKey || !signingKey) return reply(500);
  if (request.method !== "POST") return reply(405);
  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return reply(401);

  const headers = { Authorization: authorization, apikey: publicKey };
  const user = await fetch(`${supabaseURL}/auth/v1/user`, { headers });
  if (!user.ok) return reply(401);
  const { id } = await user.json();

  // Read with the caller's own token, so the row-level rules apply here too.
  const rows = await fetch(`${supabaseURL}/rest/v1/profiles?id=eq.${encodeURIComponent(id)}&select=handle`, { headers });
  if (!rows.ok) return reply(502);
  const [profile] = await rows.json();
  if (!profile || !handleRule.test(profile.handle)) return reply(403);

  return reply(200, { token: await sign(profile.handle) });
});
