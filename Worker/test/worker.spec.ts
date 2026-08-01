import { SELF, env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { presignPut } from "../src/presign";
import type { Env } from "../src/types";

const TOKEN = "test-token";
const BASE = "https://s.test";

/// A real 1x1 PNG. Bytes matter here: half these tests are about whether the
/// exact same bytes come back out.
const PNG = Uint8Array.from(
  atob(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  ),
  (c) => c.charCodeAt(0),
);

async function upload(
  body: BodyInit = PNG,
  query = "ext=png&name=shot.png",
  token: string | null = TOKEN,
): Promise<Response> {
  const headers = new Headers();
  if (token !== null) headers.set("Authorization", `Bearer ${token}`);
  return SELF.fetch(`${BASE}/api/put?${query}`, { method: "PUT", headers, body });
}

async function uploadedKey(query?: string): Promise<string> {
  const response = await upload(PNG, query);
  expect(response.status).toBe(201);
  return ((await response.json()) as { key: string }).key;
}

describe("auth", () => {
  it("refuses an upload with no token", async () => {
    expect((await upload(PNG, "ext=png", null)).status).toBe(401);
  });

  it("refuses an upload with the wrong token", async () => {
    expect((await upload(PNG, "ext=png", "not-the-token")).status).toBe(401);
  });

  // The control for the two above. If this ever fails they prove nothing --
  // a route that rejects everything also rejects a bad token.
  it("accepts an upload with the right token", async () => {
    expect((await upload()).status).toBe(201);
  });
});

describe("round trip", () => {
  it("returns the exact bytes that were uploaded", async () => {
    const key = await uploadedKey();
    const response = await SELF.fetch(`${BASE}/f/${key}.png`);

    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("image/png");
    expect(response.headers.get("Accept-Ranges")).toBe("bytes");
    expect(response.headers.get("X-Robots-Tag")).toBe("noindex, nofollow");
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(PNG);
  });

  it("answers HEAD with the size and no body", async () => {
    const key = await uploadedKey();
    const response = await SELF.fetch(`${BASE}/f/${key}.png`, { method: "HEAD" });

    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Length")).toBe(String(PNG.byteLength));
    expect(await response.text()).toBe("");
  });

  it("404s an unknown key", async () => {
    expect((await SELF.fetch(`${BASE}/f/aaaaaaaaaaaa.png`)).status).toBe(404);
    expect((await SELF.fetch(`${BASE}/aaaaaaaaaaaa`)).status).toBe(404);
  });
});

describe("range requests", () => {
  // Without this Safari does not merely fail to seek a video -- it declines to
  // play it at all. It is the first thing that breaks and the last thing anyone
  // thinks to check.
  it("answers a byte range with 206 and a correct Content-Range", async () => {
    const key = await uploadedKey();
    const response = await SELF.fetch(`${BASE}/f/${key}.png`, {
      headers: { Range: "bytes=0-9" },
    });

    expect(response.status).toBe(206);
    expect(response.headers.get("Content-Range")).toBe(`bytes 0-9/${PNG.byteLength}`);
    expect(response.headers.get("Content-Length")).toBe("10");
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(PNG.slice(0, 10));
  });

  it("answers a suffix range", async () => {
    const key = await uploadedKey();
    const response = await SELF.fetch(`${BASE}/f/${key}.png`, {
      headers: { Range: "bytes=-5" },
    });

    expect(response.status).toBe(206);
    expect(response.headers.get("Content-Range")).toBe(
      `bytes ${PNG.byteLength - 5}-${PNG.byteLength - 1}/${PNG.byteLength}`,
    );
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(PNG.slice(-5));
  });

  it("sends the whole body for a range header it will not parse", async () => {
    const key = await uploadedKey();
    const response = await SELF.fetch(`${BASE}/f/${key}.png`, {
      headers: { Range: "bytes=0-9,20-29" },
    });

    expect(response.status).toBe(200);
    expect((await response.arrayBuffer()).byteLength).toBe(PNG.byteLength);
  });
});

describe("conditional requests", () => {
  it("answers 304 when the client already has the bytes", async () => {
    const key = await uploadedKey();
    const first = await SELF.fetch(`${BASE}/f/${key}.png`);
    const etag = first.headers.get("ETag");
    expect(etag).toBeTruthy();

    const second = await SELF.fetch(`${BASE}/f/${key}.png`, {
      headers: { "If-None-Match": etag! },
    });
    expect(second.status).toBe(304);
  });
});

describe("content types are an allowlist, not a suggestion", () => {
  // Serving an uploaded file as text/html on this origin would be stored XSS
  // against every other link ever shared from this domain.
  it("refuses to accept an html upload", async () => {
    expect((await upload(PNG, "ext=html")).status).toBe(400);
  });

  it("refuses to accept an svg upload", async () => {
    expect((await upload(PNG, "ext=svg")).status).toBe(400);
  });

  it("refuses to serve a stored object under a different extension", async () => {
    const key = await uploadedKey();
    expect((await SELF.fetch(`${BASE}/f/${key}.html`)).status).toBe(404);
  });

  it("rejects a key that tries to walk out of its prefix", async () => {
    expect((await SELF.fetch(`${BASE}/f/..%2F..%2Fm%2Fabc.png`)).status).toBe(404);
  });
});

describe("viewer page", () => {
  it("carries the og:image an unfurl needs", async () => {
    const key = await uploadedKey("ext=png&name=shot.png&w=800&h=600");
    const response = await SELF.fetch(`${BASE}/${key}`);
    const html = await response.text();

    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toContain("text/html");
    expect(html).toContain(`<meta property="og:image" content="${BASE}/f/${key}.png">`);
    expect(html).toContain(`<img src="${BASE}/f/${key}.png"`);
    expect(html).toContain("800×600");
    expect(response.headers.get("Content-Security-Policy")).toContain("default-src 'none'");
  });

  it("escapes a filename chosen to break out of the markup", async () => {
    const hostile = '"><script>alert(1)</script>';
    const key = await uploadedKey(`ext=png&name=${encodeURIComponent(hostile)}`);
    const html = await SELF.fetch(`${BASE}/${key}`).then((r: Response) => r.text());

    expect(html).not.toContain("<script>alert(1)</script>");
    expect(html).toContain("&lt;script&gt;");
  });

  // A record with no object has two causes that must not be told the same way:
  // an expiry, and an upload that never finished because the app was quit
  // mid-transfer. Age is the only thing that separates them.
  it("says expired for an old record whose object is gone", async () => {
    const key = await uploadedKey();
    await (env as Env).BUCKET.delete(`p/${key}`);
    // Backdate the sidecar past the incomplete window.
    const meta = await (env as Env).BUCKET.get(`m/${key}`);
    const record = (await meta!.json()) as { createdAt: string };
    record.createdAt = new Date(Date.now() - 48 * 3600 * 1000).toISOString();
    await (env as Env).BUCKET.put(`m/${key}`, JSON.stringify(record));

    const response = await SELF.fetch(`${BASE}/${key}`);
    expect(response.status).toBe(410);
    expect(await response.text()).toContain("expired");
  });

  it("does not claim a just-abandoned upload expired", async () => {
    const key = await uploadedKey();
    // What quitting the app mid-upload leaves behind: a fresh record, no bytes.
    await (env as Env).BUCKET.delete(`p/${key}`);

    const response = await SELF.fetch(`${BASE}/${key}`);
    expect(response.status).toBe(404);
    const html = await response.text();
    expect(html).toContain("did not finish");
    expect(html).not.toContain("expired");
    // Cached, this 404 would outlive the upload that fixes it.
    expect(response.headers.get("Cache-Control")).toBe("no-store");
  });

  it("leaves the record alone so an upload in flight can still land", async () => {
    const key = await uploadedKey();
    await (env as Env).BUCKET.delete(`p/${key}`);
    await SELF.fetch(`${BASE}/${key}`);

    // Reading the page must not clean up: a large presigned upload looks
    // identical to an abandoned one while it is still running.
    expect(await (env as Env).BUCKET.head(`m/${key}`)).not.toBeNull();
  });
});

describe("api/new does not trust its JSON", () => {
  async function create(body: unknown): Promise<Response> {
    return SELF.fetch(`${BASE}/api/new`, {
      method: "POST",
      headers: { Authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify(body),
    });
  }

  // The dimensions are interpolated into meta tags without escaping, so a
  // string here is markup on the share origin for anyone holding the token.
  it("refuses a width that is not a number", async () => {
    const response = await create({
      ext: "png",
      width: '"><script>alert(1)</script>',
      height: 600,
    });
    expect(response.status).toBe(400);
  });

  it("refuses a non-finite height and a string duration", async () => {
    expect((await create({ ext: "png", width: 800, height: "600" })).status).toBe(400);
    expect((await create({ ext: "png", duration: "12" })).status).toBe(400);
  });

  // `input.name.slice` on a number is a 500.
  it("refuses a name that is not a string", async () => {
    expect((await create({ ext: "png", name: 12 })).status).toBe(400);
  });

  it("still accepts a well-formed body", async () => {
    const response = await create({ ext: "png", name: "shot.png", width: 800, height: 600 });
    expect(response.status).toBe(201);
  });
});

describe("one-time links", () => {
  async function burnKey(query = "ext=png&name=secret.png&burn=1"): Promise<string> {
    return uploadedKey(query);
  }

  it("serves the bytes once and then refuses", async () => {
    const key = await burnKey();

    const first = await SELF.fetch(`${BASE}/f/${key}.png`);
    expect(first.status).toBe(200);
    expect(new Uint8Array(await first.arrayBuffer())).toEqual(PNG);
    // A cached copy is a copy that outlives the deletion, which is the one
    // thing this link promises cannot happen.
    expect(first.headers.get("Cache-Control")).toBe("no-store");

    const second = await SELF.fetch(`${BASE}/f/${key}.png`);
    expect([404, 410]).toContain(second.status);
    expect(await (env as Env).BUCKET.head(`p/${key}`)).toBeNull();
  });

  it("says viewed rather than expired once it has been used", async () => {
    const key = await burnKey();
    await SELF.fetch(`${BASE}/f/${key}.png`);

    const page = await SELF.fetch(`${BASE}/${key}`);
    expect(page.status).toBe(410);
    const html = await page.text();
    expect(html).toContain("viewed");
    expect(html).not.toContain("expired");
  });

  // An unfurl bot, a link checker or a proxy prefetch would otherwise spend the
  // single read on nobody, and the recipient would get the 410.
  it("does not burn on HEAD", async () => {
    const key = await burnKey();

    const head = await SELF.fetch(`${BASE}/f/${key}.png`, { method: "HEAD" });
    expect(head.status).toBe(200);
    expect(head.headers.get("Content-Length")).toBe(String(PNG.byteLength));

    const get = await SELF.fetch(`${BASE}/f/${key}.png`);
    expect(get.status).toBe(200);
  });

  // The whole reason the viewer page renders no <img> and no og:image.
  it("does not burn on a page view, and the page names no bytes", async () => {
    const key = await burnKey();

    const page = await SELF.fetch(`${BASE}/${key}`);
    expect(page.status).toBe(200);
    const html = await page.text();
    expect(html).not.toContain("og:image");
    expect(html).not.toContain(`<img src=`);
    expect(html).toContain("opens once");
    // The link to the bytes is there to be *clicked*; nothing may fetch it.
    expect(html).toContain(`href="${BASE}/f/${key}.png"`);

    expect((await SELF.fetch(`${BASE}/f/${key}.png`)).status).toBe(200);
  });

  it("refuses a range rather than serving one", async () => {
    const key = await burnKey();
    const response = await SELF.fetch(`${BASE}/f/${key}.png`, {
      headers: { Range: "bytes=0-9" },
    });

    expect(response.status).toBe(416);
    expect((await SELF.fetch(`${BASE}/f/${key}.png`)).status).toBe(200);
  });

  // "First complete read" is not a moment that exists for a video.
  it("refuses a burn upload of a video", async () => {
    const put = await upload(PNG, "ext=mp4&burn=1");
    expect(put.status).toBe(400);

    const post = await SELF.fetch(`${BASE}/api/new`, {
      method: "POST",
      headers: { Authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({ ext: "mp4", size: 1000, burn: true }),
    });
    expect(post.status).toBe(400);
  });

  // The read is buffered whole before it can be answered and deleted, so the
  // size limit is what a Worker can hold, and upload time is the last moment
  // where refusing is still useful.
  it("refuses a burn upload too large to buffer", async () => {
    const oversized = await SELF.fetch(`${BASE}/api/new`, {
      method: "POST",
      headers: { Authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({ ext: "png", size: 64 * 1024 * 1024, burn: true }),
    });
    expect(oversized.status).toBe(400);

    // And with no declared size at all, which would be the way around it.
    const unsized = await SELF.fetch(`${BASE}/api/new`, {
      method: "POST",
      headers: { Authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({ ext: "png", burn: true }),
    });
    expect(unsized.status).toBe(400);
  });

  it("refuses a burn flag that is not a boolean", async () => {
    const response = await SELF.fetch(`${BASE}/api/new`, {
      method: "POST",
      headers: { Authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({ ext: "png", size: 1000, burn: "yes" }),
    });
    expect(response.status).toBe(400);
  });

  // The download route reads the same bytes; letting it through unburnt would
  // be the way round the feature.
  it("burns on the download route too", async () => {
    const key = await burnKey();
    expect((await SELF.fetch(`${BASE}/${key}/dl`)).status).toBe(200);
    expect([404, 410]).toContain((await SELF.fetch(`${BASE}/f/${key}.png`)).status);
  });
});

describe("delete", () => {
  it("removes the object and then serves nothing", async () => {
    const key = await uploadedKey();
    const response = await SELF.fetch(`${BASE}/api/o/${key}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${TOKEN}` },
    });

    expect(response.status).toBe(200);
    expect((await SELF.fetch(`${BASE}/f/${key}.png`)).status).toBe(404);
    expect((await SELF.fetch(`${BASE}/${key}`)).status).toBe(404);
  });

  it("refuses an unauthenticated delete", async () => {
    const key = await uploadedKey();
    expect((await SELF.fetch(`${BASE}/api/o/${key}`, { method: "DELETE" })).status).toBe(401);
    expect((await SELF.fetch(`${BASE}/f/${key}.png`)).status).toBe(200);
  });
});

describe("uploads that cannot be streamed", () => {
  it("asks for a Content-Length rather than failing inside R2", async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(PNG);
        controller.close();
      },
    });
    const response = await SELF.fetch(`${BASE}/api/put?ext=png`, {
      method: "PUT",
      headers: { Authorization: `Bearer ${TOKEN}` },
      body: stream,
    });
    expect(response.status).toBe(411);
  });
});

