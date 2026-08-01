import { servedTypeFor } from "./mime";

/// Parses a `Range` header into what R2 wants.
///
/// Only a single range is honoured. Multi-range requests (`bytes=0-9,20-29`)
/// require a multipart/byteranges body, no browser video player sends them, and
/// half-implementing that format is worse than ignoring the header -- so an
/// unparseable or multi-range header returns undefined and the full body is
/// sent, which is always a legal answer.
export function parseRange(header: string | null): R2Range | undefined {
  if (!header) return undefined;
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match) return undefined;

  const [, rawStart, rawEnd] = match;
  if (rawStart === "" && rawEnd === "") return undefined;

  // "bytes=-500": the last 500 bytes.
  if (rawStart === "") return { suffix: Number(rawEnd) };

  const offset = Number(rawStart);
  if (rawEnd === "") return { offset };

  const end = Number(rawEnd);
  if (end < offset) return undefined;
  return { offset, length: end - offset + 1 };
}

/// Content-Range needs two concrete numbers; a parsed range is three optional
/// ones. This turns the second into the first.
///
/// Two things measured rather than assumed, both of which produced a
/// `bytes NaN-69/70` header before they were understood:
///
///  - the range this resolves is the one *we* parsed, not `R2Object.range`.
///  - `"suffix" in range` is not a usable discriminator. The object handed back
///    carries all three keys with the unused ones set to `undefined`, so the
///    `in` test passes for a plain offset range and `size - undefined` is NaN.
///    Checking the value's type is the only test that holds.
function resolve(range: R2Range | undefined, size: number): { start: number; end: number } {
  if (!range) return { start: 0, end: Math.max(0, size - 1) };

  const shape = range as { offset?: number; length?: number; suffix?: number };

  if (typeof shape.suffix === "number") {
    return { start: Math.max(0, size - shape.suffix), end: size - 1 };
  }

  const start = shape.offset ?? 0;
  const end = shape.length === undefined ? size - 1 : Math.min(size - 1, start + shape.length - 1);
  return { start, end };
}

export interface ServeOptions {
  /// Filename offered to the browser. Also decides `Content-Disposition`
  /// together with the extension's safety.
  filename: string;
  ext: string;
  /// Force a download even for a type that could be displayed. What `/:key/dl`
  /// uses.
  download: boolean;
}

export async function serveObject(
  bucket: R2Bucket,
  objectKey: string,
  request: Request,
  options: ServeOptions,
): Promise<Response> {
  const { contentType, forceDownload } = servedTypeFor(options.ext);
  const attachment = forceDownload || options.download;

  const base = new Headers({
    "Content-Type": contentType,
    "Accept-Ranges": "bytes",
    // The bytes at a key never change -- a new upload is a new key -- so this
    // is honest, and it lets the *recipient's browser* keep its copy.
    //
    // It is deliberately NOT backed by the Cache API, though the saving would be
    // real: a video being scrubbed sends a lot of range requests and every one
    // of them reaches R2. Measured 2026-08-01 against the deployed Worker --
    // responses carry no `cf-cache-status` at all, i.e. nothing is edge-cached.
    //
    // The reason to leave it that way is DELETE. `caches.default.delete()` is
    // per-colo, so an edge-cached object would go on being served from every
    // data centre that had not been asked, and "delete this link" would become
    // "delete this link, eventually, in most places". These links carry
    // screenshots. Revocation that actually revokes is worth more than the
    // Class B operations, of which the free tier has ten million a month.
    //
    // If those ever do become a problem, the move is to cache the SIDECAR alone
    // on a short TTL and never the bytes: the existence check goes stale by at
    // most the TTL, while deleting the object still revokes the bytes at once.
    "Cache-Control": "public, max-age=31536000, immutable",
    "X-Content-Type-Options": "nosniff",
    "X-Robots-Tag": "noindex, nofollow",
  });
  if (attachment) {
    base.set("Content-Disposition", `attachment; filename="${sanitizeFilename(options.filename)}"`);
  }

  if (request.method === "HEAD") {
    const head = await bucket.head(objectKey);
    if (!head) return new Response(null, { status: 404 });
    base.set("Content-Length", String(head.size));
    base.set("ETag", head.httpEtag);
    return new Response(null, { status: 200, headers: base });
  }

  const range = parseRange(request.headers.get("Range"));

  let object: R2Object | R2ObjectBody | null;
  try {
    // `onlyIf` takes the request's own headers: R2 evaluates If-None-Match and
    // If-Modified-Since itself and returns a bodyless object when the client's
    // copy is current.
    object = await bucket.get(objectKey, { range, onlyIf: request.headers });
  } catch {
    // The one thing that lands here in practice is a range starting past the
    // end of the object.
    return new Response("range not satisfiable", { status: 416, headers: base });
  }

  if (object === null) return new Response(null, { status: 404 });

  base.set("ETag", object.httpEtag);

  if (!("body" in object)) {
    // Condition failed -- the client already has these bytes.
    return new Response(null, { status: 304, headers: base });
  }

  if (range) {
    const { start, end } = resolve(range, object.size);
    base.set("Content-Range", `bytes ${start}-${end}/${object.size}`);
    base.set("Content-Length", String(end - start + 1));
    return new Response(object.body, { status: 206, headers: base });
  }

  base.set("Content-Length", String(object.size));
  return new Response(object.body, { status: 200, headers: base });
}

