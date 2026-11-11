# 多客户 data-field 方案（供 review）

> 状态：**M1 + M1.5 已实施**（`wist-evidence` 0.2.0 / `wist-field-api` 0.7.0 / `wist-field-web` 0.2.8 /
> `wist-field-stack` 0.4.x）；M2（凭据驱动授权）与 atlas 隔离仍未做，见 §11 已知缺口。
> 日期 2026-11-11。涉及仓：`wist-evidence` / `wist-field-api` / `wist-cred` / `wist-field-web` / `wist-field-stack`。

## 0. 一句话

`wist-field` 对外是**一个**可服务多客户的 data-field；**数据物理隔离**（每客户独立 PG + 独立对象目录）；
**使用 field 时先选客户**（不做跨客户聚合视图）。

三件事合起来的含义：客户标识不能出现在数据面（sink 只有一份投递配置），所以**分流只能发生在
服务端**，依据是写入 body 里本来就有的 `cust_id`。

## 1. 范围

| 项 | 本期 | 说明 |
|---|---|---|
| 证据（evidence） | ✅ M1 | 客户调查报告，天然按 `cust_id` 组织，是这次的主体 |
| 运行指标（VM） | ✅ M1.5 查询隔离 | 指标带 `tenant_id` label（来源：网关 `bind-tenant` → `WP_GLOBAL_TAGS`），按客户过滤即可（§5.6） |
| 选客户的授权来源 | M1.5 配置白名单 / M2 凭据 | **本期不动 `wist-cred`**：先让 BFF 从配置里的 `allowed_tenants` 取；以后再换成凭据的 `resources.tenants` |
| 资产拓扑（atlas） | ⏳ 方案已定，未实施（§5.7） | 保留 atlas 的 `tenant_id`（路由 + 审计），改“共享计算 + 每客户库”；做完前 BFF 在多客户站点直接 501 |
| 凭据摘要表 | ❌ 不分 | 它是"人"的授权表，按客户分反而查不到自己 |

## 2. 决定架构的四条事实（都已核实）

| # | 事实 | 出处 |
|---|---|---|
| 1 | 写端点 body 是三字段 `cust_id` / `cmd_id` / `content`，**`cust_id` 就是客户** | `wist-evidence/src/api/sink.rs` 文件头注释 |
| 2 | `cust_id` 已经是分区键（对象键第一段 + 索引租户列）——**单库内早就按客户分开了** | `domain/artifact.rs`、`infra/index.rs` |
| 3 | evidence 进程**一个 PG 池 + 一个对象 store**，没有多后端概念 | `infra/index.rs::connect`、`infra/object_store.rs` |
| 4 | 读端点靠 `x-evidence-tenant` 过滤，且注释明说它是"调用方自述，内网里信任" → **授权只能在 BFF 做** | `wist-evidence/src/config.rs:61` |

结论：**"跨库分离"必须改 `wist-evidence`**（只有它读得到 body），反代/网关层做不到
（它们看不到 JSON body 里的 `cust_id`）。

## 3. 隔离边界

| 数据 | 隔离粒度 | 靠什么 |
|---|---|---|
| 证据索引 | **每客户独立 PG 实例** | `[[storage.cell]]` 路由 |
| 证据正文 | 每客户独立目录 / 独立 bucket prefix | 同上 |
| 运行指标 | **单 VM**，按 `tenant_id` label 过滤 | BFF 查询注入 filter（§5.6） |
| 凭据摘要表 | 不分（单份） | — |
| cred 接入材料（`identity/`） | 不分（这个 BFF 的身份） | — |

## 4. 客户标识的三条链路

```
写：wparse ──(单端口、单配置、不带客户)──► evidence ──[按 body.cust_id 选后端]──► PG-<cust>
读：浏览器 ──(令牌 + ?tenant=)──► field-api ──[校验 ✅ 再用自己的 tenant]──► evidence(读口) ──► PG-<cust>
写：wparse ──(body.cust_id = atlas 租户 UUID)──► atlas ──[UUID 选库 / 租户]──► PG-<cust>-atlas
```

