# CHANGELOG

## 0.5.3-alpha · 2026-11-12

**修一个会在重部署时弄坏客户 PG 的挂载问题**（只动栈，不动镜像）。

`evidence` 原来挂的是**整个数据根**（`${FIELD_DATA_ROOT}:/data-customers`），而客户的
PG 数据（`<数据根>/<cust>/pg`、`pg-atlas`）就在它下面。后果：

- `gops sys perms --apply` 把它们当成 evidence 的写目录，chown 成 `0:10001` + 组可写；
  PostgreSQL（uid 999）读不到自己的文件、也拒绝组可写的建库目录 → atlas 无限重启；
- 顺带把客户索引库暴露在 evidence 的写权限里，隔离本来就是假的。

修法：**对象目录按客户单独挂**。

- 主 compose 去掉 `${FIELD_DATA_ROOT}:/data-customers`；
- `configs/cells/compose.yml`（localize 从 `cells.json` 生成）为每个客户追加
  `{host_dir}/objects:/data-customers/<cust>/objects`；PG 目录只挂给各自的 PG 容器，
  不再落在任何 evidence 的挂载里。
- 新增回归：生成片段必须带每个客户的对象挂载，且主 compose 不得再出现
  `:/data-customers` 的挂载行。

升级影响：先 `gops sys localize` 重生成片段再 `gops run start`（否则 evidence 会丢掉
对象挂载 → 新建正文写不进去）。

## 0.5.2-alpha · 2026-11-12

**清掉默认库遗留的两个死旋钮**（只动栈，不动镜像）。

- 删 `EVIDENCE_TENANT`（默认值 `c-001`）：它只服务「没有客户集合时查谁」那个兜底，
  而现在客户集合就是已登记的 cell（至少一个，否则 evidence 起不来），所以它永远走不到。
  留着反而会在 `allowed_tenants` 空的时候造成一个“看起来能跑”的站点。
  连带：`[evidence] default_tenant` 不再渲染；`.env.example` / `vars.yml` / merged_vars
  同步删除（drift 用例绿）。
- 删 `.wist/sec-value.yml` 里的 `SEC_EVIDENCE_DB_URL`（默认库的 DSN，已无引用方）。
- 删两个旧命名卷 `wist-field-stack_{evidence,atlas}-pgdata`（默认库的数据，容器已在 0.5.1 移除）。
- README 的「多客户（切换式）」整节改写为「并行登记」，绑定契约改成
  `客户 ID == cells.json 的 cust_id == 数据目录名 == 数据面 payload 的 cust_id`。

## 0.5.1-alpha · 2026-11-12

**修 0.5.0 没拆干净的两处默认库依赖**（`wist-atlas` → `v0.5.1-alpha`）。

0.5.0 上线后 atlas 容器一直在重启：`serve` 虽然已经要求客户清单，但启动路径上
**先连了一个默认库**（`DATABASE_URL` 已从栈里删掉 → 它去连 `localhost:5432`）。
同一个缺口还在写探针上：探针打的是那个默认库，`/healthz` 会报绿的而实际什么都没落库。

- atlas 0.5.1：`serve` 不再连任何默认库（真正的库全来自客户清单）；
  写探针改成**每个客户各一份**，全成功才记成功。
- 栈这边只改一个镜像 tag；证据 / BFF 不变，配置不用重渲染（但还是跟着 localize 走一遍）。

## 0.5.0-alpha · 2026-11-11

**资产拓扑也按客户分开**（与证据同一个客户清单，`wist-atlas` 0.4.x 的多客户能力）。

- `add-customer.sh <cust>` 现在一次登记**两套库**：证据库 `pg-<cust>` + 拓扑库
  `pg-<cust>-atlas`（数据目录 `<数据根>/<cust>/pg` 与 `<数据根>/<cust>/pg-atlas`）。
- 拓扑租户 UUID **在登记时生成一次并固化**进 `configs/cells/cells.json`
  （`atlas_tenant_id`），之后**永不重算**；要沿用现场已有的 UUID 用
  `--atlas-tenant-id <uuid>`（从 `select tenant_id from tenant` 取）。
- 新渲染产物 `configs/atlas/cells.json`：`cust_id → {tenant_id, host, database, user}`，
  **不含口令**（口令由 compose 注入 `WIST_ATLAS_PG_PASSWORD`），所以它可以跟着
  `configs/` 备份；atlas 启动时把它幂等地播种进各库的 `tenant` 表。
- compose：`atlas` 服务新增 `WIST_ATLAS_CELLS_FILE` / `WIST_ATLAS_PG_PASSWORD` 与
  只读挂载 `./configs/atlas`。**没有清单 / 清单为空 = 单库老行为**。
- 版本：`ATLAS_IMAGE_TAG` → `v0.4.1-alpha`，`FIELD_API_IMAGE_TAG` → `v0.7.3-alpha`，
  `FIELD_WEB_IMAGE_TAG` → `v0.2.9-alpha`。
- **注销客户**：`add-customer.sh --remove <cust_id> [--purge-data]` —— 从清单 / compose 片段 /
  密钥文件移除登记；`--purge-data` 才删容器与数据目录（不可逆）。
- **资产拓扑页现在能正常显示当前客户的拓扑**：`wist-field-api` 0.7.3 用与证据同一套选客户，
  校验后把 `tenant=` 注入给 atlas；`wist-field-web` 0.2.9 让画布组件带上当前客户。
  多客户站点不再 501（单客户站点行为不变）。

### 结构收敛（客户清单只有一个产生点）

- **compose 片段的生成搬进 localize**：`configs/cells/compose.yml` 现在由
  `sys/scripts/init-field-config.sh` 从 `configs/cells/cells.json` 全量生成（与 evidence /
  atlas / BFF 的客户清单**同一个产生点**）。`add-customer.sh` 退化为「只改清单 + 提醒跑
  localize」，不再顺手写编排 —— 以前「加了客户但没跑脚本」的现场会留下两份不一致。
- **新增回归**：`dev/tests/customer-id-alignment.test.sh` 钉住 field **内部**五处客户 id 一致
  （清单 / compose 片段 / evidence cells / atlas cells / BFF `allowed_tenants`），沙箱从零
  生成 + 现场 `configs/` 双段校验；`dev/tests/add-customer.test.sh` 钉住登记是否幂等、
  注销只退登记（数据默认保留）、以及「目录末段不是 cust_id 时拒绝 `--purge-data`」。
- 口径说明：这些校验**只做 field 内部自洽**。`cells.json` 不服务中心 / 网关，客户 id 与
  网关绑定的 `tenant_id` 是否相同是网关侧的事，两套系统**没有共享校验**。

### 默认库走人（不向后兼容）

