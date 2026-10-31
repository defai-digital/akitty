// AkiTTY's isolated public download gateway. No write operations are exposed.
export function keyFor(url) {
  if (url.hostname !== "download.automatosx.com" || !url.pathname.startsWith("/akitty/")) return null
  const key = url.pathname.slice("/akitty/".length)
  if (["appcast.xml", "latest.json", "install"].includes(key)) return key
  return /^releases\/download\/v\d+\.\d+\.\d+\/[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(key) ? key : null
}
export function rangeFor(header, size) {
  const value = header.trim()
  const separator = value.indexOf("=")
  // RFC 9110 §14.1-14.2: range units are case-insensitive, and a unit this
  // gateway does not understand is ignored rather than rejected. `undefined`
  // therefore means "serve the whole representation"; `null` means the header
  // named bytes but its range set was malformed or unsatisfiable (416).
  if (separator < 0 || value.slice(0, separator).trim().toLowerCase() !== "bytes") return undefined
  const rangeSpec = /^(\d*)-(\d*)$/
  const specs = value.slice(separator + 1).split(",").map(part => part.trim())
  // RFC 9110 §14.1.1 allows a comma-separated range set. This gateway does not
  // implement multipart/byteranges, so a syntactically valid multi-range is
  // ignored (`undefined` -> full 200) instead of answered 416. A malformed set
  // (e.g. an empty or non-numeric member) still fails closed.
  if (specs.length > 1) return specs.every(part => {
    const match = rangeSpec.exec(part)
    return match && (match[1] || match[2]) && (!match[1] || !match[2] || BigInt(match[1]) <= BigInt(match[2]))
  }) ? undefined : null
  const values = rangeSpec.exec(specs[0])
  if (!values || (!values[1] && !values[2])) return null
  const start = values[1] ? Number(values[1]) : Math.max(0, size - Number(values[2]))
  const end = values[1] && values[2] ? Math.min(size - 1, Number(values[2])) : size - 1
  return Number.isSafeInteger(start) && Number.isSafeInteger(end) && start >= 0 && start <= end && start < size ? { offset: start, length: end - start + 1 } : null
}
// Quote-aware entity-tag list parser shared by both conditional headers.
// Commas may occur inside an opaque-tag, so the list cannot be split on `,`.
// Returns null for a malformed field, `{ wildcard: true }` for `*`, and one
// entry per entity-tag with its weakness preserved (RFC 9110 §8.8.3).
function entityTags(header) {
  const list = header.trim()
  if (!list) return null
  if (list === "*") return { wildcard: true, tags: [] }
  const tags = []
  let remaining = list
  while (remaining) {
    const match = /^(W\/)?("[\x21\x23-\x7e\x80-\xff]*")/.exec(remaining)
    if (!match) return null
    tags.push({ weak: Boolean(match[1]), tag: match[2] })
    remaining = remaining.slice(match[0].length).trim()
    if (!remaining) break
    if (!remaining.startsWith(",")) return null
    remaining = remaining.slice(1).trim()
    if (!remaining) return null
  }
  return { wildcard: false, tags }
}
export function ifMatch(header, httpEtag) {
  if (header == null) return true // absent precondition
  const parsed = entityTags(header)
  if (!parsed) return false
  if (parsed.wildcard) return true
  // RFC 9110 §13.1.1 strong comparison: a weak entity-tag on either side never
  // matches, so `W/"id"` must not satisfy If-Match for a strong current tag.
  if (/^W\//.test(httpEtag)) return false
  return parsed.tags.some(({ weak, tag }) => !weak && tag === httpEtag)
}
export function ifNoneMatch(header, httpEtag) {
  if (!header) return false
  const parsed = entityTags(header)
  if (!parsed) return false
  // RFC 9110 If-None-Match: `*` matches any existing entity (GET/HEAD answer 304).
  if (parsed.wildcard) return true
  // Otherwise the list matches when any entity-tag weakly compares equal to the
  // current one: the W/ prefix is ignored on both sides, so W/"id" and "id" both
  // match "id".
  const current = httpEtag.replace(/^W\//, "")
  return parsed.tags.some(({ tag }) => tag === current)
}
const failure = (status, message, extra = {}) => new Response(message, { status, headers: { "Cache-Control": "no-store", ...extra } })
export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") return failure(405, "Read only", { Allow: "GET, HEAD" })
    const key = keyFor(new URL(request.url))
    if (key === null) return failure(404, "Not found")
    const metadata = await env.RELEASES.head(key)
    if (!metadata) return failure(404, "Not found")
    const headers = new Headers({ "ETag": metadata.httpEtag, "Accept-Ranges": "bytes", "X-Content-Type-Options": "nosniff" })
    metadata.writeHttpMetadata(headers)
    headers.set("Cache-Control", key.startsWith("releases/") ? "public, max-age=31536000, immutable" : "no-store")
    // Conditional preconditions run in RFC 9110 §13.2.2 order: If-Match first
    // (412), then If-None-Match (304), then Range. A failed precondition must
    // answer before any body read, so nothing below `RELEASES.get` runs.
    if (!ifMatch(request.headers.get("If-Match"), metadata.httpEtag)) return failure(412, "Precondition failed", { ETag: metadata.httpEtag })
    if (ifNoneMatch(request.headers.get("If-None-Match"), metadata.httpEtag)) return new Response(null, { status: 304, headers })
    let range
    if (request.method === "GET" && request.headers.has("Range") && (!request.headers.has("If-Range") || request.headers.get("If-Range") === metadata.httpEtag)) {
      range = rangeFor(request.headers.get("Range"), metadata.size)
      if (range === null) return failure(416, "Invalid range", { "Content-Range": `bytes */${metadata.size}` })
      // Ignore unsupported units and valid multi-ranges; serve the full 200.
      if (range) headers.set("Content-Range", `bytes ${range.offset}-${range.offset + range.length - 1}/${metadata.size}`)
    }
    headers.set("Content-Length", String(range?.length ?? metadata.size))
    if (request.method === "HEAD") return new Response(null, { headers })
    const object = await env.RELEASES.get(key, { onlyIf: { etagMatches: metadata.etag }, ...(range ? { range } : {}) })
    if (!object || !("body" in object)) return failure(503, "Content changed; retry")
    return new Response(object.body, { status: range ? 206 : 200, headers })
  },
}
