import type { Env } from "./types";

/// AWS Signature Version 4, query-string form, for R2's S3-compatible endpoint.
///
/// This exists for one reason: a Worker's *request body* is capped, and a screen
/// recording is not small. Handing the client a URL it can PUT to directly means
/// the bytes never traverse this Worker, so no cap applies -- and the client
/// still holds nothing but the bearer token, because the signing happens here.
///
/// Written from the published SigV4 rules rather than pulled from a library:
/// it is ~80 lines, and a dependency here would have to be audited on every
/// bump for something that is allowed to mint write URLs into the bucket.

const ALGORITHM = "AWS4-HMAC-SHA256";
const REGION = "auto"; // R2 has exactly one
const SERVICE = "s3";

export class PresignUnavailable extends Error {}

/// RFC 3986. `encodeURIComponent` leaves five characters unescaped that the
/// canonical request requires to be escaped; getting this wrong produces a
/// signature mismatch only for filenames containing them, which is the kind of
/// bug that shows up months later on one file.
function encodeSegment(value: string): string {
  return encodeURIComponent(value).replace(
    /[!'()*]/g,
    (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

function hex(buffer: ArrayBuffer): string {
  return [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(input: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input)));
}

async function hmac(key: ArrayBuffer | Uint8Array, message: string): Promise<ArrayBuffer> {
  const imported = await crypto.subtle.importKey(
    "raw",
    key as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return crypto.subtle.sign("HMAC", imported, new TextEncoder().encode(message));
}

export interface PresignOptions {
  /// Injectable so the signature is a fixed value in tests rather than
  /// something that changes every second.
  now?: Date;
  expiresIn?: number;
}

export async function presignPut(
  env: Env,
  objectKey: string,
  options: PresignOptions = {},
): Promise<string> {
  const { R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_NAME } = env;
  if (!R2_ACCOUNT_ID || !R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY || !R2_BUCKET_NAME) {
    throw new PresignUnavailable("R2 S3 credentials are not configured on this Worker");
  }

  const now = options.now ?? new Date();
  const expiresIn = options.expiresIn ?? 900;

  const amzDate = now.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const dateStamp = amzDate.slice(0, 8);
  const scope = `${dateStamp}/${REGION}/${SERVICE}/aws4_request`;

  const host = `${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
  const path = `/${encodeSegment(R2_BUCKET_NAME)}/${objectKey.split("/").map(encodeSegment).join("/")}`;

  // Already in the byte order the canonical request requires; kept explicit so
  // a future addition cannot silently land out of order.
  const query: [string, string][] = [
    ["X-Amz-Algorithm", ALGORITHM],
    ["X-Amz-Credential", `${R2_ACCESS_KEY_ID}/${scope}`],
    ["X-Amz-Date", amzDate],
    ["X-Amz-Expires", String(expiresIn)],
    ["X-Amz-SignedHeaders", "host"],
  ];
  query.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  const canonicalQuery = query
    .map(([k, v]) => `${encodeSegment(k)}=${encodeSegment(v)}`)
    .join("&");

  const canonicalRequest = [
    "PUT",
    path,
    canonicalQuery,
    `host:${host}\n`,
    "host",
    // The whole point of the presigned form: the signature cannot cover a body
    // that does not exist yet.
    "UNSIGNED-PAYLOAD",
  ].join("\n");

  const stringToSign = [ALGORITHM, amzDate, scope, await sha256Hex(canonicalRequest)].join("\n");

  const kDate = await hmac(new TextEncoder().encode(`AWS4${R2_SECRET_ACCESS_KEY}`), dateStamp);
  const kRegion = await hmac(kDate, REGION);
  const kService = await hmac(kRegion, SERVICE);
  const kSigning = await hmac(kService, "aws4_request");
  const signature = hex(await hmac(kSigning, stringToSign));

  return `https://${host}${path}?${canonicalQuery}&X-Amz-Signature=${signature}`;
}