- **删掉 `evidence-postgres` / `atlas-postgres` 两个默认库容器与它们的命名卷**，
  连同 `DATABASE_URL`、`EVIDENCE_PG_DATA`、`ATLAS_PG_DATA`、`EVIDENCE_PG_HOST_PORT`、
  `ATLAS_PG_HOST_PORT`、`EVIDENCE_OBJECTS_DIR` 六个现场变量。
  它们服务的是「未登记客户的默认后端」，而现场每个客户都有自己的库 —— 那个库从头到尾
  没人读。留着它只有一个效果：让「数据落错库」这件事有可能发生。
- `wist-evidence` **0.3.0**：`[[storage.cell]]` 必填且 ≥1 条（一条 = 一个客户）；
  未登记的 `cust_id` 写入 **400 `evidence_customer_unregistered`**（不再落 fallback）；
  写探针改成**每个客户各投一条**（原来打的是保留客户 `c-probe`，没默认库后就是未登记）；
  `/healthz` 始终回显 `cells` 清单（`cust_id` + index/objects 类型，不含连接串）。
- `wist-atlas` **0.5.0**：`serve` 没有客户清单就**直接不启动**（以前落 `DATABASE_URL`）。
  单客户站点也要登记一条 cell。
- `wist-field-api` **0.7.4**：预签名能力只认 `s3`（`mixed` / `file` / 探测不到都走代理读正文）；
  `/healthz` 回显启动时的客户清单（`customers.mode` / `customers.ids` / `auth`）。
- **升级顺序**：先把客户登记齐（`add-customer.sh`）→ `gops sys localize` →
  `gops run stop && gops run start`。以前只靠默认库跑的单客户站点，必须先把自己登记成
  一个 cell（`cust_id` = 原来的 `EVIDENCE_TENANT`），否则升级后 evidence / atlas 起不来。
  启动顺序上不再 `depends_on` 客户 PG（它们是动态生成的服务）：库里没就绪时
  evidence / atlas 会重启重试，直到 PG 可连。
- 版本：`EVIDENCE_IMAGE_TAG` → `v0.3.0-alpha`，`ATLAS_IMAGE_TAG` → `v0.5.0-alpha`，
  `FIELD_API_IMAGE_TAG` → `v0.7.4-alpha`（`wist-field-web` 不变）。

> 本版本把 M1.7 的 S1–S5 全接上了；剩下 G1（网关 OML 改发客户号）—— 那一步要**和
> 切 OML 同一轮**做，不然旧 OML 发的 UUID 会被当成未登记客户拒掉（详见
> `docs/atlas-m1.7-tasks.md` §6）。

## 0.4.1-alpha · 2026-11-11

- **修 CI**：`sys/docker-compose.yml` 用 `include` 引入 `configs/cells/compose.yml`，
  而 `configs/` 是现场态（不入库）→ 干净 checkout 上 `docker compose config` 报
  `no such file or directory`，release 的 verify 阶段直接失败。
  verify 现在先用入库骨架（`sys/configs/cells/compose.yml`）铺一份再渲染。
  （本地/现场不受影响：`init-stack.sh` 本来就会兜底创建它。）

## 0.4.0-alpha · 2026-11-11

**多客户 data-field**（一栈服务多客户、数据物理隔离、使用前先选客户）。

### 新增

- **`sys/scripts/add-customer.sh <cust_id>`**：加一个客户的**一条命令**——
  建 `<FIELD_DATA_ROOT>/<cust>/{pg,objects}`、写该客户的 DB URL 密钥、维护客户清单
  `configs/cells/cells.json`、并从清单全量生成 compose 片段 `configs/cells/compose.yml`。
  客户清单放 `configs/`（protect 区）而不是 `sys/`：**升级不覆盖**。
- **compose `include`**：主 compose 引入 `./configs/cells/compose.yml`，所以客户的 PG
  仍归 `gops run start` 管（不是游离的 `docker run`）。骨架由 `init-stack.sh` 兜底创建。
- **`FIELD_DATA_ROOT`**（默认 `./customers`）：多客户数据根，容器内挂到 `/data-customers`。
- 证据服务的 `[[storage.cell]]` 由 `init-field-config.sh` 从 cells.json 渲染；
  BFF 的 `allowed_tenants` 同源渲染（避免两份客户名单分叉）。

### 跟版

`wist-evidence 0.2.0-alpha`（多客户存储路由）、`wist-field-api 0.7.0-alpha`
（`allowed_tenants` / `/api/session` / 指标按客户过滤）、`wist-field-web 0.2.8-alpha`（选客户）。

### 升级注意

- **顺序**：先升 evidence（0.2.0 之前的镜像会**静默忽略** `[[storage.cell]]`，
  数据全落 default —— 不报错、不丢数据，但也不隔离）。
- 单客户站点：不建 `cells.json` → 无 `storage.cell`、`allowed_tenants = []`，
  行为与 0.3.x 完全一致。
- 多客户站点：客户清单变了必须 `gops sys localize`（重渲 evidence/BFF 配置）再 `gops run start`。
- 指标按客户隔离依赖数据里的 `tenant_id` label（网关绑定写入）；部署后先验一次
  `curl -s http://metrics:8428/api/v1/labels | grep tenant_id`。
- 已知缺口：`/api/atlas/*` 暂不按客户过滤（atlas 租户是独立 UUID）。


## 0.3.1-alpha · 2026-11-11

- **多客户（切换式）落地**：PG / 指标 / 证据正文 / 凭据摘要表 的落点改成可覆盖变量，
  默认值**等于既有落点**（命名卷 / `./data`）——升级不会搬数据：

  | 变量 | 默认 | 多客户时 |
  |---|---|---|
  | `EVIDENCE_PG_DATA` | `evidence-pgdata`（卷） | `/srv/wist-field/<cust>/pg/evidence` |
  | `ATLAS_PG_DATA` | `atlas-pgdata`（卷） | `/srv/wist-field/<cust>/pg/atlas` |
  | `VM_DATA` | `metrics-data`（卷） | `/srv/wist-field/<cust>/vm` |
  | `EVIDENCE_OBJECTS_DIR` | `./data/evidence-objects` | `/srv/wist-field/<cust>/objects` |
  | `FIELD_API_STORE_DIR` | `./data/field-api` | `/srv/wist-field/<cust>/field-api` |

  容器 source 写成「卷名或路径」，compose 自己判断；`init-stack.sh` 会提前把路径型的
  落点建好（这是“docker 把 bind 源建成 root:root”那类问题的前置）。
