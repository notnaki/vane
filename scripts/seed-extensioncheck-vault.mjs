#!/usr/bin/env node
// Seeds a throwaway account and one login item on a disposable self-hosted
// Bitwarden-compatible server (Vaultwarden), then writes the account file that
// `vane extensioncheck` reads. Never point this at a server holding real data.
// Usage: node scripts/seed-extensioncheck-vault.mjs <https server> <fixtures/bitwarden-account.json>
import crypto from 'node:crypto';
import fs from 'node:fs';

const [server, output] = process.argv.slice(2);
if (!server?.startsWith('https://') || !output) {
  console.error('usage: seed-extensioncheck-vault.mjs <https server> <output json>');
  process.exit(2);
}
const account = {
  server,
  email: `vane-fixture-${crypto.randomUUID().slice(0, 8)}@example.com`,
  masterPassword: crypto.randomUUID(),
  username: `fixture-user-${crypto.randomUUID().slice(0, 8)}`,
  password: crypto.randomUUID(),
};
const iterations = 600000;
const b64 = bytes => Buffer.from(bytes).toString('base64');
const masterKey = crypto.pbkdf2Sync(account.masterPassword, account.email, iterations, 32, 'sha256');
const hash = b64(crypto.pbkdf2Sync(masterKey, account.masterPassword, 1, 32, 'sha256'));
const expand = info => crypto.createHmac('sha256', masterKey).update(Buffer.concat([Buffer.from(info), Buffer.from([1])])).digest();
// Bitwarden "type 2" strings: AES-256-CBC, then HMAC-SHA256 over IV and ciphertext.
function encrypt(data, key) {
  const iv = crypto.randomBytes(16);
  const cipher = crypto.createCipheriv('aes-256-cbc', key.enc, iv);
  const text = Buffer.concat([cipher.update(data), cipher.final()]);
  const mac = crypto.createHmac('sha256', key.mac).update(Buffer.concat([iv, text])).digest();
  return `2.${b64(iv)}|${b64(text)}|${b64(mac)}`;
}
const symmetric = crypto.randomBytes(64);
const userKey = { enc: symmetric.subarray(0, 32), mac: symmetric.subarray(32) };
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'der' },
  privateKeyEncoding: { type: 'pkcs8', format: 'der' },
});
async function post(path, body, headers = {}) {
  const form = typeof body === 'string';
  const response = await fetch(server + path, {
    method: 'POST',
    body: form ? body : JSON.stringify(body),
    headers: { 'content-type': form ? 'application/x-www-form-urlencoded' : 'application/json', ...headers },
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${path} ${response.status} ${text.slice(0, 300)}`);
  try { return JSON.parse(text); } catch { return text; }
}
const verification = await post('/identity/accounts/register/send-verification-email',
  { email: account.email, name: 'Vane Fixture', receiveMarketingEmails: false });
await post('/identity/accounts/register/finish', {
  email: account.email, emailVerificationToken: verification, masterPasswordHash: hash, masterPasswordHint: null,
  userSymmetricKey: encrypt(symmetric, { enc: expand('enc'), mac: expand('mac') }), kdf: 0, kdfIterations: iterations,
  userAsymmetricKeys: { publicKey: b64(publicKey), encryptedPrivateKey: encrypt(privateKey, userKey) },
});
const token = await post('/identity/connect/token', new URLSearchParams({
  grant_type: 'password', username: account.email, password: hash, scope: 'api offline_access', client_id: 'cli',
  deviceType: '8', deviceIdentifier: crypto.randomUUID(), deviceName: 'vane-extensioncheck-seed',
}).toString());
const owner = JSON.parse(Buffer.from(token.access_token.split('.')[1], 'base64url')).sub;
const seal = text => encrypt(Buffer.from(text), userKey);
await post('/api/ciphers', {
  encryptedFor: owner, type: 1, name: seal('Vane fixture login'), notes: null, favorite: false, reprompt: 0,
  // The harness serves its login form from a random loopback port.
  login: { username: seal(account.username), password: seal(account.password), totp: null, uris: [{ uri: seal('http://127.0.0.1'), match: null }] },
}, { authorization: 'Bearer ' + token.access_token });
fs.writeFileSync(output, JSON.stringify(account, null, 2) + '\n', { mode: 0o600 });
console.log(`Seeded ${account.email} with one login item; wrote ${output}`);