- **写侧**没有任何客户信息可依赖，只看 `cust_id`：这就是为什么分流必须在服务端。
- **读侧**的客户由 BFF 校验：**本期授权源是配置 `allowed_tenants`**（不碰 `wist-cred`），`?tenant=` 只用来"选"，不能用来"授"；校验通过后 BFF 用自己解析出的 tenant 去读。M2 再把授权源换成凭据的 `resources.tenants`（校验点不变）。
- **atlas 侧多一层编码**：它的租户是 UUID，而 evidence 的租户是客户号字符串；目前靠数据面 OML 里一行 `uuid5` 死值硬顶（换客户要改模型），且读接口完全不带租户 —— 见 §5.7。

## 5. 详细设计

### 5.1 `wist-evidence`：存储路由

配置（`wist-evidence.toml`）：

```toml
# 默认后端：未在 [[storage.cell]] 里出现的 cust_id 落这里（见 §9 决策 1）
[index]
kind = "postgres"
database_url = "${SEC_EVIDENCE_DB_URL}"

[objects]
kind = "file"                     # 或 s3
dir = "/srv/wist-field/_default/objects"

[[storage.cell]]
cust_id = "1000000000000000001"   # 与写入 body 的 cust_id 完全一致
index   = { kind = "postgres", database_url = "${SEC_EVIDENCE_DB_URL_C1}" }
objects = { kind = "file", dir = "/srv/wist-field/1000.../objects" }

[[storage.cell]]
cust_id = "1000000000000000002"
index   = { kind = "postgres", database_url = "${SEC_EVIDENCE_DB_URL_C2}" }
objects = { kind = "file", dir = "/srv/wist-field/1000.../objects" }
```

实现要点：

| 点 | 做法 |
|---|---|
| 启动 | 为 default + 每个 cell 各建一个 `(Index, ObjectStore)`，放进 `StorageRouter { default, cells: HashMap<String, Backend> }` |
| 写 | `write_records` 逐条按 `record.cust_id` 选后端（批内可能跨客户，逐条选） |
| 读 | 按 `x-evidence-tenant` 选后端（读口本来就带这个头，天然可用） |
| probe | **现状：仍只探 default 后端**（每 cell 一份尚未实现）。目标：每个后端各跑一份（租户 `_probe` 落在各自库里），这样"某个客户的库挂了"能单独发现 |
| 连接池 | 每个 cell 一个 pool，`max_connections` 默认 4（20 个客户 × 4 = 80，仍在 PG 默认 100 之下） |
| 未匹配 cust_id | 落 default + **WARN 日志带 `cust_id`**（不能丢数据；见决策 1） |
| 健康 | `/healthz` 增加 `cells: [{cust_id, index_ok, objects_ok}]` |

改动范围：`config.rs`（schema）、`infra/`（router）、`api/sink.rs`、`api/read.rs`、`probe.rs`、
`service.rs`（写/读入口签名）。**这是本次唯一"改服务核心"的地方。**

### 5.2 `wist-field-api`：多租户读

| 点 | 现在 | 改成 |
|---|---|---|
| `EvidenceConfig.tenant: String` | 单值 | `default_tenant: Option<String>`（仅当没有可选客户时用）+ `tenant` 接上 `expand()` |
| `Caller` | `{subject, roles}` | `+ tenants: Vec<String>`；**本期数据源 = 配置 `allowed_tenants`**（M2 换成凭据的 `resources.tenants`，校验点不变） |
| 多客户令牌 | — | 本期没有这个能力（一个令牌能看哪些客户由配置决定，与令牌无关） |
| 读路径 | 固定 `x-evidence-tenant: self.tenant` | 按本次请求选定的 tenant |
| `?tenant=` | 被 `strip_tenant` 丢弃 | **校验后使用**：不在可选集合 → 403 `tenant_not_allowed`（不泄露存在性） |
| 选择语义 | — | 见决策 2：多个可选但不带 `?tenant=` → 400 `tenant_required`；只有一个 → 自动 |
| 新端点 | — | `GET /api/session` → `{subject, roles, tenants}`（web 用它渲染选择器）。**故意不返回 `default_tenant`**：前端不得根据它"猜"客户，否则多客户站点会静默落错库（决策 4） |
| 覆盖范围 | `list_evidence` | **所有**读路径：`list` / `get` / `content` / `presign`（漏一个就是越权） |

