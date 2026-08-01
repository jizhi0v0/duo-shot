import { isAuthorized } from "./auth";
import { isValidKey, metaKey, newKey, objectKeyFor, posterKeyFor } from "./keys";
import { isUploadableExtension, kindFor } from "./mime";
import { renderGone, renderPage } from "./page";
import { PresignUnavailable, presignPut } from "./presign";
import { serveObject } from "./serve";
import type { Env, ShareRecord } from "./types";

/// Above this, `PUT /api/put` refuses and tells the client to use the presigned
/// path instead. The platform's own request-body limit sits somewhere above
/// this and answers with an opaque failure; this one answers with a sentence
/// naming the route to use.
const DIRECT_PUT_LIMIT = 90 * 1024 * 1024;

const POSTER_LIMIT = 4 * 1024 * 1024;

/// Below this age, a record with no object is treated as "still uploading or
/// abandoned" rather than "expired". Generous on purpose -- a slow uplink and a
/// large recording can legitimately take a long time.
const INCOMPLETE_WINDOW_MS = 60 * 60 * 1000;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      // Never let a stack trace reach a public URL.
      console.error(error);
      return text(500, "internal error");
    }
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const segments = url.pathname.split("/").filter(Boolean);
  const [first, second] = segments;

  if (first === undefined) return text(404, "not found");
  if (first === "api") return api(request, env, segments.slice(1), url);

  const isRead = request.method === "GET" || request.method === "HEAD";

  // GET /f/<key>.<ext>  — the bytes
  if (first === "f" && segments.length === 2 && second !== undefined) {
    if (!isRead) return text(405, "method not allowed");
    return serveFile(request, env, second, false);
  }

  if (segments.length === 1 || (segments.length === 2 && second === "dl")) {
    if (!isRead) return text(405, "method not allowed");
    if (!isValidKey(first)) return text(404, "not found");
    // GET /<key>/dl — the same bytes, as a download
    if (second === "dl") {
      const record = await loadRecord(env, first);
      if (!record) return text(404, "not found");
      return serveObject(env.BUCKET, record.objectKey, request, {
        filename: record.name || `${first}.${record.ext}`,
        ext: record.ext,
        download: true,
      });
    }
    return servePage(env, first);
  }

  // No index, no listing, nothing that confirms this host is a file store.
  return text(404, "not found");
}

// MARK: - Authenticated API

async function api(request: Request, env: Env, segments: string[], url: URL): Promise<Response> {
  if (!isAuthorized(request, env)) {
    return json(401, { error: "unauthorized" }, { "WWW-Authenticate": "Bearer" });
  }

  const [action, argument] = segments;

  if (action === "new" && request.method === "POST") return apiNew(request, env);
  if (action === "put" && request.method === "PUT") return apiPut(request, env, url);
  if (action === "poster" && request.method === "PUT" && argument) {
    return apiPoster(request, env, argument);
  }
  if (action === "o" && request.method === "DELETE" && argument) {
    return apiDelete(env, argument);
  }
  if (action === "list" && request.method === "GET") return apiList(env, url);

  return json(404, { error: "no such endpoint" });
}

interface NewBody {
  ext?: string;
  name?: string;
  size?: number;
  ephemeral?: boolean;
  width?: number;
  height?: number;
  duration?: number;
}

/// Mints a key, writes the sidecar, and returns a URL the client can PUT the
/// bytes to directly. The bytes never come through here, which is the only
/// reason a 400 MB recording is uploadable at all.
async function apiNew(request: Request, env: Env): Promise<Response> {
  let body: NewBody;
  try {
    body = (await request.json()) as NewBody;
  } catch {
    return json(400, { error: "body must be JSON" });
  }

  const ext = normalizeExtension(body.ext);
  if (!ext) return json(400, { error: "unsupported or missing extension" });

  const record = await createRecord(env, {
    ext,
    name: body.name ?? "",
    size: typeof body.size === "number" ? body.size : null,
    ephemeral: body.ephemeral === true,
    width: body.width,
    height: body.height,
    duration: body.duration,
  });

  let uploadURL: string;
  try {
    uploadURL = await presignPut(env, record.objectKey);
  } catch (error) {
    if (error instanceof PresignUnavailable) {
      // The sidecar would otherwise be a permanent orphan pointing at bytes
      // that can never arrive.
      await env.BUCKET.delete(metaKey(record.key));
      return json(501, { error: error.message });
    }
    throw error;
  }

  return json(201, { ...links(env, record), uploadURL });
}

