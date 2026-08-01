import type { Env } from "./types";

/// Constant-time comparison.
///
/// Not written this way out of superstition: the token is compared on every
/// upload, an attacker can make as many attempts as they like, and a `===` on
/// strings returns as soon as it finds a differing byte. The cost of doing it
/// properly is four lines.
///
/// The length check leaks the token's length, which is not a secret.
function equals(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) {
    difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return difference === 0;
}

export function isAuthorized(request: Request, env: Env): boolean {
  // An unset secret must never mean "everything is allowed". A Worker deployed
  // without `wrangler secret put UPLOAD_TOKEN` should refuse every write, not
  // accept an empty Authorization header.
  if (!env.UPLOAD_TOKEN) return false;

  const header = request.headers.get("Authorization");
  if (!header || !header.startsWith("Bearer ")) return false;
  return equals(header.slice("Bearer ".length), env.UPLOAD_TOKEN);
}
