# wist-field Python 示例

调用 **计算区 BFF**（`wist-field-api`）的最小可运行示例，全部只用 Python 标准库
（Python 3.8+）。浏览器 / 脚本只跟 BFF 说话：到证据服务的 mTLS、租户、scope、
敏感度都在 BFF 里完成，示例里唯一的凭据是一把操作员令牌 `wcr_…`。

> `wist-field-web` 是页面；本目录演示的是它背后的 HTTP 接口。

访问模型：栈只发布 **web 入口**（`WEB_HOST_PORT`，默认宿主 `8088` → 容器 `443`），
nginx 再把 `/api` 反代到 `field-api:8080`。所以 `WIST_FIELD_URL` 填**站点入口**，
不要填容器里的 8080（没有发布到宿主）。

## 先跑起来（本地栈：零参数）

```bash
cd examples/field-api

python3 01_token_identity.py
python3 02_health.py --strict
python3 03_evidence.py --limit 2
python3 03_evidence.py --limit 2 --content
python3 04_metrics.py
python3 05_integration_and_atlas.py
```

本地栈下脚本会自动：

- 用默认入口 `https://127.0.0.1:8088`；
- 信任本栈 `identity/web/public/web-ca.crt.pem`，**不用再传 `--insecure`**；
- 没有令牌时，从可发现的本地 cred 领一把 **5 分钟** dev 令牌
  （`WIST_FIELD_NO_DEV_TOKEN=1` 关闭；`WIST_CRED_SECRET_FILE` / `WIST_CRED_SITE` 指定 cred）；
- 单客户站点自动选客户，多客户才需要 `--tenant` / `WIST_FIELD_TENANT`。

自动签发的令牌不会打印；它只用于本地开发，`subject = examples-field-api`，TTL 300s。

### 跨环境 / 生产：显式给入口和令牌

```bash
export WIST_FIELD_URL=https://<站点入口>:<端口>
export WIST_FIELD_TOKEN=wcr_xxx
export WIST_FIELD_TENANT=c-001        # 多客户站点必填
python3 02_health.py
```

也可以自己签一把（不依赖自动发现）：

```bash
export WIST_FIELD_TOKEN=$(python3 mint_token.py \
    --secret-file /path/to/wist-cred-stack/.wist/sec-value.yml \
    --cred-url https://127.0.0.1:4444)
```

`--audience` 不传时依次取 `WIST_FIELD_AUDIENCE` → 栈根 `.env` 的 `FIELD_API_AUDIENCE`
→ 产品默认 `wist-field-api`。它必须等于目标 field-api 的 `[verify].audience`，
签错 audience 访问会 401。

`auth.mode = ingress` 的部署没有令牌，用入口写入的操作员头：

```bash
python3 01_token_identity.py --operator 张三
```

## 文件

| 文件 | 内容 |
| --- | --- |
| `field_client.py` | 共用客户端：Bearer、客户选择、翻页、错误信封、预签名下载、证据写入 |
| `01_token_identity.py` | 令牌体检：`POST /api/login`、`GET /api/session`、客户选择 |
| `02_health.py` | `GET /api/health`：数据源状态 + 逐条接口探活（`--strict` 可做探针） |
| `03_evidence.py` | `GET /api/evidence*`：列表 / 详情 / 正文 / 预签名下载 |
| `04_metrics.py` | `GET /api/metrics`、`/api/metrics/middleware`、`/api/ingest/stats` |
| `05_integration_and_atlas.py` | `GET /api/integration` + `GET /api/atlas/*` 代理 |
| `06_write_evidence.py` | 数据面 `POST /internal/evidence` → BFF 读回 |
| `mint_token.py` | 开发态：用 cred web 口令签一把读令牌 |

> **`01` 不是“登录一次、后面就不用令牌了”。** BFF 没有会话：`POST /api/login`
> 只把令牌解成身份（subject / roles / audience / expires_at），不设 cookie、不返回
> session id；`GET /api/session` 也只是回**当前令牌**能看哪些客户。每个 `/api/*` 请求
> 都各自带一次 `Authorization: Bearer`。所以 `01` 是可选的令牌体检，跳过它直接跑
> `02` 也行；它单独存在只是为了先把 401/403 的原因（令牌错 / 过期 / audience 不符 /
> 角色不够）暴露出来。

