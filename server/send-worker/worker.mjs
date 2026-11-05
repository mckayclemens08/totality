// The last hop for mail to outside addresses. Only the Totality mail server can call it, with a secret
// that lives on that server and in this Worker's settings. The server has already checked the sign-in,
// the limits, and every field, and set From from the sign-in. This checks again what it can, sends, and
// says how it went. It logs nothing: a message passes through readable, so no log may hold it.

const FROM = /^[a-z0-9_]{3,24}@usetotality\.com$/
const HEADERS = new Set(['In-Reply-To', 'References'])
const encoder = new TextEncoder()

function answer(status, value) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  })
}

/** Compared in constant time, so the answer's timing says nothing about how much of a guess was right. */
function sameSecret(given, secret) {
  const [a, b] = [encoder.encode(given), encoder.encode(secret)]
  let differ = a.byteLength ^ b.byteLength
  for (let i = 0; i < b.byteLength; i += 1) differ |= (a[i] ?? 0) ^ b[i]
  return differ === 0
}

const addresses = (value) => Array.isArray(value) && value.every((address) => typeof address === 'string')

export default {
  async fetch(request, env) {
    if (!env.MAIL_SEND_SECRET) return answer(503, { code: 'E_NOT_SET_UP' })
    const authorization = request.headers.get('Authorization') ?? ''
    if (!authorization.startsWith('Bearer ') || !sameSecret(authorization.slice(7), env.MAIL_SEND_SECRET)) {
      return answer(401, { code: 'E_NOT_ALLOWED' })
    }
    if (request.method !== 'POST' || new URL(request.url).pathname !== '/') return answer(404, { code: 'E_NOT_FOUND' })
    let message
    try {
      message = await request.json()
    } catch {
      return answer(400, { code: 'E_VALIDATION_ERROR' })
    }
    const { from, to, cc, bcc, subject, text, headers = {}, attachments = [] } = message ?? {}
    if (typeof from !== 'string' || !FROM.test(from) || ![to, cc, bcc].every(addresses) || typeof subject !== 'string'
      || typeof text !== 'string' || !Array.isArray(attachments) || typeof headers !== 'object' || headers === null
      || !Object.keys(headers).every((name) => HEADERS.has(name) && typeof headers[name] === 'string')) {
      return answer(400, { code: 'E_VALIDATION_ERROR' })
    }
    try {
      await env.EMAIL.send({
        from,
        to,
        ...(cc.length && { cc }),
        ...(bcc.length && { bcc }),
        subject,
        text,
        ...(Object.keys(headers).length && { headers }),
        ...(attachments.length && {
          attachments: attachments.map(({ filename, type, content }) => ({ filename, type, content, disposition: 'attachment' })),
        }),
      })
      return answer(200, { sent: true })
    } catch (error) {
      // Only the code goes back. Cloudflare's message can quote an address.
      const code = typeof error?.code === 'string' && /^E_[A-Z_]{1,40}$/.test(error.code) ? error.code : 'E_UNKNOWN'
      return answer(502, { code })
    }
  },
}
