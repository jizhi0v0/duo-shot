#!/usr/bin/env bash
#
# 把 R2 的 S3 凭据写进 Worker 的 secret。
#
# 这三个只有 POST /api/new 用得上 —— 也就是超过 90 MB 的录制。Worker 用它们签一个
# presigned PUT URL，客户端拿着直接把字节 PUT 进 R2，绕开 Worker 的请求体上限。
#
# 凭据从**交互式输入**读，不接受命令行参数：参数会进 shell 历史、进 ps 输出、
# 进任何人肩膀上的一瞥。输入时不回显，脚本自己也从不打印它们。
#
# 先去面板建 token：
#   R2 → API → Create API token → Object Read & Write → 只勾 duoshot 这一个桶
# 建完页面会给你 Access Key ID 和 Secret Access Key，各贴一次。
#
#   ./Scripts/set-r2-credentials.sh

set -euo pipefail
cd "$(dirname "$0")/.."

WORKER_NAME="duoshot-share"
WRANGLER="npx --no-install wrangler"

ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
if [ -z "$ACCOUNT_ID" ]; then
  ACCOUNT_ID="$($WRANGLER whoami 2>/dev/null | grep -oE '[0-9a-f]{32}' | head -1 || true)"
fi
[ -n "$ACCOUNT_ID" ] || { echo "取不到 account id；先跑 npx wrangler login" >&2; exit 1; }
echo "account: $ACCOUNT_ID"

printf 'Access Key ID: '
read -r ACCESS_KEY_ID
printf 'Secret Access Key（不回显）: '
read -rs SECRET_ACCESS_KEY
echo

[ -n "$ACCESS_KEY_ID" ] && [ -n "$SECRET_ACCESS_KEY" ] || { echo "两个都不能为空" >&2; exit 1; }

# Secret Access Key 是 API token 值的 SHA-256。粘错成 token 原文是最容易犯的错，
# 而它的症状是一个来自 R2 的 SignatureDoesNotMatch —— 出现在上传时，不是现在。
if [ ${#SECRET_ACCESS_KEY} -ne 64 ]; then
  echo
  echo "  注意：Secret Access Key 通常是 64 个十六进制字符，你贴的是 ${#SECRET_ACCESS_KEY} 个。"
  echo "  如果面板给的是「API token」原文而不是 Secret Access Key，它不是同一个东西。"
  printf '  仍然继续？[y/N] '
  read -r answer
  [ "$answer" = "y" ] || exit 1
fi

printf '%s' "$ACCOUNT_ID"         | $WRANGLER secret put R2_ACCOUNT_ID        --name "$WORKER_NAME"
printf '%s' "$ACCESS_KEY_ID"      | $WRANGLER secret put R2_ACCESS_KEY_ID     --name "$WORKER_NAME"
printf '%s' "$SECRET_ACCESS_KEY"  | $WRANGLER secret put R2_SECRET_ACCESS_KEY --name "$WORKER_NAME"

echo
echo "三个 secret 已写入。生效需要重新部署一次："
echo "  npx wrangler deploy"
echo
echo "然后验证大文件那条路（会真的传一个 120 MB 的文件再删掉）："
echo "  build/DuoShot.app/Contents/MacOS/DuoShot --selftest-share --configured --big 120"