- **定位明确：切换式**。一个站点一套栈、同一时刻服务一个客户；多客户 = 换落点 + 换
  `EVIDENCE_TENANT`。**不做** BFF 多租户授权（`Caller.tenants` / `?tenant=` / 聚合列表），
  也不做同宿主并行多实例（那需要先把 `name:` / `container_name` / 端口全部参数化）。
- README 新增「多客户（切换式）」：绑定契约（客户 ID = `EVIDENCE_TENANT` = 目录名 =
  数据面 `cust_id`）、切换五步、三条硬约束（先与数据面协调 / 先备份 / `perms.allow_external`）。
- `sys-prj.yml` 补 `perms.allow_external` 的声明示例（数据根在栈外时必须开）。

## 0.3.0-alpha · 2026-11-11

**结构性变更：`configs/` 从「种子拷贝」改为「模板渲染」**（与 `wist-gateway-stack` /
`wist-cred-stack` / `wist-center-stack` 同一套）。

### 为什么

旧做法是 `init-stack.sh` 按「只补缺」把 `sys/configs/` 拷到栈根 `configs/`。代价是
**栈升了、运行态那份还是旧的**：新加的配置项永远不生效，而排查时看到的是一份“看起来对”
的文件。0.2.8 加 `[metrics] write_url` 就是这么丢的 —— 种子里有、`configs/` 里没有，
接入页因此不显示运行指标写地址。

### 改了什么

- **新增 `_gal/work.gxl` + `sys/workflows/operators.gxl`**：`gops sys localize` 现在会执行
  `gx run localize`（galaxy-ops ≥ 1.3.4 / galaxy-flow ≥ 0.14）。此前本栈是纯
  `docker-compose` 类型，没有这两个文件，`localize` 找不到流程就**静默跳过**。
- **`sys/configs/` 下的四份配置改为 `*.tpl`**：
  `field-api.toml` / `cred.toml` / `wist-evidence.toml` / `nginx.conf`。
  非密钥的部署值换成 handlebars 占位符（`{{...}}`），由 `gx.tpl` 渲染成字面量；
  **`${SEC_…}` 原样保留**，仍由服务启动时从 `.wist/sec-value.yml` 展开（密钥不落盘）。
- **新增 `sys/scripts/init-field-config.sh`**：从栈根 `.env` 生成三份 `*.value.json` 渲染值
  （幂等；内容不变不碰 mtime）。之所以是脚本而不是 GXL 里的 `printf`，因为 GXL 不还原
  `\"` 而 Ubuntu 的 `/bin/sh` 是 dash —— 会写出非法 JSON，且 macOS 上看不出来。
- **新增 `sys/scripts/lib/env-defaults.sh`**：`.env` 读取器从 `init-stack.sh` 里抽出来共用。
- **`init-stack.sh` 不再拷 `configs/`**：只留目录 / 密钥文件 / 自注册 setup code /
  cred 材料自检 / web TLS；`configs/` 的权限收尾保留（所有文件 → 0644）。
  `FORCE_CONFIGS=1` 与「种子与运行态不一致」的提示**一并删除** —— 不再需要。
- **新增 `EVIDENCE_TENANT`**：`[evidence].tenant`（客户 id）原本是写死在种子里的 `c-001`，
  改成模板后必须能按站点覆盖，否则现场改了会被下一次 localize 盖回去。
- **`sys-prj.yml` 补齐现场态声明**：`configs` 进 `ignore` / `protect` / `backup`，
  `identity` 进 `contract`（web 证书 CA + cred 自注册材料，丢了要重新发券注册），
  `.wist` 进 `backup`（setup code 是随机生成的，丢了接入流程作废）。
  少了这几条，`gops prj upgrade` 回滚时按 `protect ∪ contract ∪ backup` 排除代码快照，
  `configs/` 有被当成代码一起回退的风险。

### 升级注意

- **升级后 `configs/` 会被重渲**：现场在 `configs/` 下做过的改动**会丢**。
  站点值请写 `values/<系统>/sys_value.yml`（`EVIDENCE_TENANT` / `*_PUBLIC_HOST` /
  `FIELD_API_*` 等），产品默认写 `sys/setting/vars.yml`。
- 机器上必须有 **gx**（`gx --version` ≥ 0.14）：没有的话 `gops sys localize` 会打
  `WARN: 跳过阶段流程 localize：…`，configs 不会被重渲（栈还能跑，但配置停在旧版本）。
- compose 里那一组 `EVIDENCE_READ_PORT` / `FIELD_API_*` 环境变量**这一版仍保留**：
  配置渲染被跳过时服务还能自己展开（过渡兜底）。0.4.0 删除。

## 0.2.9-alpha · 2026-11-11

- **跟版 `field-web v0.2.7-alpha`**：左下角版本号不再渲染成 `vv0.2.6-alpha`
  （CI 传的是带 `v` 的 git tag，UI 又拼了一个），且标签由 `wist-field-api`
  改为 `wist-field-web` —— 那个号是前端构建版本，和 BFF 的 0.6.x 不是一条线。
- 其余组件不变：`field-api v0.6.7-alpha` / `evidence v0.1.15-alpha`。

## 0.2.8-alpha · 2026-11-10

- **修 `init-stack.sh` 把 `.wist` 收成 `0700` 导致 evidence 起不来**：该目录是**只读挂进容器**的，
  而 `evidence` / `field-api` 以 `10001:10001` 运行；`0700`（属主 root）让容器 `stat` 不到里面的
  文件，症状是 `secrets file not found: /sec/sec-value.yml` —— 配置和密钥明明都在，只是没权限。
  现在按挂载契约给到 `2750`、属组 = 容器 gid（`CONTAINER_GID` 可覆盖）；以非 root 跑且不在
  该组时退回 `0755/0644` 让栈能起，并提示随后用 root 执行 `gops sys perms --apply` 收紧。
- **`init-stack.sh` 识别「被 docker 建成目录」的 bind 源**：先 `up` 再 init 时，缺失的
  **文件级** bind 源（如 `configs/field-api/cred.toml`）会被 docker 建成同名目录，之后
  复制被跳过、容器报 `read ...: Is a directory` / `mount ...: not a directory`。空目录现在
  自动清掉并补文件，非空则报错停下；`/cred` 下由同一挂载点产生的
  `identity/field-api/cred/cred.toml` 目录也一并清理。
