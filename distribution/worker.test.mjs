import test from "node:test"
import assert from "node:assert/strict"
import worker, { keyFor, rangeFor, ifNoneMatch } from "./worker.mjs"
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
test("If-None-Match uses the RFC weak comparison function", () => {
  assert.equal(ifNoneMatch('"id"garbage', '"id"'), false)
  assert.equal(ifNoneMatch('"other, \"id\"', '"id"'), false)
  assert.equal(ifNoneMatch(undefined, '"id"'), false)
  assert.equal(ifNoneMatch("", '"id"'), false)
  assert.equal(ifNoneMatch("*", '"id"'), true)
  assert.equal(ifNoneMatch("  *  ", '"id"'), true)
  assert.equal(ifNoneMatch('"id"', '"id"'), true)
  assert.equal(ifNoneMatch('W/"id"', '"id"'), true)
  assert.equal(ifNoneMatch('"id"', 'W/"id"'), true)
  assert.equal(ifNoneMatch('W/"id"', 'W/"id"'), true)
  assert.equal(ifNoneMatch('"other", W/"id"', '"id"'), true)
  assert.equal(ifNoneMatch('W/"other", "id"', '"id"'), true)
  assert.equal(ifNoneMatch('"a,b"', '"a,b"'), true) // commas may occur inside an opaque-tag
  assert.equal(ifNoneMatch('"other"', '"id"'), false)
  assert.equal(ifNoneMatch('W/"other", W/"third"', '"id"'), false)
  assert.equal(ifNoneMatch('"id', '"id"'), false) // malformed unterminated tag
  assert.equal(ifNoneMatch('other', '"id"'), false) // unquoted tags never match
})
test("If-None-Match answers 304 without fetching the body for GET and HEAD", async () => {
  const metadata = { size: 3, etag: "identity", httpEtag: '"identity"', writeHttpMetadata: h => h.set("Content-Type", "application/xml") }
  let fetches = 0
  const env = { RELEASES: { head: async () => metadata, get: async () => { fetches++; return { body: "abc" } } } }
  const url = "https://download.automatosx.com/akitty/appcast.xml"
  for (const value of ["*", '"identity"', 'W/"identity"', '"other", W/"identity"', 'W/"other", "identity"']) {
    fetches = 0
    const response = await worker.fetch(new Request(url, { headers: { "If-None-Match": value } }), env)
    assert.equal(response.status, 304, `If-None-Match: ${value}`)
    assert.equal(await response.text(), "")
    assert.equal(response.headers.get("ETag"), '"identity"')
    assert.equal(fetches, 0, `no body fetch for ${value}`)
  }
  for (const value of ['"other"', 'W/"other"', 'garbage', '"other", "third"']) {
    fetches = 0
    const response = await worker.fetch(new Request(url, { headers: { "If-None-Match": value } }), env)
    assert.equal(response.status, 200, `If-None-Match: ${value}`)
    assert.equal(fetches, 1, `body fetched for ${value}`)
  }
  fetches = 0
  const head = await worker.fetch(new Request(url, { method: "HEAD", headers: { "If-None-Match": "*" } }), env)
  assert.equal(head.status, 304)
  assert.equal(fetches, 0)
})
