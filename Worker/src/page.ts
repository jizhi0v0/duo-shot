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

function formatDuration(seconds: number | undefined): string {
  if (seconds === undefined) return "";
  const total = Math.round(seconds);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}

export function renderPage(record: ShareRecord, base: string): string {
  const fileURL = `${base}/f/${record.key}.${record.ext}`;
  const downloadURL = `${base}/${record.key}/dl`;
  const kind = kindFor(record.ext);
  const { contentType } = servedTypeFor(record.ext);
  const title = escape(record.name || `${record.key}.${record.ext}`);

  // og:image is what actually produces a thumbnail in chat apps. For a video
  // that has to be the poster still -- no unfurler decodes a frame for you.
  const previewImage =
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
  if (record.width && record.height) {
    const dimensionPrefix = kind === "video" ? "og:video" : "og:image";
    meta.push(`<meta property="${dimensionPrefix}:width" content="${record.width}">`);
    meta.push(`<meta property="${dimensionPrefix}:height" content="${record.height}">`);
  }

  let body: string;
  if (kind === "image" && isRenderable(record.ext)) {
    body = `<img src="${fileURL}" alt="${title}">`;
  } else if (kind === "video") {
    const poster = record.posterKey ? ` poster="${base}/f/${record.key}.poster.jpg"` : "";
    body = `<video src="${fileURL}"${poster} controls playsinline preload="metadata"></video>`;
  } else {
    body = `<p class="plain">${title}</p>`;
  }

  const facts = [
    record.width && record.height ? `${record.width}×${record.height}` : "",
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
footer { display:flex; align-items:center; gap:14px; color:var(--dim); flex-wrap:wrap; justify-content:center; }
a { color:inherit; text-decoration:none; border:1px solid var(--line); padding:5px 12px; border-radius:7px; }
a:hover { background:var(--card); }
</style>
</head>
<body>
${body}
<footer>
<span>${facts.join(" · ")}</span>
<a href="${downloadURL}" download>Download</a>
</footer>
</body>
</html>`;
}

export function renderGone(key: string, unfinished = false): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>${unfinished ? "Not here" : "Expired"}</title>
<style>
:root { color-scheme: light dark; }
body { margin:0; min-height:100vh; display:flex; flex-direction:column; align-items:center;
  justify-content:center; gap:8px;
  font:14px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
p { color:#6e6e73; margin:0; }
</style>
</head>
<body>
<h1>${unfinished ? "Nothing here yet" : "This link has expired"}</h1>
<p>${unfinished
  ? "The upload is still running, or it did not finish."
  : escape(key)}</p>
</body>
</html>`;
}