- **接入页「运行指标」的写端点改为由配置生成**：`field-api.toml` 新增 `[metrics] write_url`
  （**数据面视角**的 VM 写端点，与 `atlas.sink_url` 同性质），栈变量新增
  `METRICS_SINK_PUBLIC_HOST`。三条输入通道因此各有自己的数据面主机名 ——
  证据 `EVIDENCE_SINK_PUBLIC_HOST`、资产 `ATLAS_INGEST_PUBLIC_HOST`、指标 `METRICS_SINK_PUBLIC_HOST`；
  端口仍由各自的 `EVIDENCE_SINK_HOST_PORT` / `ATLAS_INGEST_HOST_PORT` / `VM_HOST_PORT` 单点决定。
  BFF 把 `write_url + /api/v1/import` 交给接入页，**页面不再手写地址**
  （原来前端写的是 `WIST_METRICS_ENDPOINT`，与实际用的 `CONSOLE_VM_ENDPOINT` 不一致）。
- **`*_PUBLIC_HOST` 与 `*_BIND_IP` 是一对**：域名解析到站点地址、bind 却还在 `127.0.0.1` 时，
  端口只挂在 loopback 上，别的机器拨不进来。三条输入通道（18800 / 18801 / 18428）要对外时，
  必须同时把对应的 `*_BIND_IP` 设成 `0.0.0.0`。
- 组件跟版：`field-api v0.6.7-alpha` / `field-web v0.2.6-alpha`。`[metrics] write_url`
  与接入页样例对齐在这两版里 —— **不跟版时这几项配置不生效（也不会报错）**。
  其余不变：`evidence v0.1.15-alpha`。

## 0.2.7-alpha · 2026-11-09

- **跟版 `field-api v0.6.6-alpha`**：`[verify].audience` 支持 `${…}` 展开。
- **新增栈变量 `FIELD_API_AUDIENCE`**（产品默认 `wist-field-api`）：认证系统名是
  部署事实 —— 它必须等于 cred 侧那个 peer 的名字，不同站点往往不同名（例：`local-field-alpha`）。
  现在在 `values/<系统>/sys_value.yml` 里设一次就行，不用再改 `configs/field-api/cred.toml`
  （那份是现场态，升级也不会被覆盖，容易忘而得到 401 `audience_mismatch`）。
- **已有站点要注意**：现场 `configs/field-api/cred.toml` 里如果写的是字面量（`wist-field-api` 或
  别的名字），继续用没问题（字面量原样生效）。想改由变量管就把那行换成
  `audience = "${FIELD_API_AUDIENCE}"`（或 `FORCE_CONFIGS=1 bash sys/scripts/init-stack.sh`），
  并在 `values/` 里设 `FIELD_API_AUDIENCE`，然后 `gops sys localize && gops run start`。

## 0.2.6-alpha · 2026-11-09

- **`init-stack.sh` 现在自己读栈根 `.env`**（显式传入的环境变量优先）。以前手工跑只会
  回落 `WEB_DOMAIN=localhost`，web 叶证书签成 `SAN: localhost` —— 看起来“证书有了”，
  实际与站点域名不符（浏览器报名字不符，cred 拨号也会证书校验失败）。不 `source` 而是逐行解析，
  `.env` 里的内容不会被当作 shell 执行。
- **修正 `.wist/sec-value.yml` 的路径**：README / compose / evidence 配置注释写的是
  `sys/.wist/...`，实际读取的是**栈根** `.wist/...`（compose 挂 `./.wist:/sec:ro`，
  `init-stack.sh` 也只检查栈根）。按旧文档放文件会得到
  `secrets file not found: /sec/sec-value.yml`，evidence 无限重启。
- 组件版本不变：`field-api v0.6.5-alpha` / `field-web v0.2.5-alpha` / `evidence v0.1.15-alpha`。

## 0.2.5-alpha · 2026-11-09

- **「接入」页展示的写端点不再硬编码 `127.0.0.1`**：新增栈变量
  `EVIDENCE_SINK_PUBLIC_HOST` / `ATLAS_INGEST_PUBLIC_HOST`（产品默认 `127.0.0.1`，与原行为一致）。
  `field-api.toml` 的 `[integration].sink_url` / `[atlas].sink_url` 改为
  `http://${*_PUBLIC_HOST}:${*_HOST_PORT}` 渲染 —— 不同部署实例（各站点 / 各客户的域名或
  内网地址）在 `values/<系统>/sys_value.yml` 里填一次就行，不用再改配置文件。
- 端口仍只有一个来源：证据写端口 `EVIDENCE_SINK_HOST_PORT`、资产写端口 `ATLAS_INGEST_HOST_PORT`。
- **已有站点要注意**：现场 `configs/field-api/field-api.toml` 是 `init-stack.sh` 从 `sys/configs/`
  复制出来的现场态，升级**不会**覆盖它。想用新变量就同步这份种子
  （`cp sys/configs/field-api/field-api.toml configs/field-api/field-api.toml`，
  或 `FORCE_CONFIGS=1 bash sys/scripts/init-stack.sh`），然后 `gops sys localize && gops run start`。
  没同步的旧配置照样能跑（继续用硬编码地址），不受影响。
- 组件版本不变：`field-api v0.6.5-alpha` / `field-web v0.2.5-alpha` / `evidence v0.1.15-alpha`。

## 0.2.4-alpha · 2026-11-09

- **发布对齐 `wist-cred-stack`**：打 tag 后自动产部署包（`wist-field-stack-<tag>.tar.gz`）、
  建 GitHub Release，并把同一个包同步到 COS（`<prefix>/<tag>/` 与 `<prefix>/latest/`，
  带 `x-cos-meta-artifact-sha256` 元数据）。`<prefix>` 默认 `wist-field-stack`，由 `COS_PREFIX` 覆盖。
- **`sys/merged_vars.yml` 改为入库文件**：改 `sys/setting/vars.yml` 后跑 `gops sys update`，
  两份一起提交（部署包靠 `git archive` 带它走）。
- **`.env.example` 与 `sys/merged_vars.yml` 逐键对齐**（新增 `dev/tests/env-example-drift.test.sh`，
  CI 用的就是这份 `.env.example` 渲染 compose）；新增 `dev/lint.sh`（shellcheck 两道门）。
- 组件版本不变：`field-api v0.6.5-alpha` / `field-web v0.2.5-alpha` / `evidence v0.1.15-alpha`。

## 0.2.3 · 2026-11-09

- **发布火车**：`field-api v0.6.5-alpha` + `field-web v0.2.5-alpha` + `evidence v0.1.15-alpha`。
- **证据按调查命令 id（`cmd_id`）读与筛**：详情 / 预签名 / 正文代理读的路径 key 接受
  `cmd_id`（发起调查的人手里只有这个）；列表支持 `?cmd_id=`，页面查询栏以它为主位，
  列表新增「命令 id」列。
- **「接口可用性」页拆成三个 tab**（探活结果 / 证据读取 API / 资产拓扑 API）：
  页面不再维护第二份接口清单；证据读接口清单由 BFF 自己输出的 OpenAPI 提供。
