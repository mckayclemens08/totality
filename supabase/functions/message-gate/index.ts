// Answers Totality's Matrix guard (server/matrix-guard): may this Matrix user invite these people?
// The guard proves itself with MESSAGE_GATE_SECRET, which lives only in Supabase's secrets and the server's
// .env. The answer comes from public.message_gate, which only the service role can call, and the service
// role key is the one Supabase hands every edge function; it never leaves here. Nothing is logged.
const supabaseURL = Deno.env.get("SUPABASE_URL");
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const gateSecret = Deno.env.get("MESSAGE_GATE_SECRET");

const handleRule = /^[a-z0-9_]{3,24}$/;
const maxRecipients = 50;
const encoder = new TextEncoder();

// Compares digests, so how long it takes says nothing about the secret.
async function sameSecret(given: string, expected: string): Promise<boolean> {
  const [a, b] = await Promise.all([given, expected].map(async (s) =>
    new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(s)))));
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}

function reply(status: number, body?: unknown): Response {
  return new Response(body === undefined ? null : JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (request) => {
  if (!supabaseURL || !serviceKey || !gateSecret || gateSecret.length < 32) return reply(500);
  if (request.method !== "POST") return reply(405);
  if (!(await sameSecret(request.headers.get("X-Gate-Secret") ?? "", gateSecret))) return reply(401);

  let input: { sender?: unknown; recipients?: unknown };
  try { input = await request.json(); } catch { return reply(400); }
  const { sender, recipients } = input;
  if (typeof sender !== "string" || !handleRule.test(sender)) return reply(400);
  if (!Array.isArray(recipients) || recipients.length === 0 || recipients.length > maxRecipients
      || !recipients.every((r) => typeof r === "string" && handleRule.test(r))) return reply(400);

  // A broadcast channel (the guard says so, from the room's power levels) also needs each invitee to follow
  // the sender. Both rules must say yes.
  const channel = (input as { channel?: unknown }).channel === true;
  const ask = (name: string) => fetch(`${supabaseURL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_sender: sender, p_recipients: recipients }),
  });
  const answers = await Promise.all(channel ? [ask("message_gate"), ask("channel_gate")] : [ask("message_gate")]);
  if (!answers.every((a) => a.ok)) return reply(502);
  const sets: { handle: string; allowed: boolean }[][] = await Promise.all(answers.map((a) => a.json()));
  const allowed: Record<string, boolean> = {};
  for (const r of recipients) allowed[r] = sets.every((rows) => rows.some((row) => row.handle === r && row.allowed === true));
  return reply(200, { allowed });
});
