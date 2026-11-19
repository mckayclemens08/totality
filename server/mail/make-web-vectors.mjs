// Makes docs/mail-vectors.json with the server's own seal(), so the website's opener is tested against the
// code that really seals mail. Run by hand: node server/mail/make-web-vectors.mjs. Test key only.
import { createPublicKey, hkdfSync } from 'node:crypto'
import { writeFileSync } from 'node:fs'
import { seal, sealedForm } from './mail.mjs'

const root = Buffer.from(Array.from({ length: 32 }, (_, i) => 100 + i))
const seed = Buffer.from(hkdfSync('sha256', root, Buffer.alloc(0), 'totality/mail-key/v1', 32))
// The public half, by the same route the app uses: X25519 of the seed (PKCS#8 wrapping of the raw seed).
import { createPrivateKey } from 'node:crypto'
const priv = createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), seed]), format: 'der', type: 'pkcs8' })
const pub = Buffer.from(createPublicKey(priv).export({ format: 'jwk' }).x, 'base64url')

const mailbox = '11111111-2222-4333-8444-555555555555'
const crlf = (s) => s.replaceAll('\n', '\r\n')
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64')
const messages = [
  ['plain', crlf('From: Charles Babbage <charles@example.org>\nTo: ada_lovelace@usetotality.com\nSubject: The engine\nDate: Tue, 17 Nov 2026 16:00:00 +0000\nContent-Type: text/plain; charset=utf-8\n\nThe gears arrived on Tuesday.\n<b>not html</b>\n')],
  ['rich', crlf(`From: =?UTF-8?B?w4lsw6hnYW50IFNlbmRlcg==?= <sender@example.org>
To: ada_lovelace@usetotality.com
Subject: =?UTF-8?Q?Caf=C3=A9_menu?=
Date: Wed, 18 Nov 2026 09:30:00 -0700
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="outer"

--outer
Content-Type: multipart/alternative; boundary="alt"

--alt
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: quoted-printable

Plain version =E2=9C=93
--alt
Content-Type: text/html; charset=utf-8
Content-Transfer-Encoding: quoted-printable

<html><body><p style=3D"color:red">Hello <a href=3D"https://example.com/a">a link</a> <a href=3D"javascript:alert(1)">bad</a></p><img src=3D"cid:logo1"><img src=3D"https://tracker.example/p.gif"><script>alert(1)</script></body></html>
--alt--
--outer
Content-Type: image/png
Content-ID: <logo1>
Content-Transfer-Encoding: base64

${png.toString('base64')}
--outer
Content-Type: application/pdf; name="menu.pdf"
Content-Disposition: attachment; filename="menu.pdf"
Content-Transfer-Encoding: base64

JVBERi0xLjQK
--outer--
`)],
]
const entries = messages.map(([label, raw], i) => {
  const id = `aaaaaaaa-bbbb-4ccc-8ddd-00000000000${i + 1}`
  const plain = sealedForm(Buffer.from(raw), { flagged: i === 1 }, Date.parse('2026-11-18T16:00:00Z') + i * 1000)
  return { label, id, sealed: seal(plain, pub, mailbox, id).toString('base64') }
})
// A message from another Totality account is sealed again inside, which the browser doesn't open yet.
const direct = sealedForm(Buffer.from('inner-sealed-bytes'), { flagged: false }, Date.parse('2026-11-18T17:00:00Z'), 'grace_hopper', 'ada_lovelace')
const directId = 'aaaaaaaa-bbbb-4ccc-8ddd-000000000003'
entries.push({ label: 'direct', id: directId, sealed: seal(direct, pub, mailbox, directId).toString('base64') })

writeFileSync(new URL('../../docs/mail-vectors.json', import.meta.url), JSON.stringify({
  note: 'Made by server/mail/make-web-vectors.mjs with the server\'s real seal(). Test key only.',
  rootKey: root.toString('hex'), mailbox, entries,
}, null, 2) + '\n')