### 5.3 `wist-cred`：签发（**本期不做**）

后端**已支持** `resources: BTreeMap<String, Vec<String>>`（`src/api.rs:143` 签发请求体、`store.rs`、
`push.rs` 全链路），但**本期不动 cred**：先把“一个凭据授权多个客户”放着，由 BFF 侧的
`allowed_tenants`（配置）充当过渡期的授权源（§5.2）。

以后要接真实授权时，只需把 `Caller.tenants` 的**数据源**从配置换成凭据推送的
`resources["tenants"]`，校验点与错误码不变。

### 5.4 `wist-field-web`：先选客户

```
登录(粘贴令牌) → GET /api/session
  ├ tenants.len() == 0  → 沿用现有行为（单客户站点无感）
  ├ tenants.len() == 1  → 自动进入，不显示选择器
  └ tenants.len() > 1   → 进入"选择客户"页（客户 id 列表）
        选中 → 存 sessionStorage → 之后所有 /api/evidence* 带 ?tenant=<id>
```

- 顶部展示当前客户，可切换（切换 = 换 `?tenant=` + 重置分页游标）；
- 不提供"全部客户"聚合视图（本期，理由见 §9 决策 3）。

### 5.5 `wist-field-stack`：编排

| 项 | 做法 |
|---|---|
| 每客户 PG | compose 里每客户一个 postgres 服务（手工加，命名 `field-pg-<cust>`），数据目录 `/srv/wist-field/<cust>/pg` |
| evidence | **仍然一个**（单入口），配置里 `[[storage.cell]]` 由渲染值生成 |
| 渲染值 | `init-field-config.sh` 从 values 的 `EVIDENCE_CELLS`（`cust_id→db_url 变量名/目录`）生成 cells 段 |
| 端口 | **不变**（宿主仍是那 5 个） |
| 客户增删 | 改 compose（加 PG）+ 改 values + `gops sys localize` + `gops run start` |
| 单客户站点 | 不写 `EVIDENCE_CELLS` → 配置里没有 cells 段 → 行为与 0.3.x 完全一致 |

> 注意：0.3.1 引入的 `EVIDENCE_PG_DATA` / `EVIDENCE_OBJECTS_DIR` 等变量在单客户场景继续有效；
> 多客户场景下它们只描述 **default 后端**，各客户后端由 `EVIDENCE_CELLS` 描述。

### 5.6 指标（VM）：按 `tenant_id` 过滤

指标里**确实有客户维度**：网关绑定客户时把 `tenant_id=<id>` 写进 `WP_GLOBAL_TAGS`，引擎把它盖到
所有记录上（含指标），所以 VM 里的序列带 `tenant_id` label。

因此本期做**查询隔离**，不动存储：

| 点 | 做法 |
|---|---|
| 查询 | BFF 的指标 PromQL 统一注入 `tenant_id="<当前选中客户>"`（包括 `sum by` 聚合里） |
| 客户切换 | 与证据同一个 `?tenant=`（同一个校验，不另开语义） |
| 不做的 | 按客户分 storageDataPath：VM 单实例只有一个 `storageDataPath`，写入侧是 protobuf/ndjson，
反代与 VM 都不会按 label 拆包 → 要么新加一个“指标分发器”组件，要么改 VM。收益是“每客户独立留存/删除”，
本期不需要（需要时再立项） |

**先验证一次**（部署后、写页面之前）：

```bash
curl -s http://metrics:8428/api/v1/labels | tr ',' '\n' | grep tenant_id
# 有 → 直接按它过滤；没有 → 先去查 wp-infra 的 defaults.toml / adm.oml 是否掉了 tenant_id
```

> 坑：指标的 `tenant_id`（来自网关绑定，tag-safe `[A-Za-z0-9_.:/=@+,-]{1,64}`）与证据的 `cust_id`
> **必须是同一个 ID 空间**，否则“选了客户 A，证据有、指标空”。绑定时就要对齐，不要到页面上才发现。

