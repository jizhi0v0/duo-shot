#!/usr/bin/env bash
#
# 一次性把 duoshot-share 的 Cloudflare 侧建起来。
#
# 这个脚本会创建计费资源并改动你的 Cloudflare 账号，所以默认只打印计划。
# 确认无误后加 --yes 再跑一次。
#
#   ./Scripts/setup.sh --domain s.example.com
#   ./Scripts/setup.sh --domain s.example.com --yes
#
# 可以安全重跑：已经存在的 bucket、生命周期规则和 UPLOAD_TOKEN 都会跳过。
# 要换一个新的上传 token 就加 --rotate-token（老的立刻失效）。
#
# 新 token 写进 ~/.duoshot-upload-token（0600），**不打印到终端** —— 终端会被截屏，
# 而这个 app 的用户整天在截屏。要管道用就加 --print-token。
#
# 前置：域名已经在 Cloudflare（zone 已激活）。域名注册和改 NS 这两步没有 API
# 能替你做完 —— 注册商那边的 nameserver 必须人工改。

set -euo pipefail
cd "$(dirname "$0")/.."

DOMAIN=""
BUCKET="duoshot"
DEV_BUCKET="duoshot-dev"
EXPIRE_DAYS=30
WORKER_NAME="duoshot-share"
APPLY=false
ROTATE=false
PRINT_TOKEN=false
TOKEN_FILE="${TOKEN_FILE:-$HOME/.duoshot-upload-token}"

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --bucket) BUCKET="$2"; shift 2 ;;
    --dev-bucket) DEV_BUCKET="$2"; shift 2 ;;
    --expire-days) EXPIRE_DAYS="$2"; shift 2 ;;
    --yes|-y) APPLY=true; shift ;;
    --rotate-token) ROTATE=true; shift ;;
    --print-token) PRINT_TOKEN=true; shift ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$DOMAIN" ] || { echo "usage: $0 --domain s.example.com [--yes]" >&2; exit 2; }

WRANGLER="npx --no-install wrangler"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
step() { printf '  \033[2m$\033[0m %s\n' "$*"; }

# 每个会改动账号的命令都经过这里：不加 --yes 就只打印。
run() {
  step "$*"
  if $APPLY; then "$@"; fi
}

# --- 0. 身份 -----------------------------------------------------------------
# wrangler 认 OAuth（wrangler login）或 CLOUDFLARE_API_TOKEN 环境变量。CI 里用后者。
say "身份"
if ! $WRANGLER whoami >/tmp/duoshot-whoami.txt 2>&1; then
  echo "  未登录。先跑 'npx wrangler login'，或设置 CLOUDFLARE_API_TOKEN。" >&2
  exit 1
fi
sed 's/^/  /' /tmp/duoshot-whoami.txt | head -20
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-$(grep -oE '[0-9a-f]{32}' /tmp/duoshot-whoami.txt | head -1 || true)}"
[ -n "$ACCOUNT_ID" ] || { echo "  取不到 account id，手工设 CLOUDFLARE_ACCOUNT_ID" >&2; exit 1; }
echo "  account: $ACCOUNT_ID"

$APPLY || echo $'\n\033[33m--- 预演模式：下面的命令都不会执行。确认后加 --yes ---\033[0m'

# --- 1. Bucket ---------------------------------------------------------------
#
# 账号第一次用 R2 会在这里失败，错误码 10042。那不是脚本或凭据的问题:R2 是一个
# 需要在面板上走 checkout 的订阅,wrangler 没有对应命令,公开 API 也没有暴露这个
# 端点——这是整个 setup 里唯一必须人工点的一步(域名注册除外)。
create_bucket() {
  step "$WRANGLER r2 bucket create $1"
  $APPLY || return 0
  local output
  if output="$($WRANGLER r2 bucket create "$1" 2>&1)"; then
    return 0
  fi
  if printf '%s' "$output" | grep -q '10042'; then
    cat >&2 <<'EOF'

  这个账号还没开通 R2。

    面板 → Storage & databases → R2 → Overview → 走完 checkout
    https://dash.cloudflare.com/?to=/:account/r2

  免费额度内不产生费用，但通常要求账号上先有支付方式。开通后重跑本脚本。

  如果你确认已经订阅却仍然报 10042，那是另一个已知问题，面板按钮点了没反应，
  只能给 Cloudflare 开工单 —— 不是这里能修的。

  在此之前开发完全不受影响：测试和 wrangler dev 用的是本地模拟的 R2，
  不碰账号（make share-check 现在就能跑）。
EOF
    exit 1
  fi
  # 桶已存在是可以接受的:这个脚本要能重跑。
  if printf '%s' "$output" | grep -qi 'already exists'; then
    echo "  已存在，跳过"
    return 0
  fi
  printf '%s\n' "$output" >&2
  exit 1
}

