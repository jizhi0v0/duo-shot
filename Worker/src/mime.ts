/// Extension -> Content-Type, and nothing else is ever served inline.
///
/// This table is a security boundary, not a convenience. Serving an uploaded
/// file as `text/html` or `image/svg+xml` on your own origin is stored XSS
/// against every other link you have ever shared from this domain: the page
/// would run script with access to this origin. SVG is absent for exactly that
/// reason -- it is a document format that can carry `<script>`, not an image.
///
/// Anything not in this table is still served, but as an opaque download.
const INLINE_TYPES: Record<string, string> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  avif: "image/avif",
  heic: "image/heic", // stored and downloadable; browsers mostly will not render it
  mp4: "video/mp4",
  m4v: "video/mp4",
  webm: "video/webm",
  mov: "video/quicktime",
  m4a: "audio/mp4",
  mp3: "audio/mpeg",
  pdf: "application/pdf",
};

/// What a browser will actually display in a page or a chat unfurl. Narrower
/// than INLINE_TYPES: heic and pdf are perfectly safe to serve but there is no
/// point putting them in an <img>.
const RENDERABLE = new Set([
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
  "image/avif",
  "video/mp4",
  "video/webm",
  "video/quicktime",
]);

export interface Served {
  contentType: string;
  /// True when the response must carry `Content-Disposition: attachment`.
  forceDownload: boolean;
}

export function servedTypeFor(ext: string): Served {
  const type = INLINE_TYPES[ext.toLowerCase()];
  if (!type) return { contentType: "application/octet-stream", forceDownload: true };
  return { contentType: type, forceDownload: false };
}

export function isUploadableExtension(ext: string): boolean {
  return ext.toLowerCase() in INLINE_TYPES;
}

export function isRenderable(ext: string): boolean {
  const type = INLINE_TYPES[ext.toLowerCase()];
  return type !== undefined && RENDERABLE.has(type);
}

export function kindFor(ext: string): "image" | "video" | "file" {
  const type = INLINE_TYPES[ext.toLowerCase()];
  if (!type) return "file";
  if (type.startsWith("image/")) return "image";
  if (type.startsWith("video/")) return "video";
  return "file";
}