- **资产拓扑画布组件化**：删除 `atlas-web` 容器与 nginx 的 `/atlas/` 反代，数据统一走
  BFF 的 `/api/atlas/*`；画布升到 `wist-atlas-graph 0.5.1`（网络归属过滤、选中 2 秒快捷操作等）。
- **atlas 读接口要令牌**：新增栈变量 `ATLAS_API_TOKEN`（产品默认是**空串** —— atlas 拿到空串
  会拒绝启动，读接口不允许“谁都能读”）。现场在 `values/<系统>/sys_value.yml` 给一个随机值；
  compose 同时以 `WIST_ATLAS_TOKEN` 传给 atlas、以 `SEC_ATLAS_API_TOKEN` 传给 field-api
  （对应的 `[atlas] auth_token`）。
- **只保护读接口**：`/healthz`、`/internal/atlas`（数据面写入，已只绑环回）、
  `/api/openapi.json`、`/api/docs` 仍然不要令牌。
- **已有站点要注意**：现场 `configs/` 是 `init-stack.sh` 从 `sys/configs/` 副本出来的
  （gitignore 的现场态）。升级后要把 `[atlas] auth_token = "${SEC_ATLAS_API_TOKEN}"` 同步进
  现场的 `configs/field-api/field-api.toml`，否则 BFF 手里没有令牌，atlas 会回 401。
- **开发**：`dev/dev-image.sh` 支持 `--evidence`，证据服务的改动也能用本地镜像验证。

## 0.2.2 · 2026-11-07

- 跟版 `field-api v0.6.4-alpha` + `field-web v0.2.4-alpha`。
- **「运行指标」页改成四层表达**：`1 · 业务层` → `2 · 服务层` → `3 · 中间件层` → `4 · 计算资源层`。
  业务层的主机归属来自 `sys/configs/field-api/field-api.toml` 的 `[[business.units]]`
  （配置里给了注释模板，默认未启用）—— **不下沉到数据面**，改归属不用重启 wparse / agentd。
- 中间件层当前是空态：`container_*` / `kafka_*` 有契约，等 agentd 开 provider。
- 接口只做加法：`/api/metrics` 多 `business` / `unassigned_agents` 两个字段，原有字段与语义不变。

## 0.2.1 · 2026-11-07

- 跟版 `field-api v0.6.3-alpha` + `field-web v0.2.3-alpha`。
- **「运行指标」页补上主机侧**：主机名 / IP / OS / 架构、负载（1m/5m/15m）、内存使用率、
  系统盘使用率与容量、最紧张的挂载点、运行时长、进程数；趋势从 4 张变 8 张（主机四条在前）。
- 接口只做加法：`/api/metrics` 的每个 agent 多一个 `host` 块，原有字段与语义不变。


## 0.2.0 · 2026-11-06

- **改名：`wist-console-stack` → `wist-field-stack`**：仓名、compose 项目名、容器名
  （`wist-field-stack-*`）、网络内服务名（`console` → `field-api`）全部跟着改；镜像跟版
  `wist-field-api v0.6.1-alpha` + `wist-field-web v0.2.1-alpha`（web 反代上游已改成
  `field-api:8080`）。这两个版本只是把发版流水线换成原生分架构构建，镜像内容与
  0.6.0 / 0.2.0 一致。
- **变量与路径全部改名**：`CONSOLE_REGISTRY` / `CONSOLE_IMAGE_TAG` / `CONSOLE_WEB_IMAGE_TAG`
  → `FIELD_REGISTRY` / `FIELD_API_IMAGE_TAG` / `FIELD_WEB_IMAGE_TAG`；
  `CONSOLE_ADVERTISE_HOST` / `CONSOLE_CRED_URL` / `CONSOLE_CRED_CA_FILE` /
  `CONSOLE_CRED_INSECURE_TLS` / `CONSOLE_REQUIRE_CRED_SIGNATURE` → `FIELD_API_*`；
  `configs/console` → `configs/field-api`、`console.toml` → `field-api.toml`；
  `identity/console/cred` → `identity/field-api/cred`；`data/console` → `data/field-api`
  （容器内 `/var/lib/wist-field-api`）。站点 `values/` 里的同名项要一起改。
- **凭据侧也改名（= 一次重新接入）**：cred 认证系统 audience 改为 `wist-field-api`，
  密钥项改为 `SEC_FIELD_API_PEER_SETUP_CODE`，ingress 操作员头改为 `x-field-operator`。
  旧 `wist-console` 认证系统的令牌与摘要不再可用；在 cred 里新建 `wist-field-api` 系统、
  重新签发令牌即可，**不需要改代码**。
- **卷与数据不复用**：项目名变了，卷名随之为 `wist-field-stack_*`。旧的
  `wist-console-stack_*`（PG / VM 数据）留在宿主上不再被引用，确认不要后
  `docker volume rm` 自行清理。
- **升级步骤**：
  1. 先停旧栈：`gops run stop`（或 `docker compose -p wist-console-stack down`，别加 `-v`）；
  2. `bash sys/scripts/init-stack.sh`（补 `SEC_FIELD_API_PEER_SETUP_CODE`、建
     `data/field-api` 与 `identity/field-api`）；
  3. `gops sys localize` → `gops run start`；
  4. 打开页面走 `/__init` 重新接入，然后用新令牌登录。

## 0.1.30 · 2026-11-06

- 跟版 `console v0.5.0-alpha` + `console-web v0.1.17-alpha` + `evidence v0.1.14-alpha`（把 0.1.29 之后的两版一起带上）。
- **展示名改为「数据场 · 现场视图」**（原「星象台」）：现场由三类信号构成 —— 发生过什么（证据）、
  由什么构成（资产）、现在跑得怎样（指标）。只读，不动手；仓名 / 镜像名 / 服务名不变。
- 顺便跟上的两个能力：`console` 新增 `GET /api/evidence/capabilities`（证据后端自述，
  证据页据此选正文通路，不再先撞 501 再回落）；`console-web` 的运行指标页对齐“场”的口径
  （静默 = 场缺一块，不是值为 0）。
- `evidence` 的 `/healthz` 多一个 `objects.kind`（部署自述）：本地文件存储下证据页直接走
  BFF 代理读，不再先发一个必然 501 的 `:presign`。新增字段，老调用方不受影响。

## 0.1.29 · 2026-11-06

- 跟版 `console v0.4.0-alpha` + `console-web v0.1.15-alpha`。
- **「运行指标」页上线**：不再是一个占位页。数据面把 agent 采集指标镜像进本栈的
  VictoriaMetrics（网关栈的 `CONSOLE_VM_ENDPOINT`），页面读这一份：概览（指标名 / 序列 /
  在报 agent / 采集窗口）、Agent 自观测表、单机四条趋势、按前缀折叠的指标目录。
