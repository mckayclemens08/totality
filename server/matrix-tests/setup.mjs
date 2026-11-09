// Prepares a throwaway Matrix server for the two-user tests: the production config with a signing key
// made fresh for this run. Nothing here is a secret worth keeping; the key dies with the CI machine.
import { generateKeyPairSync } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync, chmodSync } from 'node:fs'

const out = process.argv[2] ?? '/tmp/matrix-test'
mkdirSync(`${out}/data`, { recursive: true })
chmodSync(`${out}/data`, 0o777)

const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' })
const pub = publicKey.export({ type: 'spki', format: 'pem' }).trim()
writeFileSync(`${out}/jwt-private.pem`, privateKey.export({ type: 'pkcs8', format: 'pem' }))

const production = readFileSync(new URL('../tuwunel.toml', import.meta.url), 'utf8')
const config = production
  .replace(/key = """[\s\S]*?"""/, `key = """\n${pub}\n"""`)
  // Requests come straight from the test, not through Cloudflare.
  .replace(/^ip_source = .*$/m, '')
if (config === production || !config.includes(pub)) throw new Error('the production config changed shape')
writeFileSync(`${out}/tuwunel.toml`, config)
console.log(`wrote ${out}/tuwunel.toml`)
