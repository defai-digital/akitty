// AkiTTY's isolated public download gateway. No write operations are exposed.
export function keyFor(url) {
  if (url.hostname !== "download.automatosx.com" || !url.pathname.startsWith("/akitty/")) return null
  const key = url.pathname.slice("/akitty/".length)
  if (["appcast.xml", "latest.json", "install"].includes(key)) return key
  return /^releases\/download\/v\d+\.\d+\.\d+\/[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(key) ? key : null
}
export function rangeFor(header, size) {
  const values = /^bytes=(\d*)-(\d*)$/.exec(header)
  if (!values || (!values[1] && !values[2])) return null
  const start = values[1] ? Number(values[1]) : Math.max(0, size - Number(values[2]))
  const end = values[1] && values[2] ? Math.min(size - 1, Number(values[2])) : size - 1
  return Number.isSafeInteger(start) && Number.isSafeInteger(end) && start >= 0 && start <= end && start < size ? { offset: start, length: end - start + 1 } : null
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
    if (request.headers.get("If-None-Match")?.split(/\s*,\s*/).includes(metadata.httpEtag)) return new Response(null, { status: 304, headers })
    let range
    if (request.method === "GET" && request.headers.has("Range") && (!request.headers.has("If-Range") || request.headers.get("If-Range") === metadata.httpEtag)) {
      range = rangeFor(request.headers.get("Range"), metadata.size)
      if (!range) return failure(416, "Invalid range", { "Content-Range": `bytes */${metadata.size}` })
      headers.set("Content-Range", `bytes ${range.offset}-${range.offset + range.length - 1}/${metadata.size}`)
    }
    headers.set("Content-Length", String(range?.length ?? metadata.size))
    if (request.method === "HEAD") return new Response(null, { headers })
    const object = await env.RELEASES.get(key, { onlyIf: { etagMatches: metadata.etag }, ...(range ? { range } : {}) })
    if (!object || !("body" in object)) return failure(503, "Content changed; retry")
    return new Response(object.body, { status: range ? 206 : 200, headers })
  },
}
