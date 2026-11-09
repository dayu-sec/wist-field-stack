# wist-field-stack

计算区**只读**界面「数据场 · 现场视图」的一体化编排：**证据 / 资产拓扑 / 运行指标 / 设备状态** 一个入口。

本仓**只做编排**，镜像分别来自：

- [`wist-evidence`](https://github.com/dayu-sec/wist-evidence)（证据服务）
- [`wist-field-api`](https://github.com/dayu-sec/wist-field-api)（BFF）
- [`wist-field-web`](https://github.com/dayu-sec/wist-field-web)（前端）
- [`wist-atlas`](https://github.com/dayu-sec/wist-atlas)（资产与拓扑 API；画布已组件化进 `wist-field-web`）

## 组件

| 服务 | 作用 | 端口（宿主:容器） | 镜像 |
|---|---|---|---|
| `web` | 唯一浏览器入口：静态托管 + `/api` 反代 | `${WEB_BIND_IP}:${WEB_HOST_PORT}:80` | `wist-field-web` |
| `field-api` | 只读 API（BFF）：身份 / 健康聚合 / 预签名转发 / 指标查询 / 拓扑代理 | 仅 compose 网络 `:8080` | `wist-field-api` |
| `evidence` | 证据索引 + 对象存储 | 写 `${EVIDENCE_SINK_BIND_IP}:${EVIDENCE_SINK_HOST_PORT}:8080`；读仅网络内 `:${EVIDENCE_READ_PORT}` | `wist-evidence` |
| `atlas` | 资产与拓扑 API（读接口要 Bearer 令牌） | 写 `${ATLAS_INGEST_BIND_IP}:${ATLAS_INGEST_HOST_PORT}:8080`；读仅网络内 `:8080` | `wist-atlas` |
| `metrics` | 运行指标（VictoriaMetrics） | `${VM_BIND_IP}:${VM_HOST_PORT}:8428` | `victoriametrics/victoria-metrics` |
| `evidence-postgres` | 证据索引库 | `${PG_BIND_IP}:${EVIDENCE_PG_HOST_PORT}:5432` | `postgres` |
| `atlas-postgres` | 资产库 | `${PG_BIND_IP}:${ATLAS_PG_HOST_PORT}:5432` | `postgres` |

**只有 `web` 给浏览器用**；对数据面开放的只有三个写/收端口：
证据写（`18800`）、资产写（`18801`）、指标（`18428`）。其余服务都不绑宿主端口。

## 快速开始（docker compose）

```bash
cp .env.example .env

# 1) 密钥：`${SEC_...}` 的真值（0640）
mkdir -p .wist
cat > .wist/sec-value.yml <<'YAML'
SEC_EVIDENCE_DB_URL: postgres://evidence:evidence-dev-only@evidence-postgres:5432/wist_evidence
YAML
chmod 0640 .wist/sec-value.yml

# 2) 运行态备料（gops 用栈根作为 project directory；sys/configs 只是种子）
#    脚本会自己读栈根 `.env`（显式传入的环境变量优先），所以 `WEB_DOMAIN` 直接生效
bash sys/scripts/init-stack.sh

# 3) 起（手动 compose 要显式指定 --project-directory .，与 gops 行为一致）
docker compose --project-directory . -f sys/docker-compose.yml --env-file .env up -d

# 4) 入口（默认只绑回环）
#    https://127.0.0.1:8088/   （TLS 在 web 容器里终结；证书自动生成）
```

入口要**访问令牌**：`field-api` 配的是 `auth.mode = "cred"`，令牌由 `wist-cred` 签发。
没有令牌就没有「匿名打开」这一档 —— 先把本栈接入凭据中心（见下面「接入 wisst-cred」）。

```bash
curl -k -H 'Authorization: Bearer wcr_…' https://127.0.0.1:8088/api/health
```

## 快速开始（gops）

```bash
gops sys update      # sys/setting/vars.yml -> sys/merged_vars.yml
gops sys localize    # 生成栈根 .env
bash sys/scripts/init-stack.sh   # 种子 -> 栈根 configs/ 与 .wist/（并读 .env 签 web 证书）
gops run start
```

> `gops` 用**栈根**当 compose 的 project directory，所以 `./configs`、`./.wist` 都在栈根；
> `sys/configs/` 只是种子。手动 `docker compose` 时也要带 `--project-directory .`，否则挂载会指错。

现场覆盖值写 ops-prj 的 `values/wist-field-stack/sys_value.yml`，不要改 `sys/setting/vars.yml`。

## 发布

本栈是**制品**，走 `alpha → beta → main` 三条通道：**当前开发与发布在 `alpha` 分支**，
tag 形如 `vX.Y.Z-alpha`；成熟后再推进到 `beta`（`-beta`）与 `main`（无后缀）。

在 `alpha` 分支打 `vX.Y.Z-alpha` tag 会触发 `.github/workflows/release.yml`
（与 `wist-cred-stack` 同一套）：

1. **verify**：用入库的 `.env.example` 渲染 compose + `./dev/lint.sh` + `dev/tests/*.test.sh`；
2. **package**：`git archive` 出 `wist-field-stack-<tag>.tar.gz`（只含 git 跟踪内容）；
3. **release**：发到 GitHub Release；
4. **可选 COS**：配了 `COS_BUCKET` 时把同一个包推到
   `cos://$COS_BUCKET/<COS_PREFIX|wist-field-stack>/<tag>/` 与 `/latest/`，
   带 `x-cos-meta-artifact-sha256`。

本栈**不含二进制**：`wist-evidence` / `wist-field-api` / `wist-field-web` / `wist-atlas`
的镜像由各自仓的流水线产出。

`sys/merged_vars.yml` 是**入库文件**：改 `sys/setting/vars.yml` 后跑 `gops sys update`，
把两份一起提交；`.env.example` 也必须同步（`dev/tests/env-example-drift.test.sh` 会在 CI 里钉住）。

## 本机访问

浏览器入口：**<https://127.0.0.1:8088/>**（`WEB_BIND_IP` / `WEB_HOST_PORT` 可改）。

TLS 在 `web` 容器里终结（80 只给健康检查、不发布到宿主）。证书由
`sys/scripts/init-web-tls.sh <域名>` 生成两级材料到 `identity/web/`：一张 web CA + 由它签的叶。
**把 `identity/web/public/web-ca.crt.pem` 导入浏览器信任库一次**，之后换叶零动作；
不导入就只能「继续访问（不安全）」。

`field-api` 是 **`cred`** 模式（默认，也是唯一推荐）：

- 浏览器打开页面时会要求粘贴访问令牌（`wcr_…`），令牌只存在 `sessionStorage`；
- BFF 用 `wist-cred-peer` 的摘要表验：没带 → 401 `field_credential_missing`，
  不认识 / 过期 / 撤销 → 401 `field_credential_invalid`，角色不够 → 403 `field_role_required`；
- 摘要由 `wist-cred` 通过 **mTLS** 推到 `field-api` 的 3103（宿主 `${CREDENTIALS_BIND_IP}:${CREDENTIALS_HOST_PORT}`），
  本地只落 sha256，不进 PG、重启不丢。

### 接入 wist-cred（一次性，P1 自注册）

默认路径：**field-api 自己注册**。栈渲染的 `configs/field-api/cred.toml` 带 `[init]`，
首次启动只开 `/__init`，注册材料由服务自己写进 `identity/field-api/cred/`。

1. 先把两个部署事实写进 `values/wist-field-stack/sys_value.yml`（或 `.env`）：

   ```yaml
   # 认证系统名 = cred 侧那个 peer 的名字；凭据的 audience 必须等于它。
   FIELD_API_AUDIENCE: wist-field-api
   # 收数地址的主机名 = 证书 SAN = cred 拨号的地址。**不填就启动失败**（有意如此）。
   FIELD_API_ADVERTISE_HOST: field.dev.wist.lab
   # cred 的注册入口（留空 = 初始化页上填）。
   FIELD_API_CRED_URL: https://cred.dev.wist.lab:4444
   # cred 在别的机器/容器里时，收数监听不能只绑回环。
   CREDENTIALS_BIND_IP: 0.0.0.0
   # 入口是自签证书：给它 CA；拿不到 CA 时才用 FIELD_API_CRED_INSECURE_TLS: 'true'。
   FIELD_API_CRED_CA_FILE: /cred/cred-entry-ca.pem
   ```

2. 在 cred 页面建「认证系统」（名字要等于栈变量 `FIELD_API_AUDIENCE`，产品默认 `wist-field-api`；
   角色至少 `read`），签发一张**接入券**（`wot_…`）；
   同时拿到 **setup code**：`bash sys/scripts/init-stack.sh` 会幂等生成它并写进
   `.wist/sec-value.yml` → `SEC_FIELD_API_PEER_SETUP_CODE`（0640；没生成过就读不到，
   现场也不要自己编一个弱口令）。

3. 起栈（`gops run start`），打开 **<https://127.0.0.1:8088/__init>**，填 setup code + 券 → 提交。

   成功后响应里有：

   | 字段 | 用途 |
   |---|---|
   | `written` | 三件材料的落点 |
   | `cred_certificate_sha256` | 入口证书指纹，与 `openssl s_client … -fingerprint -sha256` 对照 |
   | `restart_required: false` | **不需要重启**：收数监听材料齐了自己起来 |

4. `curl -k -H 'Authorization: Bearer wcr_…' https://127.0.0.1:8088/api/health` 应看到
   `凭据：已登记 N 条；收数监听在线`。

失败了怎么办（初始化页会把错误码写在响应里）：

| 错误码 | 含义 / 怎么修 |
|---|---|
| `setup_code_invalid` | 页面上的 setup code 与 `sec-value.yml` 里的不一致（403，不落任何材料） |
| `cred_unreachable` + `certificate` | 入口自签且没配信任锚：设 `FIELD_API_CRED_CA_FILE`，或明确开 `FIELD_API_CRED_INSECURE_TLS` 后再核对指纹 |
| `publish_endpoint_invalid` | `FIELD_API_ADVERTISE_HOST` 是空（地址渲染成 `https://:18802/…`）；同时 field-api 启动期就会拒 |
| `host_mismatch` | 页面上手填的证书主机名与 `[publish].endpoint` 的主机名不一致（cred 按后者拨号） |
| `bundle_rejected` / `enroll_rejected` | cred 拒绝：券已用/过期，或认证系统名字与 `FIELD_API_AUDIENCE` 不一致 |

> 想重来：删掉 `identity/field-api/cred/{server.crt,server.key,client-ca.pem}` 后重启。

### 升级后配置没生效？先看 `init-stack.sh` 的提示

`sys/configs/` 是**种子**，脚本只补缺、不覆盖现场改动 —— 好处是现场改的端口/域名不会被冲掉，
代价是“栈升了，但运行态那份还是旧的”（典型表现：nginx 少了 `/__init`，页面直接掉到 SPA）。

所以脚本会逐文件比对并列出差异。确认可以跟种子一致时：

```bash
FORCE_CONFIGS=1 bash sys/scripts/init-stack.sh   # 用种子覆盖 configs/ 下的差异
```

### 接入 wist-cred（旧路径：join.sh）

在没有 `[init]` 的部署（例如走入口认证、或 cred 侧只支持接入命令）时仍可用：

```bash
bash sys/scripts/init-stack.sh                       # 先备料（目录 / sec-value / web TLS）
curl -fsSLk 'https://<cred>/enroll/<券>/join.sh' | bash -s -- \
  --dir './identity/field-api/cred' \
  --host "$(hostname -f)" \
  --roles admin,read
```

| 参数 | 不给会怎样 |
|---|---|
| `--dir` | 材料落到别处；**给错目录**最隐蔽——一切看起来正常，但本服务读不到 |
| `--host` | 证书 SAN 用本机名；cred 用别的名字连过来会证书校验失败 |
| `--roles` | 从没登记过角色 → 发不出凭据（`400 roles_not_registered`） |

> 收数地址**不再由命令行给**（`--advertise` 已删除）：它是部署事实，只有三个来源 ——
> 栈渲染的 `[publish].endpoint`、cred 控制台登记、或自注册时随券上报。

`identity/` 下的材料（含 `server.key`）**不进版本库**：自注册 / join.sh / `init-web-tls.sh`
各自生成。

### 只想用入口认证？

把 `auth.mode` 改成 `ingress`（运行态 `configs/field-api/field-api.toml`），
入口（VPN / 堡垒机 / 反代）认证后注入 `x-field-operator` 即可：

```bash
curl -k -H 'x-field-operator: zhangsan' https://127.0.0.1:8088/api/health
```

页面：

| 路由 | 内容 |
|---|---|
| `#/overview` | 四域就绪度 + 接口可用性摘要 |
| `#/evidence` | 证据列表（按主机、类型筛） |
| `#/evidence/{artifact_id}` | 元数据 + 「打开正文（60s）」 |
| `#/topology` | 资产拓扑（画布是 field-web 的组件，数据走 BFF 的 `/api/atlas/*`） |
| `#/health` | **接口可用性**：逐条探活 + 延迟 + 本次会话可用率，可手动立即检查 |
| `#/pipeline`、`#/devices` | 占位（写明缺什么） |

## 密钥与配置

### 端口与地址（都在 `sys/setting/vars.yml`，现场在 `values/` 覆盖）

| 变量 | 默认 | 作用 |
|---|---|---|
| `WEB_BIND_IP` / `WEB_HOST_PORT` | `127.0.0.1:8088` | 唯一浏览器入口（HTTPS，容器内 443） |
| `WEB_DOMAIN` | `localhost` | 证书 SAN 里的域名（SAN 同时带 `localhost` 与 `127.0.0.1`） |
| `EVIDENCE_SINK_BIND_IP` / `EVIDENCE_SINK_HOST_PORT` | `127.0.0.1:18800` | 证据写入端口（数据面 `http_sink`） |
| `EVIDENCE_SINK_PUBLIC_HOST` | `127.0.0.1` | 「接入」页展示的写端点主机名（数据面视角，**每个实例不同**）；端口复用 `EVIDENCE_SINK_HOST_PORT` |
| `ATLAS_INGEST_BIND_IP` / `ATLAS_INGEST_HOST_PORT` | `127.0.0.1:18801` | 资产拓扑写入端口（数据面投 DSNAP） |
| `ATLAS_INGEST_PUBLIC_HOST` | `127.0.0.1` | 「接入」页展示的资产拓扑写端点主机名；端口复用 `ATLAS_INGEST_HOST_PORT` |
| `VM_BIND_IP` / `VM_HOST_PORT` | `127.0.0.1:18428` | VictoriaMetrics：数据面 remote write + 运维查询 |
| `ATLAS_PROBE` / `ATLAS_PROBE_INTERVAL_SECS` | `on` / `300` | atlas 写探针（往保留租户写最小 DSNAP） |
| `EVIDENCE_READ_PORT` | `8443` | 证据读监听（容器内）。**一个来源**：evidence 的 `[read].listen_addr`、compose 健康检查、field-api 的 `evidence.base_url` 都从它来 |
| `PG_BIND_IP` / `EVIDENCE_PG_HOST_PORT` / `ATLAS_PG_HOST_PORT` | `127.0.0.1:55434/55435` | 两个 PG（仅供排查） |
| `CREDENTIALS_BIND_IP` / `CREDENTIALS_HOST_PORT` | `0.0.0.0:18802` | cred 推送摘要 / 心跳的 mTLS 端口 |
| `FIELD_API_ADVERTISE_HOST` | 空（**必填**） | 收数地址的主机名 = 证书 SAN = cred 拨号地址；不填 field-api 启动期就拒 |
| `FIELD_API_AUDIENCE` | `wist-field-api` | 认证系统名（= cred 侧那个 peer 的名字）；凭据的 `audience` 不等于它就 401 `audience_mismatch` |
| `FIELD_API_CRED_URL` | 空 | cred 注册入口；留空则由初始化页填 |
| `FIELD_API_CRED_CA_FILE` | 空 | 入口自签时的信任锚（容器内路径，如 `/cred/cred-entry-ca.pem`） |
| `FIELD_API_CRED_INSECURE_TLS` | `false` | 明确跳过入口证书校验（与 `CA_FILE` 互斥；开了就必须核对指纹） |
| `FIELD_API_REQUIRE_CRED_SIGNATURE` | `false` | 授权记录强制验签（公钥 `issuer-signing.pub` 同目录；开了但不在 → 启动期报） |

> 改 `EVIDENCE_READ_PORT` 后只需 `gops sys localize && gops run start`；配置文件里写的是
> `listen_addr = "0.0.0.0:${EVIDENCE_READ_PORT}"`，不要再把端口写死回 TOML。

| 文件 | 内容 |
|---|---|
| `sys/configs/evidence/wist-evidence.toml` | 种子：sink 监听 / 允许的 kind / 索引库 / 对象存储（运行态在 `configs/evidence/`） |
| `sys/configs/field-api/field-api.toml` | 入口身份、到证据服务的租户与敏感度、atlas 读/写地址、VM 地址 |
| `.wist/sec-value.yml` | `${SEC_...}` 的真值（DB URL、COS 凭据），**不入库** |

- 写端点不校验身份（内网可信）；P1 换成 HTTPS 双向认证；
- 两处 `tenant`（evidence 的 sink 声明与 field-api 的读身份）必须一致。

### 证据正文存在哪（两种模式）

| `objects.kind` | 用在哪 | 位置 | 预签名 |
|---|---|---|---|
| `file`（本栈默认） | 测试 / 现场验证 | 宿主 `./data/evidence-objects/`（容器内 `/var/lib/wist-evidence/objects`） | ❌ 回 501 |
| `s3` | 生产 | 腾讯 COS / MinIO | ✅ 60s 单对象 |

本地模式的文件就是对象键：`<租户>/<kind>/<年>/<月>/<artifact_id>.json.zst`，
旁边 `.meta.json` 是写入时的自描述元数据。正文是 zstd 压缩的，直接看：

```bash
find data/evidence-objects -name '*.json.zst' | head
zstd -dc data/evidence-objects/t-001/investigation_report/2026/11/*.json.zst | jq .
```

注意两点：

- `data/evidence-objects` 由 `sys/scripts/init-stack.sh` 建好并给到 0777（容器内是 uid 10001）；
  **不跑 init 脚本**时 compose 会自己建一个 `root:root` 的目录，证据服务写不进去。
- 本地文件模式**不签发预签名 URL**（`:presign` 回 `501 evidence_presign_unsupported`），
  页面会自动改走 BFF 代理读（`GET /api/evidence/{id}/content`），所以「打开正文」照旧可用；
  要签名 URL（例如让外部消费者直连桶）才需要切 `s3`。

### 写探针（每 5 分钟一条真证据）

证据服务会自己每 5 分钟往写路径投一条**探针证据**（`subject_id = "_probe"`），
验证「对象 + 索引」真的写得进去；超过 24h 的探针每小时扫一次删掉。

```toml
[probe]
enabled = true
interval_secs = 300      # 投递间隔
retention_hours = 24     # 能活多久；实际每小时扫一次
# url = "http://127.0.0.1:8080/internal/evidence"   # 可选；默认由 sink 监听地址推开环地址
```

结果在证据服务 `/healthz` 的 `probe` 块里，数据场「接口可用性」页会显示成
「写探针 12 秒前成功（3 ms）」。

> 探针就是一个**小号的 wparse**：同样的 URL、同样的三字段形状。所以它验的是整条写链路
> —— 路由 → 序列化 → 对象 → 索引，而不只是「进程活着」。写端口的连通性也包含在内。
> 需要 `wist-evidence ≥ v0.1.12`（尚未发布）。

## 与其它栈的关系

- `atlas` 也可以继续由 `wist-atlas-stack` 单独跑；本栈内置一份是为了**一个入口**。
  两者不要共用同一个 PG。
- **没有 `atlas-web` 容器**：画布自 `wist-atlas-graph@0.4` 起是 field-web 的一个 React 组件
  （同一棵 React 树、同一套主题/键盘/搜索），数据经 BFF 的 `/api/atlas/*` 读 atlas。
- 本栈**不包含** `wist-center`：center 在接入区，证据/资产在计算区，两边不混。

## 本地构建镜像

```bash
./scripts/build-local.sh
# 然后把 .env 里的五个 tag 改成 dev
docker compose -f sys/docker-compose.yml --env-file .env up -d
```

## 给 WarpParse 的写入配置（可直接 copy）

三个端点和三份配置，都在 [`examples/warp-parse/`](examples/warp-parse/)（详见那里的 README）。

| 目标 | 端点 | 契约 |
|---|---|---|
| 证据 | `POST /internal/evidence` | 三字段 `{cust_id, cmd_id, content}` |
| 资产拓扑 | `POST /internal/atlas` | 两字段 `{cust_id, content}`，`content` 是 DSNAP 记录 |
| 运行指标 | `victoriametrics_sink` → `/api/v1/*` | wparse 自带的 VM sink，不是三字段 |

```text
examples/warp-parse/topology/sinks/business.d/evidence_uplink.toml
topology/sinks/business.d/atlas_uplink.toml
topology/sinks/infra.d/metrics_uplink.toml
```

> 不新增 connector：证据和 atlas 都直接复用 wp-infra 里现成的 `http_sink`
> （`connectors/sink.d/12-http_sink.toml`），sink 实例只覆盖 endpoint / fmt / headers。

拷进 wparse 工作根，配三个环境变量：

```bash
EVIDENCE_SINK_URL=http://<证据服务内网地址>:18800      # EVIDENCE_SINK_BIND_IP / PORT
ATLAS_SINK_URL=http://<atlas 内网地址>:18801           # ATLAS_INGEST_BIND_IP / PORT
WIST_METRICS_ENDPOINT=http://<本栈内网地址>:18428      # VM_BIND_IP / VM_HOST_PORT
```

> 前两行的地址就是「接入」页展示的那两条：栈里由 `EVIDENCE_SINK_PUBLIC_HOST` /
> `ATLAS_INGEST_PUBLIC_HOST`（+ 对应 `*_HOST_PORT`）渲染。现场把主机名写进
> `values/<系统>/sys_value.yml`，**与这里填的一致**，接入页就不用人工对照。

**关键前提**：连接器不做字段映射，发出去的就是 OML 的输出 —— 所以 OML 必须产出
证据的 `cust_id` / `cmd_id` / `content`，或 atlas 的 `cust_id` / `content`
（atlas 不需要 `cmd_id`：它的幂等键在快照的 `snap_id` 里）。
atlas 的 `cust_id` 是 atlas 租户 UUID，不是客户号。

### 运行指标怎么接

本栈内置一个 VictoriaMetrics，数据面用 wparse 自带的 `victoriametrics_sink` 推过来
（与 `wist-gateway-stack` 里 `infra.d/monitor.toml` 同一做法）：

```toml
[[sink_group.sinks]]
name = "metrics_vmetrics_sink"
connect = "victoriametrics_sink"

[sink_group.sinks.params]
endpoint = "${WIST_METRICS_ENDPOINT}"   # http://<field-stack 地址>:18428
```

数据场的「接口可用性」页会多一条「运行指标存储」（探 VM 的 `/health`）。
指标**不跨栈聚合**：网关栈自己的 VM 与自己本栈的 VM 是两份数据，谁写谁查。

## 容器用户与挂载权限

`evidence` / `field-api` 镜像以 **10001:10001** 运行（非 root）。挂进来的文件要让这个 uid 可读：

```bash
# 配置（不含密钥）保持 0644 即可
chmod 0644 sys/configs/evidence/*.toml sys/configs/field-api/*.toml

# 密钥：0640，属主/属组给 10001（需要 sudo）
sudo chown 10001:10001 .wist/sec-value.yml
chmod 0640 .wist/sec-value.yml
```

容器内的健康检查用**静态** busybox（`busybox:stable-musl`）：`busybox:stable` 现在要求
glibc 2.38，而镜像基础是 bookworm（2.36），会直接报 `GLIBC_2.38 not found`。