### 5.7 资产拓扑（atlas）：客户标识与隔离（**未实施，方案已定**）

#### 5.7.1 现状（逐条核实过）

| 事实 | 证据 |
|---|---|
| atlas 的租户是 **UUID**，不是客户号 | `crates/atlas-domain/src/common.rs:6` `pub struct TenantId(pub Uuid)` |
| 写入口把 `cust_id` **直接当 UUID 解析**，不是 UUID 就 400 | `crates/atlas-app/src/ingest_http.rs:136`，错误文案：`cust_id \`…\` is not a UUID; it is the atlas tenant id, not the external tenant ref` |
| 唯一的“客户号 → UUID”翻译，是**数据面 OML 里一行死值** | `wist-gateway-stack/sys/data-plane/models/oml/agent_uplink/agent_uplink_obs_dsnap/adm.oml:27`：`uuid5(NAMESPACE_OID, "1000000000000000001") = 40a59f7d-df92-5958-adef-61def418d257`（已验算），注释自认“换客户必须同步改这里” |
| 原始客户串 `tenant_ref` 解析进来但**不落库** | `crates/atlas-domain/src/ingest.rs:43`（`alias = "tenant_ref"`）→ 只存 `tenant_id`，无映射表 → 事后无法反查“这个 UUID 是哪个客户” |
| 读接口**完全不带租户** | `/api/hosts` → `list_all_hosts`（`crates/atlas-api/src/query.rs:232`）；`/api/services` → `default_tenant_id_async()`（库里第一个 host 的租户，`crates/atlas-app/src/http.rs:741`）；11 个 `/api/*` 读接口没有一个接受 `?tenant=`，也没有 `/api/tenants`；`wist-atlas-web` 源码里 `tenant` 零命中 |

**净效果**：现在 atlas 是“一个进程 + 一个 PG（`atlas-postgres`）+ 库内多租户”，任何持令牌的人能看到**全部客户**的拓扑；而证据侧已经在做“先选客户” —— 两边语义相反。

> 注意 storage 层其实**早就有**按租户过滤的接口（`list_hosts(tenant_id, page)`、`list_network_segments(tenant_id, page)`，见 `crates/atlas-storage/src/repositories.rs:63,74`），
> 是 HTTP 层绕开用了 `list_all_hosts`。所以“没隔离”不是缺能力，是缺接线。

#### 5.7.2 决策：保留客户 ID，采用「共享计算 + 每客户库」

**客户 ID 不删。** 它在每客户一个库之后仍然承担三件事：

| 用途 | 说明 |
|---|---|
| **路由** | 一个 atlas 进程连多个客户库时选库 —— 与 evidence 的 `Backends::for_tenant()` 同一个东西 |
| **审计 / 归属** | 库名在 dump、搬库、合并排障时会丢，只有行内的 `tenant_id` 能自证这行属于谁 |
| **库内过滤** | 物化、图构建、`service_summaries` 都按它 join；storage 层现成 |

这与 evidence 的口径一致（**先例就在本仓**）：每客户独立 PG，`evidence_artifact` 行里照样保留 `tenant_id`。

不选的两条路：

| 不选 | 原因 |
|---|---|
| 每客户一套 atlas 进程 + 一个库 | 运维碎片化（与“否决每客户一套 field 栈”同一理由）；BFF 要按客户选 `base_url`；进程与 PG 都 ×客户数 |
| OML / 网关侧做客户号 → UUID 翻译 | 等于把客户清单塞进数据面，违反“sink 不暴露客户配置”；且 OML 不能读环境变量，多客户要 N 份模型 |

**防御性收益**：每客户一个库让“忘写 `where tenant_id`”的后果从「泄露别家数据」降级成「多看了一眼自己家的」。

#### 5.7.3 目标形态

```
              ┌─ pg-c-a      （证据索引）
  evidence ───┤
  （1 进程）   └─ pg-c-b

              ┌─ pg-c-a-atlas（拓扑库）
  atlas ──────┤
  （1 进程）   └─ pg-c-b-atlas

  configs/cells/cells.json —— 唯一客户清单（两个服务共用，不各维护一份）
```

