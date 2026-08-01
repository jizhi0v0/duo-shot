import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      // The Worker runs in workerd against a local R2 implementation, so the
      // whole suite is offline, deterministic and free.
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          UPLOAD_TOKEN: "test-token",
          PUBLIC_BASE: "https://s.test",
          // Fixed so the presign test signs against something stable. AWS's own
          // published example credentials -- not a real key.
          R2_ACCOUNT_ID: "accountid",
          R2_ACCESS_KEY_ID: "AKIAIOSFODNN7EXAMPLE",
          R2_SECRET_ACCESS_KEY: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
          R2_BUCKET_NAME: "duoshot",
        },
      },
    }),
  ],
});