/// Serves a one-time object and then hands the caller the go-ahead to destroy it.
///
/// Everything here is a consequence of `consume` being irreversible:
///
///  - the body is buffered rather than streamed. Handing R2's stream to the
///    runtime and deleting the object underneath it is a race whose loser is the
///    recipient, who gets a truncated file and no second chance. The upload side
///    caps a burn at `BURN_LIMIT` so this fits in a Worker's memory.
///  - HEAD does not consume. An unfurler, a link checker or a proxy prefetch
///    would otherwise spend the one read on nobody.
///  - a Range request is refused rather than served. Serving one without burning
///    would make `Range: bytes=0-` a way to read the whole file forever; burning
///    on a partial read would destroy the rest of a file nobody has yet seen.
///    Burns are images, which browsers fetch whole, so nothing legitimate asks.
///  - `no-store`, without which a shared cache goes on serving bytes this Worker
///    has already deleted, and the one guarantee the link makes is void.
///
/// Two readers arriving at once both get the bytes: the delete only starts after
/// the first has been read out. That is a race between two people who already
/// hold the same secret link, not a hole in it.
export async function serveOnce(
  bucket: R2Bucket,
  objectKey: string,
  request: Request,
  options: ServeOptions,
  consume: () => void,
): Promise<Response | null> {
  const { contentType, forceDownload } = servedTypeFor(options.ext);
  const headers = new Headers({
    "Content-Type": contentType,
    "Accept-Ranges": "none",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "X-Robots-Tag": "noindex, nofollow",
  });
  if (forceDownload || options.download) {
    headers.set(
      "Content-Disposition",
      `attachment; filename="${sanitizeFilename(options.filename)}"`,
    );
  }

  if (request.method === "HEAD") {
    const head = await bucket.head(objectKey);
    if (!head) return null;
    headers.set("Content-Length", String(head.size));
    return new Response(null, { status: 200, headers });
  }

  if (request.headers.get("Range") !== null) {
    return new Response("one-time links are served whole, not in ranges", {
      status: 416,
      headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" },
    });
  }

  const object = await bucket.get(objectKey);
  if (object === null) return null;

  const body = await object.arrayBuffer();
  consume();

  headers.set("Content-Length", String(body.byteLength));
  return new Response(body, { status: 200, headers });
}

/// A filename reaches this header from whatever the client sent at upload time.
/// A quote or a newline in it would let the uploader inject header fields.
function sanitizeFilename(name: string): string {
  return name.replace(/[^\w.\- ]+/g, "_").slice(0, 120) || "download";
}