#### 5.7.4 改动清单（atlas 0.4.x，按依赖顺序）

| # | 在哪 | 改什么 | 为什么 |
|---|---|---|---|
| 1 | `atlas-app/src/ingest_http.rs` | `Uuid::parse_str` 失败时改为 `uuid5(NAMESPACE_OID, cust_id)` 派生（解析成功仍直用） | 与现有死值**完全等值**，向后兼容；数据面不必再知道 UUID |
| 2 | `atlas-domain` / storage | 落 `tenant_ref`：新增小表 `tenant(tenant_id uuid pk, tenant_ref text unique)`，ingest 时 upsert | 反查、审计、BFF 侧对齐（否则只能“猜 UUID”） |
| 3 | `atlas-app/src/http.rs` | 11 个 `/api/*` 读接口加 `?tenant=<cust_id>`，映射成 `tenant_id` 再进 storage | 把现成的 storage 过滤接上；BFF 注入方式与证据一致 |
| 4 | `atlas-api/src/query.rs` | `list_all_hosts` 收口 —— 多租户库下不允许无租户调用（只留给 probe / 运维诊断） | 防“以后又有人绕开” |
| 5 | `atlas-app` | `default_tenant_id_async()` 与 `_probe` 常量租户改为**部署给定**（配置项），不再“拿库里第一个 host 猜” | 单库多租户时代的假设，per-customer 库下会猜错 |
| 6 | atlas 侧 store 路由 | 按 `tenant` 选 store/pool（同 evidence 的 `Backends`，每 cell 一个 pool） | 一个进程连多库 |
| 7 | 栈 | `add-customer.sh` 多生成 `pg-<cust>-atlas`；`wist-atlas.toml` 渲染 cells；`<data-root>/<cust>/pg-atlas` | 一个客户清单，两套库 |
| 8 | 网关 OML | 删掉 `adm.oml` 里的 UUID 死值，改回 `read(tenant_id)` | 数据面只负责“这行属于哪个客户”，不负责编码转换 |

#### 5.7.5 短期兜底（在 1–8 做完之前）

多客户站点（`allowed_tenants.len() > 1`）时，BFF 的 `/api/atlas/*` **直接返回 501 `atlas_not_multi_tenant`**，响应体写明“atlas 尚未按客户隔离”。

理由：现在它是“看着能用、实际跨客户可见”，这种半可用状态比坏掉更危险（与“页面能开但永远 401”同一类问题）。单客户站点保持现状不动。

#### 5.7.6 契约与兼容

| 场景 | 行为 |
|---|---|
| 现有站点（数据面直传 UUID） | `parse_str` 成功 → 直用，**零改动** |
| 现有站点（数据面传 uuid5 死值） | 派生结果与死值等值 → 同上 |
| 新站点（数据面传客户号 `1000000000000000001` / `c-a`） | 派生 uuid5 → 正常入库 |
| 单客户站点 | 只有一个 tenant，读接口不带 `?tenant=` 时按该 tenant 兜底（与 evidence 的 `default_tenant` 同口径） |

**必须固化成契约**：`tenant_id = uuid5(NAMESPACE_OID, cust_id)`。写进 atlas 文档 + 一条锁定用例；这个值一旦改，等于把客户换成另一个租户。

#### 5.7.7 验收

1. 两个客户各投一份 DSNAP → 两个 atlas 库各自有 host；`/healthz` 输出 cells。
2. BFF `?tenant=c-a` 只看到 c-a 的 host/service；`?tenant=c-b` 同理；互不串。
3. 不带 `?tenant=` → 400 `tenant_required`；`?tenant=<不在白名单>` → 403 `tenant_not_allowed`（与证据同一套语义）。
4. `tenant(tenant_id, tenant_ref)` 能反查：给一个 UUID 得到客户号，反之亦然。
5. 单客户站点升级后行为不变（无 `?tenant=` 也能读）。

#### 5.7.8 风险

