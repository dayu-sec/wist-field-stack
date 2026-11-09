# 开发态：站点栈 + 本地镜像 / 源码前端

目标：**改一行代码，几秒内在真实环境里看到效果**。与 `wist-cred` 的开发工作台同一套做法
（见 `wist-work-skills/skills/wist-cred-dev-workflow`）。

## 两条回路

| 你要验什么 | 用哪条 | 后端 | 前端 |
| --- | --- | --- | --- |
| 页面交互、样式、四层表达 | **前端 HMR** | 栈里的 `field-api`（发布镜像或本地镜像都行） | `dev/dev-web.sh` → vite dev |
| 接口形状、PromQL、聚合口径 | **本地镜像** | `dev/dev-image.sh` 把源码交叉编译成 `vX.Y.Z-local` 挂进本栈 | 站点入口 `:8088` 或 HMR |

两条可以同时开（不同端口）。

## 一次性准备（每台机器一次）

```sh
brew install zig
cargo install cargo-zigbuild --locked
rustup target add aarch64-unknown-linux-gnu     # Intel 机器换成 x86_64-unknown-linux-gnu
```

三条硬事实（别踩）：

1. **macOS 二进制不能塞进 Linux 容器**：Mach-O ≠ ELF，直接 copy 会 `exec format error`（同 arm64 也不行）；
2. **不要在容器里 `cargo build`**：没有缓存，`--release` 全量 20+ 分钟，且改一行就整体失效；
3. **zig 交叉编译是秒级的**：宿主原生编译到 `aarch64-unknown-linux-gnu`，首次编依赖几分钟，之后 5–15 秒。

## 后端：本地镜像

```sh
./dev/dev-image.sh --api      ../../wist/wist-field-api  # field-api
./dev/dev-image.sh --evidence ../../wist/wist-evidence   # evidence（读接口改动用这条）
./dev/dev-image.sh --atlas    ../../wist-atlas           # atlas（从发布镜像派生，只换二进制）
./dev/dev-image.sh --web      ../../wist-field-web       # web（本地 npm build 后从发布镜像派生）
```

它做四件事：`cargo zigbuild` → 把 ELF 放进临时 build context → 打包（基底 / uid / ENTRYPOINT
与发布态一致，只换二进制）→ 备份 `.env`、把镜像 tag 改成 `vX.Y.Z-local`、**只重建那一个容器**。

- `field-api` / `evidence` 用各自仓库自带的 `docker/Dockerfile`；
- `atlas` 的仓库 Dockerfile 会在容器里 `cargo build`（20+ 分钟），所以本地改成
  `FROM <已发布镜像> + COPY 二进制` —— 运行时形状完全不变，也不用自己选基底；
- `web` 同理：`npm run build` 在宿主机跑（容器里 `npm ci` 又要拉包又慢），镜像从发布镜像
  派生、只换 `/usr/share/nginx/html`，`nginx.conf` 与健康检查原样保留；
- 镜像名形如 `${FIELD_REGISTRY}/wist-field-api:vX.Y.Z-local`，不在任何 registry 里；
- **不要跑 `gops sys localize`**：它按 `values/` 重算 `.env`，会把本地 tag 覆盖回发布 tag；
- 回滚：脚本结束会打印备份路径，`cp` 回去再重建那个服务。

## 前端：HMR

```sh
./dev/dev-web.sh --web ../../../wist-field-web --cred-site ../../local-work/cred-local/wist-cred-stack
```

- 后端 = 站点入口 `https://<WEB_DOMAIN>:<WEB_HOST_PORT>`（自签证书，代理已按 target 前缀关校验）；
- `--cred-site` 会顺手领一个 dev 令牌（`dev-token.sh`），代理只在页面**没带** `Authorization` 时才补 ——
  所以令牌输入框、401 这些路径在 dev 里仍然是真的；
- 不带 `--cred-site` 就自己粘令牌；改前端代码即时生效（HMR），不用重启任何东西。

## 令牌

```sh
./dev/dev-token.sh --cred-site ../../local-work/cred-local/wist-cred-stack
```

`audience` 默认从 `sys/configs/field-api/cred.toml` 读（本栈登记的名字，别再手抄）。
令牌会进 shell 历史，TTL 默认 2 小时；生产走 cred 页面签发。

## 自检

```sh
docker ps --filter name=field-stack-field-api --format '{{.Image}}\t{{.Status}}'   # 跑的是哪个镜像
TOKEN=$(./dev/dev-token.sh --cred-site <cred 栈>)
curl -sk https://localhost:8088/api/metrics -H "authorization: Bearer ${TOKEN}" |
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(list(d), len(d["business"]), d["unassigned_agents"])'
curl -s http://localhost:5175/api/metrics -o /dev/null -w '%{http_code}\n'       # HMR 代理是否注入令牌

# atlas 接口文档（直连宿主端口；spec / 阅读页不要令牌，数据接口要）
ATLAS_TOKEN=$(grep '^ATLAS_API_TOKEN=' .env | cut -d= -f2)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18801/api/openapi.json
curl -s -o /dev/null -w '%{http_code}\n' -H "authorization: Bearer ${ATLAS_TOKEN}" http://127.0.0.1:18801/api/hosts
open http://127.0.0.1:18801/api/docs
```

## 坑

| 现象 | 原因 / 处置 |
| --- | --- |
| `exec format error` | 把 macOS 二进制放进 Linux 容器了；必须交叉编译 |
| 改完 tag 一跑 `gops sys localize` 就变回发布 tag | `.env` 是 localize 的产物，开发期不要跑 |
| dev server 起来但页面 502 | 目标用了 `http://127.0.0.1:8088`（站点是 https），或证书 SAN 不匹配 |
| `/api/*` 一直 401 | 没注入令牌且页面也没有：用 `--cred-site` 或手动粘；先确认 `audience` 与 cred 里登记的认证系统同名 |
| `audience_not_configured` | cred 里没有这个认证系统：`cred.toml` 的 `audience` 与 cred 的 peer 名不一致 |
| 镜像 300MB+ | debug 二进制本来就大；只验功能就用 debug，要接近发布体积加 `--release` |

## 与发布流程的衔接

本地镜像**只用于开发**；发布仍走 `wist-work`：改 `sys/setting/vars.yml` → `gops sys update` →
CHANGELOG + `version.txt` → 打 `vX.Y.Z-alpha` tag，镜像由组件仓 CI 双推 ghcr + TCR。
发完把 `.env` 切回正式 tag（或 `gops sys localize`）再重建。