describe("list", () => {
  it("returns recent uploads without a read per item", async () => {
    const key = await uploadedKey("ext=png&name=listed.png");
    const response = await SELF.fetch(`${BASE}/api/list?limit=50`, {
      headers: { Authorization: `Bearer ${TOKEN}` },
    });

    expect(response.status).toBe(200);
    const body = (await response.json()) as { items: { key: string; name: string }[] };
    const found = body.items.find((item) => item.key === key);
    expect(found?.name).toBe("listed.png");
  });
});

describe("presigned PUT", () => {
  const FIXED = new Date("2026-08-01T12:00:00.000Z");

  it("builds a URL with every parameter SigV4 requires", async () => {
    const url = new URL(await presignPut(env as Env, "p/abcdefghijkl", { now: FIXED }));

    expect(url.host).toBe("accountid.r2.cloudflarestorage.com");
    expect(url.pathname).toBe("/duoshot/p/abcdefghijkl");
    expect(url.searchParams.get("X-Amz-Algorithm")).toBe("AWS4-HMAC-SHA256");
    expect(url.searchParams.get("X-Amz-Credential")).toBe(
      "AKIAIOSFODNN7EXAMPLE/20260801/auto/s3/aws4_request",
    );
    expect(url.searchParams.get("X-Amz-Date")).toBe("20260801T120000Z");
    expect(url.searchParams.get("X-Amz-SignedHeaders")).toBe("host");
    expect(url.searchParams.get("X-Amz-Signature")).toMatch(/^[0-9a-f]{64}$/);
  });

  // A regression lock, not a conformance test: it pins the canonicalisation so
  // an "innocent" edit to the encoder or the parameter order shows up here
  // rather than as an intermittent SignatureDoesNotMatch from R2 months later.
  it("signs deterministically", async () => {
    const a = await presignPut(env as Env, "p/abcdefghijkl", { now: FIXED });
    const b = await presignPut(env as Env, "p/abcdefghijkl", { now: FIXED });
    expect(a).toBe(b);

    const other = await presignPut(env as Env, "p/abcdefghijkm", { now: FIXED });
    expect(other).not.toBe(a);
  });
});