| 风险 | 处置 |
|---|---|
| uuid5 规则被无意改动 → 租户漂移 | 契约 + 锁定用例；派生函数只允许一处实现 |
| 一个进程 × N 库的连接数 | 每 cell 独立 pool，`max_connections` 默认 4（与 evidence 同口径） |
| 存量单库数据要迁到 per-customer 库 | 按 `tenant_id` `COPY ... TO` 再导入；probe 租户数据直接丢弃 |
| `tenant_ref` 唯一约束 | 派生冲突（不同客户号撞同一 UUID）理论不可能，但加 unique 约束让它显式失败 |

## 6. 加一个客户的完整步骤（三步，缺一不可）

| 步 | 在哪 | 做什么 | 漏了会怎样 |
|---|---|---|---|
| 1 | 栈 | 加 PG 服务 + values 里加一条 cell（cust_id / DB URL / 对象目录）。atlas 按 §5.7 实施后还要加它的拓扑库 | 该客户数据落 default 库（混库） |
| 2 | cred | 签发时把该客户加进 `resources.tenants` | 令牌看不到该客户；存储里有数据也读不到 |
| 3 | 栈 | `gops sys localize && gops run start` | 配置没生效 |

**治理**：evidence 的 cells 与 cred 的 tenants 是两份清单，可能不一致。
`/healthz` 输出 cells 清单；`gops run diagnose`（后续）对比"授权有、存储无"并告警。

## 7. 兼容与迁移

| 场景 | 行为 |
|---|---|
| 单客户站点（现状） | 不加 `[[storage.cell]]`、令牌无 `resources` → **零改动**，读走 `default_tenant` |
| 已有数据的单客户站点要变多客户 | 把现有 PG/对象目录登记为**第一个 cell**（cust_id = 现有 `EVIDENCE_TENANT`），其余客户新加 |
| 令牌升级 | 老令牌没有 `tenants` → 回落 `default_tenant`（决策 4） |

## 8. 安全

1. `?tenant=` 只在 `caller.tenants` 内生效；越界 **403 `tenant_not_allowed`**，响应体不回显该客户是否存在。
2. 浏览器传入的 tenant **绝不直接透传**给 evidence：BFF 校验后写自己的值（现有 `strip_tenant` 的意图保留，改成"校验 + 替换"）。
3. 审计：每次读记 `event=EvidenceRead subject=<credential subject> tenant=<id> path=<...>`。
4. 凭据被撤销 → 下一次请求 401（现有校验路径不变）。

## 9. 需要 review 拍板的 7 个点

| # | 问题 | 我的建议 |
|---|---|---|
| 1 | 写入遇到**未配置的 `cust_id`** 怎么办 | **落 default + WARN**（数据不能丢；严格模式做成配置项 `unknown_cust_id = "reject"`，默认不启用） |
| 2 | 多客户令牌**不带 `?tenant=`** 时 | **400 `tenant_required`**（符合"先选客户"；避免"以为看全了其实只看了第一个"） |
| 3 | 要不要"跨客户聚合列表" | **本期不做**（offset 游标要先变成 BFF 复合游标，前端也要加列；先按客户分开） |
| 4 | 既没配 `allowed_tenants` 也没 `default_tenant` 时 | 按单客户站点处理（行为与 0.3.x 一致）；如果连接索都不得不出来 → 启动日志 WARN，不阻止启动 |
| 5 | probe 每 cell 各跑一份 | **要**（否则某个客户的库写挂了不会报警）；成本 ×客户数，间隔可调。**现状：未做**，仍只探 default（见 §12） |
| 6 | PG 形态 | **每客户独立实例**（真隔离、备份/恢复按客户）；不选“同实例多 database” |
| 7 | 指标要不要**物理**分库（每客户一台 VM） | **本期不做**：单 VM + `tenant_id` 过滤已满足“选了客户只看该客户”；物理分离要新加分发器，收益只有“按客户独立留存/删除” |
| 8 | 选客户的授权来源（本期） | **BFF 配置 `allowed_tenants`**（不碰 cred）；M2 再换成凭据。风险点：它无法按“人”细分客户权限，只适合内部人手少、相互信任的站点 |

## 10. 分期与验收

### M1：数据能分开（`wist-evidence` + 栈）—— **本期**

