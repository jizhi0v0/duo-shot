# duoshot-share

DuoShot 的分享后端：一个 Cloudflare Worker + 一个 R2 bucket。

从零实现，没有引用任何第三方项目的代码，运行时零依赖（签名用 Web Crypto 手写）—— 这样这个仓库将来公开或分发都不受别人的许可证约束。

## 它做什么

上传截图/录制，拿回一个自有域名下的短链接。链接有两种形态：

- `https://s.example.com/a7Kd9xQ2mZ01` —— 给人看的预览页，带 OG meta（贴到微信、Slack、Discord 会出缩略图）
- `https://s.example.com/f/a7Kd9xQ2mZ01.png` —— 裸文件，可以直接 `<img>`/`<video>` 引用，支持 Range（视频能拖进度条）

## 部署

### 一条命令

`Scripts/setup.sh` 把能自动化的都做了：建两个 bucket、加生命周期规则、生成并写入 `UPLOAD_TOKEN`、按桶授权地创建 R2 的 S3 凭据、改写 `wrangler.jsonc` 里的域名、最后部署（Worker 的自定义域名由 `wrangler.jsonc` 的 `routes` 在部署时自动建 DNS 和证书）。

```bash
npm install --prefix Worker
npx wrangler login                              # 必须在交互式终端里跑
cd Worker && ./Scripts/setup.sh --domain s.example.com
```

**默认是预演**：只打印将要执行的命令，什么都不改。看过之后再加 `--yes`：

```bash
./Scripts/setup.sh --domain s.example.com --yes
```

生成的 `UPLOAD_TOKEN` 会写进 `~/.duoshot-upload-token`（0600）而**不打印到终端** —— 终端会被截屏，而这个 app 的用户整天在截屏。粘进设置之后把它删掉。要在管道里用就加 `--print-token`。

R2 的 S3 凭据（大文件直传用）**建 token 这一步只能在面板做** —— wrangler 的 OAuth 没有 `API Tokens Write` 权限：

```
面板 → R2 → API → Create API token
  Permissions   Object Read & Write     ← 不是 Read only，presigned URL 是 PUT
  Bucket(s)     Apply to specific buckets only → duoshot
```

拿到 Access Key ID 和 Secret Access Key（64 位十六进制）之后：

```bash
cd Worker && ./Scripts/set-r2-credentials.sh && npx wrangler deploy
```

那个脚本分两次交互式读取，不回显、不接受命令行参数（参数会进 shell 历史和 `ps`）。Access Key ID 是 API token 的 `id`，Secret Access Key 是 token `value` 的 SHA-256 —— 这是 Cloudflare 文档写明的推导方式。

**只有一件事 API 替不了**：域名注册、以及在注册商那边把 nameserver 改到 Cloudflare。zone 激活之后剩下的全是自动的。

### 手工做的话

1. 域名放进 Cloudflare
2. 建两个 R2 bucket：`duoshot`（正式）和 `duoshot-dev`（`wrangler dev` 和测试用）
3. 改 `wrangler.jsonc` 里的 `PUBLIC_BASE`、`R2_BUCKET_NAME`，并把最下面的 `routes` 取消注释、换成你的域名

然后：

```bash
npm install --prefix Worker
```

设置密钥（**不要**写进 `wrangler.jsonc`）：

```bash
npx wrangler secret put UPLOAD_TOKEN
```

`UPLOAD_TOKEN` 是客户端唯一持有的凭据，随便一串 32 字节随机值即可：

```bash
openssl rand -base64 32
```

只有大文件（超过 90 MB 的录制）需要下面三个 —— 它们让 Worker 能签发 presigned PUT，从而让字节绕开 Worker 直接进 R2。不配也能跑，只是 `POST /api/new` 会回 501：

```bash
npx wrangler secret put R2_ACCOUNT_ID
npx wrangler secret put R2_ACCESS_KEY_ID
npx wrangler secret put R2_SECRET_ACCESS_KEY
```

> R2 的 API token **按 bucket 授权**，只勾 `duoshot` 这一个桶的对象读写，不要用账号级的令牌。

部署：

```bash
npx wrangler deploy
```

### bucket 不要开公共访问

`setup.sh` 刻意**没有**跑 `wrangler r2 bucket domain add`，也没有开 `dev-url` —— 网上的 ShareX + R2 教程都是那么配的，但那条路对这个 Worker 是错的。

Content-Type 白名单、`noindex`、"过期显示 410" 全都在 Worker 里。把 bucket 直接挂到一个域名上，等于给这三样开了一条绕过的路，其中 Content-Type 那条是**安全边界** —— 绕过去之后，上传一个 `.svg` 就能在你自己的域名上执行脚本。

