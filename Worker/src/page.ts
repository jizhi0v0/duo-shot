import type { ShareRecord } from "./types";
import { isRenderable, kindFor, servedTypeFor } from "./mime";

/// Every interpolated value below is attacker-controlled in the sense that
/// matters: it came from an upload. One missing call here and a filename is a
/// script tag on your own origin.
function escape(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function formatBytes(size: number | null): string {
  if (size === null) return "";
  if (size < 1024) return `${size} B`;
  const units = ["KB", "MB", "GB"];
  let value = size / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`;
}

/// A record written before these fields were validated can hold anything, and
/// the two callers below interpolate the result without escaping it.
function positive(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : null;
}

function formatDuration(seconds: unknown): string {
  const value = positive(seconds);
  if (value === null) return "";
  const total = Math.round(value);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}

export function renderPage(record: ShareRecord, base: string): string {
  const fileURL = `${base}/f/${record.key}.${record.ext}`;
  const downloadURL = `${base}/${record.key}/dl`;
  const kind = kindFor(record.ext);
  const { contentType } = servedTypeFor(record.ext);
  const title = escape(record.name || `${record.key}.${record.ext}`);

  // A one-time link gets no preview of any kind, and that is the whole design
  // rather than an omission: an og:image is fetched by the unfurler in whatever
  // chat app the link was pasted into, which would spend the single read on a
  // bot before the recipient had clicked anything.
  const previewImage = record.burn
    ? null
    : // og:image is what actually produces a thumbnail in chat apps. For a video
      // that has to be the poster still -- no unfurler decodes a frame for you.
      kind === "image" && isRenderable(record.ext)
      ? fileURL
      : record.posterKey
        ? `${base}/f/${record.key}.poster.jpg`
        : null;

  const meta: string[] = [
    `<meta property="og:title" content="${title}">`,
    `<meta property="og:url" content="${base}/${record.key}">`,
    `<meta name="robots" content="noindex, nofollow">`,
  ];
  if (previewImage) {
    meta.push(`<meta property="og:image" content="${previewImage}">`);
    meta.push(`<meta name="twitter:card" content="summary_large_image">`);
    meta.push(`<meta name="twitter:image" content="${previewImage}">`);
  }
  if (kind === "video") {
    meta.push(`<meta property="og:type" content="video.other">`);
    meta.push(`<meta property="og:video" content="${fileURL}">`);
    meta.push(`<meta property="og:video:secure_url" content="${fileURL}">`);
    meta.push(`<meta property="og:video:type" content="${contentType}">`);
  } else {
    meta.push(`<meta property="og:type" content="website">`);
  }
  const width = positive(record.width);
  const height = positive(record.height);
  if (width !== null && height !== null && !record.burn) {
    const dimensionPrefix = kind === "video" ? "og:video" : "og:image";
    meta.push(`<meta property="${dimensionPrefix}:width" content="${width}">`);
    meta.push(`<meta property="${dimensionPrefix}:height" content="${height}">`);
  }

  let body: string;
  if (record.burn) {
    // No <img>: rendering the file here would spend the read on whoever loaded
    // the page, including the recipient who only wanted to see what they had
    // been sent. The read has to be something a person chooses.
    body = `<div class="once">
<h1>This link opens once</h1>
<p>Opening the file deletes it. The link will not work a second time, for you or
for anyone else it was forwarded to.</p>
<a class="go" href="${fileURL}">Open ${title}</a>
</div>`;
  } else if (kind === "image" && isRenderable(record.ext)) {
    body = `<img src="${fileURL}" alt="${title}">`;
  } else if (kind === "video") {
    const poster = record.posterKey ? ` poster="${base}/f/${record.key}.poster.jpg"` : "";
    body = `<video src="${fileURL}"${poster} controls playsinline preload="metadata"></video>`;
  } else {
    body = `<p class="plain">${title}</p>`;
  }

  const facts = [
    width !== null && height !== null ? `${width}×${height}` : "",
    formatDuration(record.duration),
    formatBytes(record.size),
  ].filter(Boolean);

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
${meta.join("\n")}
<style>
:root { color-scheme: light dark; --bg:#f5f5f7; --fg:#1d1d1f; --dim:#6e6e73; --card:#fff; --line:#0000001a; }
@media (prefers-color-scheme: dark) { :root { --bg:#000; --fg:#f5f5f7; --dim:#8e8e93; --card:#1c1c1e; --line:#ffffff1a; } }
* { box-sizing: border-box; }
body { margin:0; min-height:100vh; display:flex; flex-direction:column; align-items:center;
  justify-content:center; gap:14px; padding:24px; background:var(--bg); color:var(--fg);
  font:14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
img, video { max-width:min(100%, 1400px); max-height:82vh; border-radius:10px;
  background:var(--card); box-shadow:0 1px 3px #0000001f, 0 8px 28px #00000014; }
.plain { padding:48px 32px; background:var(--card); border-radius:10px; }
.once { max-width:34em; padding:32px; background:var(--card); border-radius:10px; text-align:center; }
.once h1 { font-size:19px; margin:0 0 10px; }
.once p { color:var(--dim); margin:0 0 20px; }
.once .go { display:inline-block; padding:9px 18px; font-weight:600; }
footer { display:flex; align-items:center; gap:14px; color:var(--dim); flex-wrap:wrap; justify-content:center; }
a { color:inherit; text-decoration:none; border:1px solid var(--line); padding:5px 12px; border-radius:7px; }
a:hover { background:var(--card); }
</style>
</head>
<body>
${body}
<footer>
<span>${facts.join(" · ")}</span>
${record.burn ? "" : `<a href="${downloadURL}" download>Download</a>`}
</footer>
</body>
</html>`;
}

/// Why there are no bytes behind a link that once had a record.
///
/// Three cases and not one page, because the recipient's next move differs: an
/// unfinished upload is worth reloading, an expired one is worth asking for
/// again, and a used one-time link is worth knowing was *used* -- telling them
/// it expired would have them wait for a link that is never coming back, and
/// would hide that somebody has already opened it.
export type GoneReason = "expired" | "unfinished" | "burned";

const GONE_TEXT: Record<GoneReason, { title: string; heading: string; detail: string }> = {
  expired: { title: "Expired", heading: "This link has expired", detail: "" },
  unfinished: {
    title: "Not here",
    heading: "Nothing here yet",
    detail: "The upload is still running, or it did not finish.",
  },
  burned: {
    title: "Viewed",
    heading: "This one-time link has been viewed",
    detail: "It was set to open once. The file was deleted when it was opened, "
      + "and no copy of it is left here.",
  },
};

export function renderGone(key: string, reason: GoneReason = "expired"): string {
  const { title, heading, detail } = GONE_TEXT[reason];
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>${title}</title>
<style>
:root { color-scheme: light dark; }
body { margin:0; min-height:100vh; display:flex; flex-direction:column; align-items:center;
  justify-content:center; gap:8px; padding:24px; text-align:center;
  font:14px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
p { color:#6e6e73; margin:0; max-width:32em; }
</style>
</head>
<body>
<h1>${heading}</h1>
<p>${detail || escape(key)}</p>
</body>
</html>`;
}