/// The one-request path, for anything small enough to pass through a Worker.
async function apiPut(request: Request, env: Env, url: URL): Promise<Response> {
  const ext = normalizeExtension(url.searchParams.get("ext"));
  if (!ext) return json(400, { error: "unsupported or missing ext" });

  // R2 needs to know how many bytes are coming; a chunked upload cannot be
  // streamed into it. Saying so here beats an opaque failure inside put().
  const declared = request.headers.get("Content-Length");
  if (declared === null) return json(411, { error: "Content-Length required" });
  const size = Number(declared);
  if (!Number.isFinite(size) || size <= 0) return json(400, { error: "bad Content-Length" });
  if (size > DIRECT_PUT_LIMIT) {
    return json(413, {
      error: `larger than ${DIRECT_PUT_LIMIT} bytes; use POST /api/new and PUT to the returned uploadURL`,
    });
  }
  if (!request.body) return json(400, { error: "empty body" });

  const record = await createRecord(env, {
    ext,
    name: url.searchParams.get("name") ?? "",
    size,
    ephemeral: url.searchParams.get("ephemeral") === "1",
    width: numberParam(url, "w"),
    height: numberParam(url, "h"),
    duration: numberParam(url, "d"),
  });

  await env.BUCKET.put(record.objectKey, request.body);
  return json(201, links(env, record));
}

/// A still for a video, so its link unfurls with a thumbnail. Always small, so
/// it always comes through the Worker.
async function apiPoster(request: Request, env: Env, key: string): Promise<Response> {
  if (!isValidKey(key)) return json(400, { error: "bad key" });
  const record = await loadRecord(env, key);
  if (!record) return json(404, { error: "no such key" });

  const size = Number(request.headers.get("Content-Length") ?? "0");
  if (!size || size > POSTER_LIMIT) return json(413, { error: "poster missing or too large" });
  if (!request.body) return json(400, { error: "empty body" });

  const posterKey = posterKeyFor(key);
  await env.BUCKET.put(posterKey, request.body);
  await saveRecord(env, { ...record, posterKey });
  return json(200, { posterURL: `${base(env)}/f/${key}.poster.jpg` });
}

async function apiDelete(env: Env, key: string): Promise<Response> {
  if (!isValidKey(key)) return json(400, { error: "bad key" });
  const record = await loadRecord(env, key);
  if (!record) return json(404, { error: "no such key" });

  // Sidecar last: if this is interrupted halfway, what survives is a record
  // whose object is gone, which serves a clean 410. The other order leaves
  // unreachable bytes paying rent forever.
  await env.BUCKET.delete(record.objectKey);
  if (record.posterKey) await env.BUCKET.delete(record.posterKey);
  await env.BUCKET.delete(metaKey(key));
  return json(200, { deleted: key });
}

/// Backs the app's "recent links" menu. Reads only the sidecars' custom
/// metadata, so listing 50 uploads is one operation rather than 50.
async function apiList(env: Env, url: URL): Promise<Response> {
  const limit = Math.min(Math.max(numberParam(url, "limit") ?? 25, 1), 200);
  const listed = await env.BUCKET.list({
    prefix: "m/",
    limit,
    include: ["customMetadata"],
  });

  const items = listed.objects
    .map((object) => {
      const key = object.key.slice(2);
      const custom = object.customMetadata ?? {};
      return {
        key,
        name: custom.name ?? "",
        ext: custom.ext ?? "",
        kind: custom.kind ?? "file",
        createdAt: custom.createdAt ?? object.uploaded.toISOString(),
        pageURL: `${base(env)}/${key}`,
        fileURL: custom.ext ? `${base(env)}/f/${key}.${custom.ext}` : null,
      };
    })
    .sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1));

  return json(200, { items, truncated: listed.truncated });
}

// MARK: - Public serving

async function serveFile(request: Request, env: Env, filename: string, download: boolean) {
  const dot = filename.indexOf(".");
  if (dot < 0) return text(404, "not found");
  const key = filename.slice(0, dot);
  const rest = filename.slice(dot + 1);
  if (!isValidKey(key)) return text(404, "not found");

  const record = await loadRecord(env, key);
  if (!record) return text(404, "not found");

  // `<key>.poster.jpg` is the video thumbnail, not the video.
  if (rest === "poster.jpg") {
    if (!record.posterKey) return text(404, "not found");
    return serveObject(env.BUCKET, record.posterKey, request, {
      filename: `${key}.jpg`,
      ext: "jpg",
      download: false,
    });
  }

  // The extension in the URL is not trusted to pick the Content-Type: the
  // record's is, and only through the allowlist. Otherwise `/f/<key>.html`
  // would be a way to have your own bytes served as a document on this origin.
  if (rest !== record.ext) return text(404, "not found");

  return serveObject(env.BUCKET, record.objectKey, request, {
    filename: record.name || `${key}.${record.ext}`,
    ext: record.ext,
    download,
  });
}