- 验收：wparse 投 `cust_id=A` 与 `cust_id=B` → 两个 PG 库各自有行（`psql -c 'select count(*)'`），
  对象落在两个目录；`/healthz` 的 `cells` 两个都 `ok`；单客户站点升级后行为不变。
- 本阶段完成后：**数据已分离，但页面仍只能看一个客户**（BFF 还是单 `tenant`）。

### M1.5：选客户 + 指标过滤（`wist-field-api` + `wist-field-web`）

- 授权来源：BFF 配置的 `allowed_tenants`（**不碰 cred**）。语义 = “持有有效令牌的人，可以在这些客户间切”；
  与现状的 `x-evidence-tenant` 同一级别的“内网信任”，但比现在无法切换强。
- 验收：`?tenant` 不在白名单 → 403；多个可选但不带 → 400；一次进入选客户；
  切客户后证据列表与指标序列集同步变化。

### M1.7：atlas 客户隔离（`wist-atlas` + 栈，见 §5.7）

- 核心：**保留 `tenant_id`**，改成“共享计算 + 每客户拓扑库”；ingest 接受客户号（`uuid5(OID, cust_id)` 派生，与现有死值等值）；读接口加 `?tenant=`；`tenant_ref` 落库可反查。
- 验收：两客户各写一份 DSNAP → 两个拓扑库各自有 host；BFF 按 `?tenant=` 只看到自己家的；不带 → 400、越界 → 403；单客户站点行为不变。
- 完成前的兜底：多客户站点 BFF 对 `/api/atlas/*` 返回 501。

### M2：凭据驱动（**以后再说**）

- `Caller.tenants` 的数据源从配置换成 cred 推送的 `resources["tenants"]`；cred 签发页支持选客户。
- 验收：A 的令牌请求 `?tenant=B` → 403（即使 B 在白名单里）；不在请求时刷新生效（无需重启）。

## 11. 明确不做

| 不做 | 原因 |
|---|---|
| 在 sink 侧按客户分投递 | 产品要求：数据面不该知道客户清单 |
| 反代/gateway 层按客户分流 | 拿不到 body 里的 `cust_id`；指标也没有标识可用 |
| 每客户一套 field 栈（并行） | 已否决（运维碎片化）；0.3.1 的切换式保留给"客户极少但要求完全独立"的场景 |
| 指标按客户**物理**分库 | 单 VM + `tenant_id` 过滤已满足“先选客户、只看该客户”；物理分离要新加分发器，本期不做 |
| 跨客户聚合视图 | 本期不做，见决策 3 |
| 在 OML / 网关侧做“客户号 → atlas UUID”翻译 | OML 不能读环境变量/外部表，多客户要 N 份模型；等于把客户清单塞进数据面 |
| 删掉 atlas 的 `tenant_id`（假设备份库名已足够） | 库名在 dump/搬库/合并时丢失身份；指标、审计、物化 join 都还依赖它（§5.7.2） |

## 12. 已知缺口（M1/M1.5 已发版，以下是未覆盖项）

| 缺口 | 现状 | 影响 | 计划 |
|---|---|---|---|
| `/api/atlas/*` 不按客户过滤 | BFF 对 atlas 纯透传，`?tenant=` 不参与；atlas 读接口本身也不带租户 | atlas 里的资产能看到**其他客户**的 | 见 §5.7（保留 tenant_id + 每客户库 + 读接口加 `?tenant`）；完成前多客户站点 501 |
| probe 只探 default 后端 | `wist-evidence` 的探针仍只扫 default cell | 某个客户 PG 写挂了不会主动报错，只能等查询失败 | M2 顺手做：probe 对 `Backends::cells` 逐个跑 |
| 授权源是配置，不是凭据 | `allowed_tenants` 写在 `field-api.toml` | 无法按“人”细分客户权限；改白名单要改配置并重启 BFF | M2：换成 cred 的 `resources.tenants` |
| 指标过滤依赖数据带 `tenant_id` | BFF 往每个查询表达式注入 `tenant_id="…"` | 若上报侧没打这个 label，查询结果为空（不会串客户，但会“看不见”） | 部署后用 `GET /api/v1/labels` 确认 label 存在 |