- **口径边界写清楚**：引擎 / 管道统计（`wparse_*`）只写网关栈那份 VM，本页不展示；
  序列数比网关栈少是正常的。没配 `[metrics] base_url` 时 BFF 回 `503 metrics_not_configured`，
  页面会直接说缺哪项配置。

## 0.1.28 · 2026-11-05

- 跟版三个**只为同步 TCR 而重发**的镜像（代码零变更）：
  `EVIDENCE_IMAGE_TAG` → `v0.1.13-alpha`、`ATLAS_IMAGE_TAG` → `v0.3.3`、
  `ATLAS_WEB_IMAGE_TAG` → `v0.1.3-alpha`。
- 背景：它们的旧 tag 早于 release 工作流增加 TCR 推送，所以 TCR 上根本没有——
  栈切到 `CONSOLE_REGISTRY=/ATLAS_REGISTRY=dy-sec.tencentcloudcr.com/cloud` 时
  就是 `manifest unknown`。现在五个业务镜像（console / console-web / evidence / atlas / atlas-web）
  在两个源上都有。

## 0.1.27 · 2026-11-05

- 跟版 `console v0.3.1-alpha` + `console-web v0.1.14-alpha`。
- **接入配置简化**：证据 / 资产拓扑的示例不再新增 connector，直接复用现成的 `http_sink`
  （只覆盖 endpoint / fmt / headers），示例从五个文件减到三个。
- 「数据面接入」页按证据 / Atlas / 运行指标分开；顶部状态条新增「退出」。

## 0.1.26 · 2026-11-05

- 修 0.1.25 的一个手误：跟版 `console-web` 时把 `EVIDENCE_IMAGE_TAG` 也从
  `v0.1.12-alpha` 改成了 `v0.1.13-alpha`（而证据服务没发这个版本），
  结果 `gops run start` 在拉镜像时 `manifest unknown`。现已改回 `v0.1.12-alpha`。
- 只有这一个变量变了，其它镜像 tag 与 0.1.25 一致。

## 0.1.25 · 2026-11-05

- 跟版 `console v0.3.0-alpha` + `console-web v0.1.13-alpha`。
- **登录端点**：`POST /api/login`（契约由 `wist-cred-peer` 0.5 统一）—— 令牌 → 
  `{subject, roles, expires_at}`；前端因此能把「令牌不对」与「角色不够」分开说。
  其它接口仍然每请求带 Bearer，没有引入 session。
- console 侧修了 0.2.0 的**自注册启动死锁**（强制验签 + 公钥随注册下发 ⇒ 原本永远进不了 `/__init`），
  并把“运行中删掉身份材料”“client CA 读不了”这类降级状态提到启动期/页面上。
  所以 `CONSOLE_REQUIRE_CRED_SIGNATURE` 现在可以安全地开回 `true`（首次启动会 WARN 一句
  “验签延后”，注册完成后重启即强制）。
- web 侧：导航拍平为两段、概览只留“四域接没接上”、接口可用性页显示接口真实地址。

## 0.1.24 · 2026-11-05

真机起栈时踩的三个坑，都补上了：

- **console 容器缺 `CREDENTIALS_HOST_PORT`**：模板里的收数地址是
  `https://${CONSOLE_ADVERTISE_HOST}:${CREDENTIALS_HOST_PORT}/…`，变量不进容器就展不开，
  启动期直接拒（`unresolved environment variable`）—— fail-closed 是对的，但栈得把变量给足。
- **`SEC_CONSOLE_PEER_SETUP_CODE` 没有来源**：`init-stack.sh` 现在幂等生成
  （`crp_` + 32 hex，写入 `.wist/sec-value.yml`，0640）并提示去 `/__init` 填；
  不自动生成就只能自己编，那必然是弱口令。
- **种子 vs 运行态静默偏差**：`sys/configs/` 只补缺不覆盖，于是“栈升了、nginx 还是旧的”
  表现为 `/__init` 直接掉回 SPA。现在逐文件比对并列出差异，
  `FORCE_CONFIGS=1` 才覆盖（现场改过的端口/域名不会被默默冲掉）。

## 0.1.23 · 2026-11-05

- 跟版 `console v0.2.1-alpha`：修了 0.1.22 里那两处「配了但没生效」——
  `[publish].endpoint` 的 `${VAR}` 不展开、布尔开关只认字面值。
- 模板与 compose 对齐：`insecure_tls` / `require_signature` 改成**字符串**形式
  `"${CONSOLE_…}"`（BFF 启动时用“密钥文件 + 进程环境”展开），
  并把 `CONSOLE_*` 与 `CREDENTIALS_HOST_PORT` 真正传进 console 容器 ——
  否则模板里的 `${CONSOLE_ADVERTISE_HOST}` 永远是一串字面占位符。

## 0.1.22 · 2026-11-05

- **星象台自己向 cred 注册（P1）**：`console v0.2.0-alpha` + `console-web v0.1.12-alpha`。
  栈渲染 `[init]` + `[publish]`，首次启动只开 `/__init`：填 setup code + 接入券就完成登记，
  材料落进 `identity/console/cred/`，收数监听**自己起来**（不需要重启、也不需要再跑 join.sh）。
- 新变量：`CONSOLE_CRED_URL` / `CONSOLE_ADVERTISE_HOST` / `CONSOLE_CRED_CA_FILE` /
  `CONSOLE_CRED_INSECURE_TLS` —— 换注册入口、换信任锚、确知跳过校验都不用改配置文件。
  `CONSOLE_ADVERTISE_HOST` 空着时 console **启动期就拒**（地址会渲染成 `https://:18802/…`）。
- 前端：未接入时不再「满屏 503」，而是一页说清下一步并直给 `/__init`。
- `identity/` 下的材料（含 `server.key` 与 web CA 私钥）**移出版本库**；
  README 的接入流程按自注册重写，并把已从 cred 侧删除的 `--advertise` 清掉。

## 0.1.21 · 2026-11-05

- console `v0.1.13-alpha`：「接口可用性」多一条 **访问凭据（wist-cred）** ——
  `已登记 N 条凭据；收数监听在线` / `一条凭据都没登记（检查 cred 侧 endpoint）` /
  `收数监听不在运行`。凭据推送不通时，页面上一眼能看见，而不是满屏 401。

## 0.1.20 · 2026-11-05

- 接入说明修了一次真实的踩坑：`join.sh` 少给 `--advertise` 时，cred 的 peer 记录里
  **没有 endpoint**，表现成「已注册」但既不推送也不心跳；`peers.json` 里那条是空壳。
  README 现在把四个参数（`--dir` / `--host` / `--advertise` / `--roles`）和各自不给的后果
  写全，并说明 `CREDENTIALS_BIND_IP` 必须是 **cred 能到达的地址**（回环只有本机能连）。
