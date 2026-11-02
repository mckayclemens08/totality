// Takes each message from Cloudflare Email Routing and hands it to the mail server through the tunnel.
// It reads nothing and keeps nothing. A reject is permanent and bounces, so it's only for what the
// server is sure about. Everything else throws, which Cloudflare passes on as a temporary failure, and
// the sender's server tries again later. The 2026-11-02 trial proved that with Gmail.
const PERMANENT = {
  410: '5.1.1 No such address',
  413: '5.3.4 Message too big',
  507: '5.2.2 Mailbox full',
}

export default {
  async email(message, env) {
    const reply = await fetch(env.MAIL_ARRIVAL_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.MAIL_ARRIVAL_SECRET}`,
        'Content-Type': 'message/rfc822',
        'X-Mail-To': message.to,
      },
      body: message.raw,
    })
    if (PERMANENT[reply.status]) return message.setReject(PERMANENT[reply.status])
    if (!reply.ok) throw new Error('The mail server is away')
  },
}