say "R2 bucket"
create_bucket "$BUCKET"
create_bucket "$DEV_BUCKET"

# 注意这里没有 `r2 bucket domain add`,也没有 `dev-url enable`——是故意的。
#
# bucket 必须保持私有:所有读取都走 Worker,因为 Content-Type 白名单、noindex
# 和"过期显示 410"全都在 Worker 里。把 bucket 直接暴露在一个域名上,等于给
# 这三样开了一条绕过的路,其中 Content-Type 那条是安全边界——上传一个 .svg
# 就能在你自己的域名上执行脚本。

# --- 2. 生命周期规则:让 e/ 前缀的对象自己消失 --------------------------------
#
# 规则名重复会被 API 拒掉（10061），所以先看它在不在。这个脚本必须能重跑:
# 中途失败一次就再也跑不了的安装脚本，比没有安装脚本更糟。
say "生命周期规则（前缀 e/，$EXPIRE_DAYS 天后删除）"
if $APPLY && $WRANGLER r2 bucket lifecycle list "$BUCKET" 2>/dev/null | grep -q "duoshot-ephemeral"; then
  echo "  已存在，跳过"
else
  run $WRANGLER r2 bucket lifecycle add "$BUCKET" duoshot-ephemeral "e/" \
    --expire-days "$EXPIRE_DAYS" --force
fi

# --- 3. 把域名写进配置 -------------------------------------------------------
say "wrangler.jsonc"
if grep -q "s.example.com" wrangler.jsonc; then
  step "填入域名 $DOMAIN，并取消 routes 的注释"
  if $APPLY; then
    cp wrangler.jsonc wrangler.jsonc.bak
    # 取消注释这一步曾经产出过非法 JSON:routes 原本是注释,所以它上面那个块
    # 结尾没有逗号,一取消注释就变成 `}` 后面直接跟一个键。所以这里补逗号,
    # 并且改完立刻让 wrangler 自己解析一遍——配置坏掉必须当场报,而不是留给
    # 下一条命令去抛一个指向行号的解析错误。
    DOMAIN="$DOMAIN" python3 - <<'PY'
import os, pathlib, re

path = pathlib.Path("wrangler.jsonc")
lines = path.read_text().splitlines(keepends=True)
domain = os.environ["DOMAIN"]

out = []
for line in lines:
    line = line.replace("s.example.com", domain)
    out.append(re.sub(r'^(\s*)//\s*("routes")', r'\1\2', line))

routes = next((i for i, l in enumerate(out) if l.lstrip().startswith('"routes"')), None)
if routes is not None:
    for i in range(routes - 1, -1, -1):
        stripped = out[i].strip()
        if not stripped or stripped.startswith("//"):
            continue
        if stripped.endswith("}") or stripped.endswith("]"):
            out[i] = out[i].rstrip("\n") + ",\n"
        break

path.write_text("".join(out))
PY
    echo "  已改写（备份在 wrangler.jsonc.bak）"
    step "$WRANGLER deploy --dry-run  （只为确认配置仍然合法）"
    if ! $WRANGLER deploy --dry-run --outdir /tmp/duoshot-dryrun >/dev/null 2>&1; then
      echo "  改写后配置解析不过。已还原，请手工改：" >&2
      mv wrangler.jsonc.bak wrangler.jsonc
      $WRANGLER deploy --dry-run --outdir /tmp/duoshot-dryrun 2>&1 | tail -12 >&2
      exit 1
    fi
  fi
else
  echo "  已经不是占位符了，跳过"
fi

# --- 4. UPLOAD_TOKEN ---------------------------------------------------------
#
# 重跑时**不**换 token。secret 的值取不回来,所以一次静默轮换意味着已经配好的
# 客户端全部失效,而且没有任何提示——想换要明说。
say "UPLOAD_TOKEN"
if $APPLY && $WRANGLER secret list --name "$WORKER_NAME" 2>/dev/null | grep -q "UPLOAD_TOKEN"; then
  if $ROTATE; then
    echo "  已存在，--rotate-token 生效，替换中"
  else
    echo "  已存在，保持不变（要换加 --rotate-token）"
    SKIP_TOKEN=true
  fi