async function servePage(env: Env, key: string): Promise<Response> {
  const record = await loadRecord(env, key);
  if (!record) return text(404, "not found");

  // The sidecar outlives the object, and there are two very different reasons
  // for that: a lifecycle rule expired it, or the upload never finished -- a
  // quit mid-transfer leaves a record whose bytes are not coming.
  //
  // Age tells them apart well enough to say something true. What it must NOT do
  // is trigger a cleanup: an upload still in flight looks exactly like an
  // abandoned one, and deleting the sidecar under a large presigned upload would
  // break a link that was about to start working.
  const head = await env.BUCKET.head(record.objectKey);
  if (!head) {
    const age = Date.now() - Date.parse(record.createdAt);
    const unfinished = Number.isFinite(age) && age < INCOMPLETE_WINDOW_MS;
    return new Response(renderGone(key, unfinished), {
      // 404 rather than 410 while it could still be arriving: 410 means "was
      // here, is deliberately gone", which is a claim about the past that a
      // never-completed upload does not support.
      status: unfinished ? 404 : 410,
      headers: htmlHeaders(),
    });
  }

  return new Response(renderPage(record, base(env)), {
    status: 200,
    headers: htmlHeaders(),
  });
}

// MARK: - Records

interface RecordInput {
  ext: string;
  name: string;
  size: number | null;
  ephemeral: boolean;
  width?: number;
  height?: number;
  duration?: number;
}

async function createRecord(env: Env, input: RecordInput): Promise<ShareRecord> {
  const key = newKey();
  const record: ShareRecord = {
    key,
    objectKey: objectKeyFor(key, input.ephemeral),
    ext: input.ext,
    name: input.name.slice(0, 200),
    size: input.size,
    kind: kindFor(input.ext),
    width: input.width,
    height: input.height,
    duration: input.duration,
    createdAt: new Date().toISOString(),
    ephemeral: input.ephemeral,
  };
  await saveRecord(env, record);
  return record;
}

async function saveRecord(env: Env, record: ShareRecord): Promise<void> {
  await env.BUCKET.put(metaKey(record.key), JSON.stringify(record), {
    httpMetadata: { contentType: "application/json" },
    // Duplicated out of the body so `list` can render the recent-links menu
    // without a read per item.
    customMetadata: {
      name: record.name,
      ext: record.ext,
      kind: record.kind,
      createdAt: record.createdAt,
    },
  });
}

async function loadRecord(env: Env, key: string): Promise<ShareRecord | null> {
  if (!isValidKey(key)) return null;
  const object = await env.BUCKET.get(metaKey(key));
  if (!object) return null;
  try {
    return (await object.json()) as ShareRecord;
  } catch {
    return null;
  }
}

// MARK: - Small helpers

function normalizeExtension(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const ext = raw.replace(/^\./, "").toLowerCase();
  if (!/^[a-z0-9]{1,8}$/.test(ext)) return null;
  return isUploadableExtension(ext) ? ext : null;
}

function numberParam(url: URL, name: string): number | undefined {
  const raw = url.searchParams.get(name);
  if (raw === null) return undefined;
  const value = Number(raw);
  return Number.isFinite(value) ? value : undefined;
}

function base(env: Env): string {
  return env.PUBLIC_BASE.replace(/\/+$/, "");
}

function links(env: Env, record: ShareRecord) {
  return {
    key: record.key,
    pageURL: `${base(env)}/${record.key}`,
    fileURL: `${base(env)}/f/${record.key}.${record.ext}`,
  };
}

function htmlHeaders(): HeadersInit {
  return {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "public, max-age=300",
    "X-Content-Type-Options": "nosniff",
    "X-Robots-Tag": "noindex, nofollow",
    "Referrer-Policy": "no-referrer",
  };
}

function json(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...extra },
  });
}

function text(status: number, message: string): Response {
  return new Response(message, {
    status,
    headers: { "Content-Type": "text/plain; charset=utf-8", "X-Robots-Tag": "noindex, nofollow" },
  });
}