- `init-stack.sh` 增加材料自检：audience 是不是 `wist-console`、`[verify].roles` 有没有
  `read`、`server.crt` 的 SAN 覆不覆盖本机名 —— 三种都会表现成「一切都对但永远 401」。
- 顺带修：脚本里提示文案中的反引号会被 shell **真的执行**（`gops sys perms --apply` 被跑了一次），
  改用单引号。

## 0.1.19 · 2026-11-05

- 修 0.1.18 的两个装不起来的问题：
  1. 凭据材料原来挂到 `/etc/wist-console/cred`（只读配置挂载的**子目录**），docker 在只读层里
     建挂载点会失败（`mkdirat ... Read-only file system`）→ 改挂顶层 `/cred`，
     `credentials.file = "/cred/cred.toml"`；
  2. `identity/console/cred` 目录缺失时同样起不来 → `init-stack.sh` 先建好。
- `server.key` 由接入命令写成 0600，而容器以 **uid 10001** 读它：`init-stack.sh` 不再擅自
  chmod，改为提示跑 `gops sys perms --apply`（Linux）。

## 0.1.18 · 2026-11-05

- **资产拓扑的数据面收进 BFF**：`/atlas/api/*` 不再由 nginx 直连 atlas-web，而是
  `/atlas/api/x → console /api/atlas/x → atlas /x`。以前 `/atlas/api/hosts` 不带令牌就能
  拿到全部主机，等于给令牌认证开了个后门。
  配套：atlas-web 读宿主页同一个 `sessionStorage` 令牌（`v0.1.2-alpha`），console-web
  两条 location 显式透传 `Authorization`（`v0.1.11-alpha`）。
- **浏览器入口上 TLS**：`web` 容器在 443 上终结 TLS（80 只留给容器健康检查、不发布到宿主）。
  证书由 `sys/scripts/init-web-tls.sh <域名>` 生成两级材料（web CA + 叶）到 `identity/web/`，
  `init-stack.sh` 幂等调用；`WEB_HOST_PORT` 现在指 **HTTPS**。
  访问令牌是 bearer，明文入口等于把凭据写在网线上 —— 这条不再可选。
- `WEB_DOMAIN` 变量：证书 SAN 里的域名（SAN 同时带 `localhost` 与 `127.0.0.1`）。
- console `v0.1.11-alpha` / console-web `v0.1.11-alpha` / atlas-web `v0.1.2-alpha`。

## 0.1.17 · 2026-11-05

- **认证改成接 `wist-cred`（`auth.mode = "cred"`），删掉 0.1.16 的 `dev` 直通**。
  `dev` 是个安全问题：计算区界面默认谁都能进，且审计里没有操作员身份。
  现在浏览器要用 `wcr_…` 访问令牌，BFF 用 `wist-cred-peer` 的摘要表验（401/403 分开）。
- `console` 新增 mTLS 收数端口 `${CREDENTIALS_BIND_IP}:${CREDENTIALS_HOST_PORT}`（默认 18802），
  材料挂 `./identity/console/cred`（由接入命令写入），摘要表落 `./data/console/`。
- `init-stack.sh` 会建 `data/console` 并检查 `identity/console/cred/cred.toml`：
  缺材料时**明确提示**（console 会拒启，不是静默降级）。
- console `v0.1.11-alpha` / console-web `v0.1.10-alpha`。

## 0.1.16 · 2026-11-05

- **修：浏览器直接打开时会得到 `401 console_operator_missing`**。根因是种子里的
  `auth.mode = "ingress"`（要入口注入 `x-console-operator`），而本栈的唯一入口只绑回环，
  根本没有反代。现在种子改成 `dev`：`http://127.0.0.1:8088/` 直开即用。
- 切回 `ingress` 的条件写进了 `console.toml` 注释与 README：**把 `WEB_BIND_IP` 改成
  非回环地址之前必须先切**，否则要么打不开、要么审计里没有操作员身份。

## 0.1.15 · 2026-11-05

- **证据 / 资产两条写入链路语义对齐**（都是「谁的 + 内容」，无认证）：证据是
  `{cust_id, cmd_id, content}`，资产是 `{cust_id, content}` —— atlas 没有「命令」这个对象，
  用快照自己的 `snap_id` 判重，所以不强制一个不参与判重的 `cmd_id`。
  atlas 新增 `POST /internal/atlas`（`content` 是 DSNAP 记录），宿主端口
  `${ATLAS_INGEST_BIND_IP}:${ATLAS_INGEST_HOST_PORT}`（默认 18801）。
- **集成 VictoriaMetrics**（`metrics` 服务，默认宿主 18428）：数据面用 wparse 自带的
  `victoriametrics_sink` 推进来，星象台的「接口可用性」多一条「运行指标存储」。
  做法与 `wist-gateway-stack` 一致（同一套镜像与 base 参数）。
- atlas 开启**写探针**（`ATLAS_PROBE`，默认 on，5 分钟一条）：往保留租户
  `00000000-0000-4000-8000-00000000a7a5` 写一份最小快照，`/healthz` 带 `probe` 块；
  不变的是图谱不脏（固定 `snap_id`，同一次 upsert）。
- 示例配置多了两个文件：`connectors/sink.d/40-atlas_sink.toml`、
  `topology/sinks/business.d/atlas_uplink.toml`、`topology/sinks/infra.d/metrics_uplink.toml`。
- console `v0.1.10-alpha`：`[metrics] base_url` 探活、`[atlas] sink_url` 接入示例。

## 0.1.14 · 2026-11-05

- **证据服务的写入契约改成三字段** `{cust_id, cmd_id, content}`（evidence `v0.1.12-alpha`）：
  不再有站点 token、`[sink].auth`、旧信封（`IVSREP`）—— 尚未上线，不留兼容分支；
  认证改由 P1 的 HTTPS 双向认证接管。`sec-value.yml` 不再需要 `SEC_EVIDENCE_SINK_TOKEN`。
- 证据服务新增**写探针**（每 5 分钟一条真证据，24h 自动清），`/healthz` 的 `probe` 块
  被星象台「接口可用性」页读出来显示（console `v0.1.9-alpha`）。
- console-web `v0.1.9-alpha`：修「页面能开、所有 `/api` 挂掉」—— 上游容器重建后 nginx
  拿着旧 IP 不再重新解析；现在 `/api` 与 `/atlas/` 都能自动跟上。