fi
if [ "${SKIP_TOKEN:-false}" != true ]; then
  step "openssl rand -base64 32 | wrangler secret put UPLOAD_TOKEN"
  if $APPLY; then
    UPLOAD_TOKEN="$(openssl rand -base64 32)"
    printf '%s' "$UPLOAD_TOKEN" | $WRANGLER secret put UPLOAD_TOKEN --name "$WORKER_NAME"

    # The token goes to a 0600 file, not to stdout.
    #
    # It used to be printed. That is exactly wrong for this app: its users take
    # screenshots for a living, and a terminal is the most-screenshotted window
    # they have. One did, the secret travelled into a chat log, and it had to be
    # rotated. A terminal's scrollback is not a secret store.
    #
    # --print-token is still there for a pipe, where nothing is on screen at all.
    if $PRINT_TOKEN; then
      printf '%s\n' "$UPLOAD_TOKEN"
    else
      ( umask 077; printf '%s\n' "$UPLOAD_TOKEN" > "$TOKEN_FILE" )
      printf '\n  \033[1mDuoShot 里要填的 token 已写入（未打印）：\033[0m\n  %s\n' "$TOKEN_FILE"
      printf '  粘进「设置 → Share → Upload token」之后删掉它：\n    rm %s\n' "$TOKEN_FILE"
    fi
  fi
fi

# --- 5. R2 的 S3 凭据 --------------------------------------------------------
#
# 只有 POST /api/new(大文件直传)需要。Access Key ID 是 API token 的 id,
# Secret Access Key 是 token value 的 SHA-256——这是 Cloudflare 文档写明的推导
# 方式,不是猜的。
#
# 需要一个有 "API Tokens Write" 权限的 token 放在 CF_API_TOKEN 里才能自动建。
# 没有就跳过,按最后打印的步骤去面板点。
say "R2 S3 凭据（大文件直传用）"
if [ -z "${CF_API_TOKEN:-}" ]; then
  echo "  CF_API_TOKEN 未设置，跳过自动创建。"
  echo "  面板路径：R2 → API → Create API token → Object Read & Write → 只勾 $BUCKET"
else
  API="https://api.cloudflare.com/client/v4"
  AUTH=(-H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")

  step "查 'Workers R2 Storage Bucket Item Write' 权限组 id"
  if $APPLY; then
    PG_ID="$(curl -sS "${AUTH[@]}" "$API/accounts/$ACCOUNT_ID/tokens/permission_groups" \
      | python3 -c 'import json,sys; print(next((g["id"] for g in json.load(sys.stdin)["result"] if g["name"]=="Workers R2 Storage Bucket Item Write"), ""))')"
    [ -n "$PG_ID" ] || { echo "  找不到该权限组，改用面板创建" >&2; exit 1; }

    # 资源标识符的拼法（com.cloudflare.edge.r2.bucket.<account>_<jurisdiction>_<bucket>）
    # 是本脚本里唯一没有实测过的一处。被拒的话按上面的面板路径手工建，
    # 不要退回账号级权限——那是把"只能碰这一个桶"悄悄换成"能碰所有桶"。
    step "创建按桶授权的 token"
    RESPONSE="$(curl -sS -X POST "${AUTH[@]}" "$API/accounts/$ACCOUNT_ID/tokens" -d "$(cat <<JSON
{"name":"duoshot-worker-r2",
 "policies":[{"effect":"allow",
   "permission_groups":[{"id":"$PG_ID"}],
   "resources":{"com.cloudflare.edge.r2.bucket.${ACCOUNT_ID}_default_${BUCKET}":"*"}}]}
JSON
)")"
    OK="$(printf '%s' "$RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["success"])')"
    if [ "$OK" != "True" ]; then
      printf '  创建失败，原样贴出响应：\n%s\n' "$RESPONSE" >&2
      exit 1
    fi
    TOKEN_ID="$(printf '%s' "$RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')"
    TOKEN_VALUE="$(printf '%s' "$RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["value"])')"
    SECRET="$(printf '%s' "$TOKEN_VALUE" | shasum -a 256 | cut -d' ' -f1)"

    printf '%s' "$ACCOUNT_ID"  | $WRANGLER secret put R2_ACCOUNT_ID        --name "$WORKER_NAME"
    printf '%s' "$TOKEN_ID"    | $WRANGLER secret put R2_ACCESS_KEY_ID     --name "$WORKER_NAME"
    printf '%s' "$SECRET"      | $WRANGLER secret put R2_SECRET_ACCESS_KEY --name "$WORKER_NAME"
    echo "  三个 secret 已写入"
  fi
fi

# --- 6. 部署 -----------------------------------------------------------------
#
# wrangler.jsonc 里的 routes + custom_domain 会在部署时自动建 DNS 记录并签证书,
# 所以域名这步不需要单独的命令。
say "部署"
run $WRANGLER deploy

say "完成"
if $APPLY; then
  cat <<EOF
  预览页  https://$DOMAIN/<key>
  裸文件  https://$DOMAIN/f/<key>.png

  自检一下（应该回 401）：
    curl -s -o /dev/null -w '%{http_code}\n' -X PUT "https://$DOMAIN/api/put?ext=png"
EOF
else
  echo "  以上都没有执行。确认后："
  echo "    $0 --domain $DOMAIN --yes"
fi
