const ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const KEY_LENGTH = 12;

/// 12 base62 characters, ~71 bits.
///
/// Screenshots routinely contain things their author would not publish, so the
/// only thing standing between a capture and the world is that nobody can guess
/// its key. Short enough to read out loud, long enough that enumeration is not
/// a strategy.
///
/// Rejection sampling rather than `% 62`: the modulo version biases the first
/// eight letters, and the next person to read this file should not have to
/// work out whether that mattered.
export function newKey(): string {
  let out = "";
  const buffer = new Uint8Array(KEY_LENGTH * 2);
  while (out.length < KEY_LENGTH) {
    crypto.getRandomValues(buffer);
    for (const byte of buffer) {
      if (byte >= 248) continue; // 248 = 62 * 4, the largest unbiased cut
      out += ALPHABET[byte % 62];
      if (out.length === KEY_LENGTH) break;
    }
  }
  return out;
}

const KEY_PATTERN = new RegExp(`^[0-9A-Za-z]{${KEY_LENGTH}}$`);

/// Every key that reaches an R2 path goes through here first. Without it a
/// request for `/f/../../m/abc.png` would be a path-traversal read of somebody
/// else's sidecar.
export function isValidKey(key: string): boolean {
  return KEY_PATTERN.test(key);
}

export function metaKey(key: string): string {
  return `m/${key}`;
}

export function objectKeyFor(key: string, ephemeral: boolean): string {
  // Two prefixes so a single R2 lifecycle rule on `e/` expires the ephemeral
  // ones. The sidecar records which was used, so serving never has to guess.
  return `${ephemeral ? "e" : "p"}/${key}`;
}

export function posterKeyFor(key: string): string {
  return `s/${key}`;
}