- 证据读端口收敛成**一个栈级变量** `EVIDENCE_READ_PORT`（默认 `8443`）。
  之前 `8443` 硬编码在三处（evidence 的 `[read].listen_addr`、compose 健康检查、
  console 的 `evidence.base_url`），改一个就得手动改另外两个。
- 注意：运行态 `configs/evidence/wist-evidence.toml` 与 `configs/console/console.toml`
  需要同步成 `${EVIDENCE_READ_PORT}`（init 脚本只补缺不覆盖）。

## 0.1.13 · 2026-11-04

- console `v0.1.8-alpha`：代理读正文的响应补 `cache-control: no-store` 与
  `x-content-type-options: nosniff`（证据正文不进浏览器 / 中间代理缓存）。
- 说明：该镜像的 CI Release 卡在 GitHub macOS arm64 runner 容量
  （`job was not acquired by Runner of type hosted`），本次是用同一提交的 CI 产物
  在本地构建出的同名镜像；runner 恢复后以 CI 产物为准（同一提交，内容一致）。

## 0.1.12 · 2026-11-04

- 「打开正文」在本地文件存储下也能用了：evidence `v0.1.10-alpha` 新增
  `GET /internal/evidence/{id}/content`（代理读正文），console `v0.1.7-alpha` 把它接到
  `/api/evidence/{id}/content`，console-web `v0.1.8-alpha` 在预签名不可用时自动降级到这条路。
- evidence `v0.1.10-alpha` 另外：索引有、对象没了回 502（不是 404）；5xx 不回显后端路径。

## 0.1.11 · 2026-11-04

- 证据正文改成**两种落点**（`wist-evidence v0.1.7-alpha`）：
  - 默认 `objects.kind = "file"`：宿主 `./data/evidence-objects/`，重启不丢，
    可直接 `find` / `zstd -dc` 看（测试与现场核对用）；
  - 生产切 `objects.kind = "s3"`（腾讯 COS / MinIO），支持 60s 短签名 URL。
- `init-stack.sh` 建好 `data/evidence-objects` 并给到 0777（容器内 uid 10001）；
  不先建目录的话 compose 会建一个 `root:root` 的，证据服务写不进去。
- **已知差异**：本地文件模式不签发预签名 URL，页面「打开正文」会回
  `501 evidence_presign_unsupported`（要看正文直接读文件，或切 s3）。

## 0.1.10 · 2026-11-04

- console-web `v0.1.7-alpha`：「接口可用性」页删除「怎么读这张表」一节。

## 0.1.9 · 2026-11-04

- console `v0.1.6-alpha`、console-web `v0.1.6-alpha`：星象台新增「**接口可用性**」页（`#/health`）——
  逐条探活证据读端点 / 证据写端点 / 资产拓扑 API，带状态、延迟、最近检查与本次会话可用率，
  支持「立即检查」。证据读端点改为**真读**探活（鉴权 + PG 索引都会走到）。

## 0.1.8 · 2026-11-04

- console `v0.1.5-alpha`、console-web `v0.1.5-alpha`：星象台概览页新增「接口可用性」——
  证据读端点 / 证据写端点 / 资产拓扑 API 逐条探活，带状态、延迟、最近检查时间。
- `sys/configs/console` 增加 `integration.sink_health_url = "http://evidence:8080/healthz"`：
  写端点（数据面视角的 `sink_url`）BFF 到不了，探活另走容器网络里的写监听（8080）。

## 0.1.7 · 2026-11-02

- console-web `v0.1.4-alpha`：修「数据面接入」页版式（codeblock 结构）、四个页面与页头对齐、
  证据筛选条改用独立栅格。

## 0.1.6 · 2026-11-02

- 星象台新增「数据面接入」页（`#/ingest`）：写端点 / 认证 / 允许的 kind，
  以及连接器、sink 分组、环境变量三段可一键复制的配置（由 BFF `GET /api/integration` 生成）。
- console `v0.1.4-alpha`、console-web `v0.1.3-alpha`；`sys/configs/console` 增加 `[integration] sink_url`。

## 0.1.5 · 2026-11-02

- 新增 [`examples/warp-parse/`](examples/warp-parse/)：可**直接 copy** 的连接器 + sink 分组，
  配 `EVIDENCE_SINK_URL` / `EVIDENCE_SINK_TOKEN` 即可把 `IVSREP` 写进证据库。
- 证据服务升到 `v0.1.6-alpha`（写端点支持 Basic：`username` = 站点 token）。

## 0.1.4 · 2026-11-02

- 跟进展示名「**星象台 · 证据与观测**」（console-web `v0.1.2-alpha`）；
  「运维台」字样全部去掉，避免承诺不存在的操作能力。

## 0.1.3 · 2026-11-02

- 跟进上游改名：「采集量」→**运行指标**（console `v0.1.3-alpha` 的 health 键 `metrics`、
  console-web `v0.1.1-alpha` 的路由 `#/metrics`）。

## 0.1.2 · 2026-11-02

- 修 gops 下的运行态路径：`gops` 用**栈根**作为 compose 的 project directory，
  所以 `./configs` / `./.wist` 在栈根；新增 `sys/scripts/init-stack.sh` 把 `sys/configs` 种子复制过去（只补缺）。
- `EVIDENCE_PG_PASSWORD` / `ATLAS_PG_PASSWORD` 进 `sys/setting/vars.yml`：
  不进 vars 的话 `gops sys localize` 生成的 `.env` 会丢它们，容器会拿到空串。
- README 补充：手动 `docker compose` 也要带 `--project-directory .`，否则挂载指错。

## 0.1.1 · 2026-11-02

- 镜像 tag 跟进上游：`wist-evidence v0.1.5-alpha`（原生编译 + 镜像只打包）、
  `wist-console v0.1.2-alpha`（同一构建方式）。
- 已在本机完成端到端验证：写入 → 索引 → 列表/详情 → 60s 短签名；`/atlas/` 子路径反代正常。

## 0.1.0 · 2026-11-02

首个骨架：计算区一体化编排（证据 + 资产拓扑 + 运维台）。

- 组件：`web`（console-web）、`console`（BFF）、`evidence`、`atlas`、`atlas-web`、两个独立 PG；
- 浏览器只接触 `web`；`evidence` 的写端口（数据面 `http_sink` 直投）是唯一需要内网开放的接口；
- 证据服务的 sink token 以 `${SEC_...}` 作为**键**，明文不落配置文件；
- 两个 PG 刻意分开（证据与资产生命周期不同）；
- 镜像 tag 各自独立（五个仓分别发版），默认 alpha；
- 已知限制：`objects.kind = "memory"` 为默认值（重启即丢），生产要切 COS；
  `console` 的 `ingress` 模式要求入口注入 `x-console-operator`。
