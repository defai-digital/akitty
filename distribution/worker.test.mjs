import test from "node:test"
import assert from "node:assert/strict"
import worker, { keyFor, rangeFor } from "./worker.mjs"
test("gateway only exposes this product's public keys", () => {
  const key = path => keyFor(new URL("https://download.automatosx.com" + path))
  assert.equal(key("/akitty/appcast.xml"), "appcast.xml")
  assert.equal(key("/akitty/install"), "install")
  assert.equal(key("/akitty/releases/download/v0.6.0/AkiTTY-0.6.0-macOS-arm64.zip"), "releases/download/v0.6.0/AkiTTY-0.6.0-macOS-arm64.zip")
  for (const path of ["/ax-code/install", "/akitty/installer.sh", "/akitty/.internal/token", "/akitty/releases/download/v0.6.0/../secret", "/akitty/%2e%2e/secret", "/akitty/AGENTS.md"]) assert.equal(key(path), null)
  assert.equal(keyFor(new URL("https://example.com/akitty/latest.json")), null)
})
test("ranges reject malformed and unsatisfiable input", () => {
  assert.deepEqual(rangeFor("bytes=1-3", 10), { offset: 1, length: 3 })
  assert.deepEqual(rangeFor("bytes=-3", 10), { offset: 7, length: 3 })
  assert.deepEqual(rangeFor("bytes=8-", 10), { offset: 8, length: 2 })
  for (const range of ["bytes=-0", "bytes=10-", "bytes=4-2", "bytes=-", "bytes=0-1,3-4", "bytes=999999999999999999999-"]) assert.equal(rangeFor(range, 10), null)
})
test("body reads are bound to metadata; mutable feeds never cache", async () => {
  const metadata = { size: 3, etag: "identity", httpEtag: '"identity"', writeHttpMetadata: h => h.set("Content-Type", "application/xml") }
  const request = new Request("https://download.automatosx.com/akitty/appcast.xml")
  const env = { RELEASES: { head: async () => metadata, get: async (_key, opts) => { assert.equal(opts.onlyIf.etagMatches, "identity"); return { body: "abc" } } } }
  const response = await worker.fetch(request, env)
  assert.equal(await response.text(), "abc"); assert.equal(response.headers.get("Cache-Control"), "no-store")
  env.RELEASES.get = async () => ({})
  assert.equal((await worker.fetch(request, env)).status, 503)
  assert.equal((await worker.fetch(new Request(request.url, { method: "POST" }), env)).status, 405)
})
