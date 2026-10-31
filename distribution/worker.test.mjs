import test from "node:test"
import assert from "node:assert/strict"
import worker, { keyFor, rangeFor, ifMatch, ifNoneMatch } from "./worker.mjs"
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
  for (const range of ["bytes=-0", "bytes=10-", "bytes=4-2", "bytes=-", "bytes=999999999999999999999-"]) assert.equal(rangeFor(range, 10), null)
})
test("valid multi-range headers are ignored so the full representation is served", () => {
  // This gateway omits multipart/byteranges, so a well-formed range set with more
  // than one range is ignored (`undefined`) rather than answered 416.
  for (const range of ["bytes=0-1,4-5", "bytes=0-1,3-4", "BYTES=0-1,3-4", "bytes=0-1, 4-5", "bytes=-3,8-", "bytes=0-1,999-"]) assert.equal(rangeFor(range, 10), undefined)
  // A malformed member still fails the whole range set closed.
  for (const range of ["bytes=0-1,4-2", "bytes=0-1,", "bytes=0-1,-", "bytes=0-1,abc", "bytes=0-1,,4-5", "bytes=,0-1"]) assert.equal(rangeFor(range, 10), null)
})
test("range units are case-insensitive and unsupported units are ignored", () => {
  for (const unit of ["Bytes", "BYTES", "bYtEs"]) assert.deepEqual(rangeFor(`${unit}=1-3`, 10), { offset: 1, length: 3 })
  for (const range of ["items=0-1", "ITEMS=0-1", "frames=0-1", "nonsense", ""]) assert.equal(rangeFor(range, 10), undefined)
  // A bytes unit with a bad range set is still an error, not an ignored unit.
  assert.equal(rangeFor("Bytes=4-2", 10), null)
  assert.equal(rangeFor("BYTES=0-1,3-4", 10), undefined) // valid multi-range, ignored
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
test("If-Match uses the RFC strong comparison function", () => {
  assert.equal(ifMatch(undefined, '"id"'), true) // absent precondition
  assert.equal(ifMatch("", '"id"'), false) // present but empty never matches
  assert.equal(ifMatch("*", '"id"'), true) // wildcard matches any current representation
  assert.equal(ifMatch("  *  ", '"id"'), true)
  assert.equal(ifMatch('"id"', '"id"'), true)
  assert.equal(ifMatch('"other", "id"', '"id"'), true) // list hits on a strong tag
  assert.equal(ifMatch('W/"other", "id"', '"id"'), true) // weak siblings do not poison a strong hit
  assert.equal(ifMatch('"a,b"', '"a,b"'), true) // commas may occur inside an opaque-tag
  assert.equal(ifMatch('"other"', '"id"'), false)
  assert.equal(ifMatch('"other", "third"', '"id"'), false)
  assert.equal(ifMatch('W/"id"', '"id"'), false) // a weak candidate never strongly matches
  assert.equal(ifMatch('"other", W/"id"', '"id"'), false)
  assert.equal(ifMatch('"a,b"', '"a"'), false)
  assert.equal(ifMatch('"id"', 'W/"id"'), false) // a weak current tag never strongly matches
  assert.equal(ifMatch('"id"', 'W/"identity"'), false)
  assert.equal(ifMatch('"id', '"id"'), false) // malformed unterminated tag
  assert.equal(ifMatch("id", '"id"'), false) // unquoted tags never match
  assert.equal(ifMatch("garbage", '"id"'), false)
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
test("If-Match answers 412 before If-None-Match and Range without fetching the body", async () => {
  const metadata = { size: 3, etag: "identity", httpEtag: '"identity"', writeHttpMetadata: h => h.set("Content-Type", "application/xml") }
  let fetches = 0
  const env = { RELEASES: { head: async () => metadata, get: async () => { fetches++; return { body: "abc" } } } }
  const url = "https://download.automatosx.com/akitty/appcast.xml"
  // If-None-Match and Range are sent too: a failed If-Match must win over both.
  for (const method of ["GET", "HEAD"]) {
    for (const value of ["", '"other"', 'W/"identity"', 'W/"other", W/"identity"', '"other", "third"', "garbage"]) {
      fetches = 0
      const response = await worker.fetch(new Request(url, { method, headers: { "If-Match": value, "If-None-Match": "*", Range: "bytes=9-" } }), env)
      assert.equal(response.status, 412, `${method} If-Match: ${value}`)
      assert.equal(await response.text(), "Precondition failed")
      assert.equal(response.headers.get("Cache-Control"), "no-store")
      assert.equal(fetches, 0, `no body fetch for ${method} If-Match: ${value}`)
    }
  }
  for (const value of ['"identity"', "*", '"other", "identity"', 'W/"other", "identity"']) {
    fetches = 0
    const response = await worker.fetch(new Request(url, { headers: { "If-Match": value } }), env)
    assert.equal(response.status, 200, `If-Match: ${value}`)
    assert.equal(await response.text(), "abc")
    assert.equal(fetches, 1, `body fetched for If-Match: ${value}`)
  }
  fetches = 0
  const head = await worker.fetch(new Request(url, { method: "HEAD", headers: { "If-Match": '"identity"' } }), env)
  assert.equal(head.status, 200)
  assert.equal(fetches, 0)
  fetches = 0
  // A matching If-Match falls through to If-None-Match, which still answers 304.
  const cached = await worker.fetch(new Request(url, { headers: { "If-Match": '"identity"', "If-None-Match": '"identity"' } }), env)
  assert.equal(cached.status, 304)
  assert.equal(fetches, 0)
})
test("Range units are case-insensitive at the endpoint", async () => {
  const metadata = { size: 3, etag: "identity", httpEtag: '"identity"', writeHttpMetadata: h => h.set("Content-Type", "application/zip") }
  const url = "https://download.automatosx.com/akitty/releases/download/v0.6.0/AkiTTY-0.6.0-macOS-arm64.zip"
  let seen = null
  const env = { RELEASES: { head: async () => metadata, get: async (_key, opts) => { seen = opts; return { body: "abc" } } } }
  for (const [value, contentRange, range] of [
    ["Bytes=0-1", "bytes 0-1/3", { offset: 0, length: 2 }],
    ["BYTES=0-1", "bytes 0-1/3", { offset: 0, length: 2 }],
    ["bYtEs=1-", "bytes 1-2/3", { offset: 1, length: 2 }],
  ]) {
    seen = null
    const response = await worker.fetch(new Request(url, { headers: { Range: value } }), env)
    assert.equal(response.status, 206, value)
    assert.equal(response.headers.get("Content-Range"), contentRange, value)
    assert.deepEqual(seen.range, range, value)
  }
})
test("unsupported Range units are ignored and serve the full representation", async () => {
  const metadata = { size: 3, etag: "identity", httpEtag: '"identity"', writeHttpMetadata: h => h.set("Content-Type", "application/zip") }
  const url = "https://download.automatosx.com/akitty/releases/download/v0.6.0/AkiTTY-0.6.0-macOS-arm64.zip"
  let seen = null
  const env = { RELEASES: { head: async () => metadata, get: async (_key, opts) => { seen = opts; return { body: "abc" } } } }
  for (const value of ["items=0-1", "ITEMS=0-1", "frames=0-1", "garbage"]) {
    seen = null
    const response = await worker.fetch(new Request(url, { headers: { Range: value } }), env)
    assert.equal(response.status, 200, `Range: ${value}`)
    assert.equal(response.headers.get("Content-Range"), null, `Range: ${value}`)
    assert.equal(response.headers.get("Content-Length"), "3", `Range: ${value}`)
    assert.equal(seen.range, undefined, `range not forwarded for ${value}`)
    assert.equal(await response.text(), "abc", `Range: ${value}`)
  }
  seen = null
  const head = await worker.fetch(new Request(url, { method: "HEAD", headers: { Range: "items=0-1" } }), env)
  assert.equal(head.status, 200)
  assert.equal(head.headers.get("Content-Range"), null)
  assert.equal(seen, null)
})
test("valid multi-range requests are ignored and serve the full representation", async () => {
  const metadata = { size: 3, etag: "identity", httpEtag: '"identity"', writeHttpMetadata: h => h.set("Content-Type", "application/zip") }
  const url = "https://download.automatosx.com/akitty/releases/download/v0.6.0/AkiTTY-0.6.0-macOS-arm64.zip"
  let seen = null
  const env = { RELEASES: { head: async () => metadata, get: async (_key, opts) => { seen = opts; return { body: "abc" } } } }
  for (const value of ["bytes=0-1,4-5", "BYTES=0-1,3-4", "bytes=0-1, 4-5", "bytes=-2,1-"]) {
    seen = null
    const response = await worker.fetch(new Request(url, { headers: { Range: value } }), env)
    assert.equal(response.status, 200, `Range: ${value}`)
    assert.equal(response.headers.get("Content-Range"), null, `Range: ${value}`)
    assert.equal(response.headers.get("Content-Length"), "3", `Range: ${value}`)
    assert.equal(seen.range, undefined, `range not forwarded for ${value}`)
    assert.equal(await response.text(), "abc", `Range: ${value}`)
  }
  seen = null
  const head = await worker.fetch(new Request(url, { method: "HEAD", headers: { Range: "bytes=0-1,4-5" } }), env)
  assert.equal(head.status, 200)
  assert.equal(head.headers.get("Content-Range"), null)
  assert.equal(seen, null)
})
test("malformed and unsatisfiable byte ranges stay 416 at the endpoint", async () => {
  const metadata = { size: 3, etag: "identity", httpEtag: '"identity"', writeHttpMetadata: h => h.set("Content-Type", "application/zip") }
  const url = "https://download.automatosx.com/akitty/releases/download/v0.6.0/AkiTTY-0.6.0-macOS-arm64.zip"
  let seen = null
  const env = { RELEASES: { head: async () => metadata, get: async (_key, opts) => { seen = opts; return { body: "abc" } } } }
  for (const value of ["bytes=3-", "bytes=4-2", "bytes=-", "bytes=0-1,", "bytes=0-1,abc", "bytes=-0", "bytes=abc-def", "Bytes=9-"]) {
    seen = null
    const response = await worker.fetch(new Request(url, { headers: { Range: value } }), env)
    assert.equal(response.status, 416, `Range: ${value}`)
    assert.equal(response.headers.get("Content-Range"), "bytes */3", `Range: ${value}`)
    assert.equal(seen, null, `no body fetch for ${value}`)
  }
})