### 过期

想让某次上传自动消失，上传时传 `ephemeral`。这类对象存在 `e/` 前缀下，`setup.sh` 已经对该前缀加好了生命周期规则（默认 30 天，`--expire-days` 可改）。

对象被生命周期删掉之后，**预览页会回 410「已过期」而不是 404** —— 元数据边车比对象活得久，这就是它存在的理由之一。

## API

除 `GET` 三个公开路由外，全部需要 `Authorization: Bearer <UPLOAD_TOKEN>`。

| 方法 | 路径 | 说明 |
|---|---|---|
| `POST` | `/api/new` | 大文件路径。body 是 JSON，返回 `uploadURL`，客户端把原始字节 **PUT 到那个 URL**（不带 Authorization，签名在 URL 里，15 分钟有效） |
| `PUT` | `/api/put?ext=png&name=…` | 小文件路径，一次请求搞定。**必须带 `Content-Length`**，上限 90 MB |
| `PUT` | `/api/poster/<key>` | 给视频传一张封面图，上限 4 MB。传了之后链接才会有缩略图预览 |
| `DELETE` | `/api/o/<key>` | 删除对象、封面和边车 |
| `GET` | `/api/list?limit=25` | 最近的上传，一次操作读完（信息存在边车的 customMetadata 里） |
| `GET` | `/<key>` | 预览页 |
| `GET` | `/<key>/dl` | 同样的字节，强制下载 |
| `GET`/`HEAD` | `/f/<key>.<ext>` | 裸文件。Range → 206，`If-None-Match` → 304 |

`POST /api/new` 的 body 和两条路径的返回：

```jsonc
// POST /api/new
{ "ext": "mp4", "name": "Recording.mp4", "size": 184320000,
  "ephemeral": false, "width": 1728, "height": 1117, "duration": 12.5 }

// 201
{ "key": "a7Kd9xQ2mZ01",
  "pageURL": "https://s.example.com/a7Kd9xQ2mZ01",
  "fileURL": "https://s.example.com/f/a7Kd9xQ2mZ01.mp4",
  "uploadURL": "https://<account>.r2.cloudflarestorage.com/…" }  // 仅 /api/new 有
```

### 存储布局

| 前缀 | 内容 |
|---|---|
| `m/<key>` | 边车：JSON 元数据。**永不过期**，对象没了它还在，用来回 410 |
| `p/<key>` | 长期保存的字节 |
| `e/<key>` | 会过期的字节（生命周期规则挂这个前缀） |
| `s/<key>` | 视频封面 |

## 开发与测试

```bash
npm --prefix Worker run dev        # wrangler dev，本地 R2
npm --prefix Worker test           # 离线，不花钱
npm --prefix Worker run typecheck
```

`wrangler dev` 读不到线上的 secret，所以本地要建一个 `Worker/.dev.vars`（已在 `.gitignore` 里）：

```
UPLOAD_TOKEN = "local-dev-token"
```

不建也能起，只是每个写接口都回 401 —— 实测确认过，**`UPLOAD_TOKEN` 未设置时带不带 token 都是 401**，这是故意的：一个漏配了密钥的 Worker 必须拒绝一切，而不是放行一切。

测试跑在 workerd 里、用 miniflare 的本地 R2，所以整套是离线、确定性、零成本的。仓库根目录有 `make share-check` 一次跑完类型检查和测试。

**测试里有反向对照**：`accepts an upload with the right token` 是那两条 401 断言的对照 —— 一个把所有请求都拒掉的路由同样会拒掉坏 token，没有这条对照，那两条证明不了任何事。想确认整套测试真的能失败，把 `isAuthorized` 改成 `return true` 再跑一次，应该红三条。

## 几条不要改错的地方

- **Content-Type 来自扩展名的白名单，不来自上传时声明的类型。** 把用户上传的文件当 `text/html` 或 `image/svg+xml` 发出去，就是在自己的域名上给此前分享过的每一个链接种了存储型 XSS。`src/mime.ts` 那张表是安全边界，不是便利设施；SVG 不在里面是故意的。
- **key 是 12 位 base62（约 71 bit）随机值**，用拒绝采样而不是 `% 62`。截图里经常有不该公开的东西，唯一的防线就是猜不到。
- **`UPLOAD_TOKEN` 没设置时一律拒绝**，而不是放行。
- **删除的顺序是先对象后边车。** 中途断掉的话，留下的是"有边车没对象"，那会干净地回 410；反过来会留下永远收不到租金的字节。