## 接口速查

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/healthz` | **只直连 BFF（8080）才有**；经 web 入口时由 nginx / 前端接管 |
| POST | `/api/login` | 令牌换身份：`{token}` 或 `Authorization: Bearer` |
| GET | `/api/session` | 本令牌能看的客户集合（**不返回默认客户**） |
| GET | `/api/health` | 数据源就绪度 + `interfaces[]` 逐条探活（含延迟 / covers） |
| GET | `/api/integration` | 数据面写端点 + wparse 环境变量（数据面视角） |
| GET | `/api/evidence` | 证据列表；`cmd_id` / `kind` / `subject_id` / `since` / `limit` / `cursor` |
| GET | `/api/evidence/capabilities` | 对象后端是 `file` 还是 `s3`，正文走哪条路 |
| GET | `/api/evidence/openapi.json` | 证据读接口的 OpenAPI 3.1 |
| GET | `/api/evidence/{key}` | 一条证据的索引行；`key` 可以是 `cmd_id` 或 `art_…` |
| GET | `/api/evidence/{key}/content` | BFF 代理读正文（**解压后原文**） |
| POST | `/api/evidence/{key}:presign` | 60 秒单对象签名 URL（仅 `s3`；`file` 回 501） |
| GET | `/api/metrics` | 主机 / agent / 业务单元 / 指标目录 |
| GET | `/api/metrics/middleware` | Kafka / DB / 容器等家族当前读数 |
| GET | `/api/ingest/stats?window_seconds=` | 三条通道累计写入量与最后接收时间 |
| GET | `/api/atlas/{path}` | 代理 atlas 只读接口（`hosts` / `network-domains` / `elastic-ips` …） |
| POST | `/internal/evidence` | **证据服务写端点**（数据面，内网明文无认证，不经 BFF） |

> 0.7.7 起 `GET /api/metrics/hosts/history` 与
> `GET /api/metrics/agents/{id}/history` 已移除，别按旧 README 去找。

## 几个容易踩的点

- **客户（tenant）就是客户 id**。多客户站点不带 `?tenant=` 回 400
  `tenant_required`，带不在集合里的值回 403 `tenant_not_allowed`。所有请求都走
  `FieldClient` 时，客户只在一个地方拼（`_url`），不会漏。
- **404 是统一口径**：不存在 / 跨客户 / 敏感度过高 / 已过期都回 404，BFF 不区分
  「不存在」和「不能看」。列表为空也可能是客户选错了。
- **错误信封**：非 2xx 一律 `{"error": {"code", "message"}}`。`field_client.explain()`
  会把常见状态码翻成一句提示。
- **两类正文通路**：`/content` 是解压后的原文；预签名 URL 拿到的是存储里的对象
  （`.zst` 压缩）。示例默认走 `/content`。
- **`/healthz` 不是 web 入口的 BFF 探活**：它只在直连 `field-api:8080`（或本地
  `cargo run`）时是 BFF JSON；经站点入口时被 nginx / 前端接管，返回的是页面。
  脚本走 web 入口时用 `/api/health` 看 BFF 的就绪度。
- **探活 ≠ 有数据**：`/api/health` 的 `ok` 只说明端点通；数据有没有进来要看
  `/api/ingest/stats`。
- **本栈指标 ≠ 网关栈指标**：`/api/metrics` 读的是数据场自己的 VictoriaMetrics，
  没有 `wparse_*` 引擎统计。本目录不负责造样本；需要时可直接向本栈 VM 的
  `/api/v1/import/prometheus` 写入（地址由 `VM_BIND_IP` / `VM_HOST_PORT` 决定）。
- **写端点在内网**：`POST /internal/evidence` 无认证、明文，只该在可信内网使用；
  `write_url` 是**数据面视角**的地址，从你的开发机不一定可达。栈里写监听默认只绑
  `EVIDENCE_SINK_BIND_IP`（回环），要对接数据面时改成内网地址。
- **HTTPS 自签入口**：本地入口会自动信任 `identity/web/public/web-ca.crt.pem`；
  找不到 CA 时才用 `--insecure` / `WIST_FIELD_INSECURE=1`。生产入口应使用可信证书，
  不要习惯性跳过校验。

## 环境变量

| 变量 | 说明 |
| --- | --- |
| `WIST_FIELD_URL` | 站点入口，默认 `https://127.0.0.1:8088`；远程用 `https://<WEB_DOMAIN>:<WEB_HOST_PORT>` |
| `WIST_FIELD_TOKEN` | 访问令牌 `wcr_…` |
| `WIST_FIELD_TENANT` | 客户 id（多客户站点必填） |
| `WIST_FIELD_OPERATOR` | `ingress` 模式的操作员名（无令牌时用） |
| `WIST_FIELD_INSECURE` | `1` = 跳过 HTTPS 证书校验（本地一般不需要，脚本会自动加载本栈 web CA） |
| `WIST_FIELD_CA_FILE` | 显式指定站点 CA（远程自签入口时用） |
| `WIST_FIELD_NO_DEV_TOKEN` | `1` = 禁止本地自动签 dev 令牌 |
| `WIST_FIELD_TIMEOUT` | 超时秒数，默认 `15` |
| `EVIDENCE_SINK_URL` | 证据服务写地址根（`06_write_evidence.py`） |
| `WIST_CRED_SITE` | 本地 cred 栈目录（自动签令牌时用来找 `.wist/sec-value.yml`） |
| `WIST_CRED_URL` | cred HTTPS 入口（默认从 `WIST_CRED_SITE/.env` 的 `WEB_HOST_PORT` 推导） |
| `WIST_CRED_SECRET_FILE` | 直接指定 cred 的 `.wist/sec-value.yml` |
| `WIST_CRED_PASSWORD` | 直接给 cred web 口令（`mint_token.py` / 自动签令牌） |
| `WIST_FIELD_AUDIENCE` | 令牌 audience（不设则读栈根 `.env`） |
