# atlas 客户隔离（M1.7）实施清单

> 方案依据：`docs/multi-customer.md` §5.7（尤其 §5.7.9「为什么不在运行时派生」）。
> 本文是**可执行拆分**：每个任务给出落点文件、签名/格式、验收与依赖。

## 0. 边界

| 做 | 不做 |
|---|---|
| 数据面只发 `cust_id`；atlas 按配置解析租户 | 把 `tenant_id` 列类型从 `uuid` 改成 `text`（22 表 / 10 约束 / 732 处引用，本轮明确不动） |
| 每客户一个拓扑库（共享一个 atlas 进程） | 每客户一套 atlas 进程 |
| 读接口加 `?tenant=`，storage 的现成过滤接上 | 跨客户聚合视图 |
| 租户 id **注册时生成并固化** | 运行时 `uuid5` 派生 |

**总依赖顺序**：A1→A2→A3→A4（写侧可用）→ A5→A6→A7→A8（读侧隔离）→ S1→S2→S3（栈出库）→ S4/B1（BFF）→ G1（数据面切客户号）。

---

## 1. 任务总览

| ID | 仓 | 任务 | 依赖 | 规模 |
|---|---|---|---|---|
| A1 | `wist-atlas` | `cells` 配置加载（文件格式 + 启动校验） | — | M |
| A2 | `wist-atlas` | `CellRouter`：按 `cust_id` 选 store + 启动时播种 `tenant` 表 | A1 | M |
| A3 | `wist-atlas` | 迁移 `0007_tenant_registry.sql` | — | S |
| A4 | `wist-atlas` | 写入口：查路由表，未登记 → 400 `tenant_unregistered` | A2 | S |
| A5 | `wist-atlas` | 读接口：`TenantCtx` 提取器 + 10 个接口接线 | A2 | L |
| A6 | `wist-atlas` | 单体读接口的越界防护（按 id 取 → 比对租户 → 404） | A5 | M |
| A7 | `wist-atlas` | `default_tenant` / probe 租户改为部署给定 | A2 | S |
| A8 | `wist-atlas` | `/healthz` 输出 `cells` | A2 | S |
| A9 | `wist-atlas` | 测试矩阵（隔离 / 未登记 / 兜底 / 反查） | A4,A5,A6 | M |
| S1 | `wist-field-stack` | `add-customer.sh`：生成 `atlas_tenant_id` + 拓扑库 | — | M |
| S2 | `wist-field-stack` | `init-field-config.sh`：渲染 `configs/atlas/cells.json` | S1 | S |
| S3 | `wist-field-stack` | compose：atlas 挂 cells + PG 片段含 atlas 库 | S1,S2 | S |
| S4 | `wist-field-api` | 多客户站点 `/api/atlas/*` → 501（短期兜底） | — | S |
| S5 | `wist-field-api` | 隔离完成后：上游注入 `?tenant=` + 移除 501 | A5,A6 | S |
| G1 | `wist-gateway-stack` | OML 删死值，改发客户号 | A4,S3 | S |

---

## 2. atlas 仓任务

### A1 · cells 配置加载

**新文件**：`crates/atlas-app/src/cells.rs`

**格式**（`WIST_ATLAS_CELLS_FILE` 指向的 JSON）：

```json
{
  "default_tenant": "c-001",
  "cells": [
    {
      "cust_id": "c-a",
      "tenant_id": "8f14e45f-ceea-4670-9f0a-1c0b2a3d4e5f",
      "host": "pg-c-a-atlas",
      "database": "wist_atlas",
      "user": "atlas"
    }
  ]
}
```

字段规则：

| 字段 | 必填 | 说明 |
|---|---|---|
| `default_tenant` | 否 | 单客户站点兜底（`cust_id`，不是 UUID）。**多客户站点留空** |
| `cells[].cust_id` | 是 | 与写入 body 的 `cust_id`、BFF 的 `?tenant=` 完全一致 |
| `cells[].tenant_id` | 是 | 注册时固化的 UUID（见 S1），atlas **只读不改** |
| `cells[].host` / `database` / `user` | 是（除非给了 `database_url`） | 拼连接串用 |
| `cells[].database_url` | 否 | 覆盖项（特殊 TLS/参数场景） |
| `WIST_ATLAS_PG_PASSWORD` | 环境变量 | 与 `host` 一起拼 `postgres://{user}:{pw}@{host}:5432/{database}` |

启动期硬校验（fail-fast，报错要指名哪个 `cust_id`）：

- `cust_id` 重复、`tenant_id` 重复 → 拒启动；
- `cust_id` 允用字符同 evidence：`[A-Za-z0-9_.-]`，长度 ≤ 64；
- 文件不存在 / 空 `cells` → **合法**（= 单库老行为，零迁移）；
- 无 `WIST_ATLAS_PG_PASSWORD` 且有没有 `database_url` 的 cell → 拒启动。

> 密钥不落 `configs/`：cells 文件只放 host/user/database（0644 可读），密码走环境变量。

### A2 · `CellRouter`

**新文件**：`crates/atlas-app/src/cells.rs`（与 A1 同文件）

```rust
pub struct CellRouter {
    /// 无 cells 配置时的退化路径：沿用 DATABASE_URL 那一份。
    default: (TopologyMonolith, Option<TenantId>),
    cells: std::collections::HashMap<String, (TopologyMonolith, TenantId)>,
    order: Vec<String>, // 保持配置顺序，便于日志/healthz 稳定输出
}

pub enum ResolveError {
    Required,      // 多客户站点未指定 → 400 tenant_required
    NotAllowed,    // 指定了但不在清单 → 读：403 tenant_not_allowed
    Unregistered,  // 写入口专用 → 400 tenant_unregistered
}
```

解析规则（读/写共用，错误码不同）：

| 请求 | cells 为空 | cells 数量 = 1 | cells 数量 > 1 |
|---|---|---|---|
| 带 `tenant` | 若等于 `default_tenant` → 用 default；否则 `NotAllowed` | 等于该客户 → 用；否则 `NotAllowed` | 命中 → 用；否则 `NotAllowed` |
| 不带 | `default_tenant`；没有则 `Required` | 自动选它 | `Required` |

**启动时播种**：对每个 cell，用其 store 执行

```sql
INSERT INTO tenant (tenant_id, tenant_ref) VALUES ($1, $2)
ON CONFLICT (tenant_id) DO UPDATE SET tenant_ref = EXCLUDED.tenant_ref
```

（幂等；让"库"成为租户映射的权威，掉 `cells.json` 也能从库恢复。）

### A3 · 迁移

**新文件**：`crates/atlas-storage/migrations/0007_tenant_registry.sql`

```sql
-- 租户注册表：UUID ↔ 外部客户号。
-- 不加外键：per-customer 库下它是"自证"用的，不是关系约束。
CREATE TABLE IF NOT EXISTS tenant (
    tenant_id  UUID PRIMARY KEY,
    tenant_ref TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### A4 · 写入口

**改**：`crates/atlas-app/src/ingest_http.rs`

- 删掉 `Uuid::parse_str(&tenant_ref)` 这段（135–147 行）；
- `let (store, tenant_id) = router.resolve_write(&write.cust_id)?;` → 未命中 `400 tenant_unregistered`，文案要带 `cust_id` 与"去 `add-customer.sh` 登记"的提示（**不**回显已登记的客户清单）；
- 兼容期保留一条：`cust_id` 能解析成 UUID **且** 命中某 cell 的 `tenant_id` → 照用（给老站点的 OML 死值留一个窗口，M1.7c 后删除）。

`atlas-wist-ingest` CLI（批量导入）同步：`--tenant` 仍收 UUID，另加 `--cust-id`（配合 `WIST_ATLAS_CELLS_FILE` 解析）；两者都给时报错。

### A5 · 读接口接线

**改**：`crates/atlas-app/src/http.rs`

新增提取器（放在 `HttpAppState` 旁边）：

```rust
/// 从 `?tenant=` 解析出 (store, tenant_id)；错误直接变成响应。
pub(crate) struct TenantCtx {
    pub app: TopologyMonolith,
    pub tenant: TenantId,
}

impl FromRequestParts<HttpAppState> for TenantCtx { /* 400 required / 403 not_allowed */ }
```

`HttpAppState` 增加 `router: Option<CellRouter>`（`new()` 保持签名，测试可不起路由）。

逐个改这 10 个接口 → 取 `TenantCtx` 替代 `state.app()`：

| 接口 | 额外改动 |
|---|---|
| `GET /api/hosts` | `host_summaries_async(tenant, page, include_stale)`，内部把 `list_all_hosts` 换成 `list_hosts(tenant, …)` |
| `GET /api/services` | 用 `ctx.tenant`，删掉 `default_tenant_id_async()` 调用 |
| `GET /api/topology/host/first` | 按租户取第一台（`list_hosts(tenant)` 的首条） |
| `GET /api/topology/host/first/processes` | 同上 |
| `GET /api/topology/host/{id}` | 见 A6 |
| `GET /api/topology/host/{id}/processes` | 见 A6 |
| `GET /api/topology/host/{id}/process-overview` | 见 A6 |
| `GET /api/topology/host/{id}/process-groups` | 见 A6 |
| `GET /api/topology/network/{id}` | 见 A6（segment 的 `tenant_id`） |
| `GET /api/topology/service/{id}` | 见 A6 |

`list_all_hosts` 收口：只在 probe / 运维诊断里保留，其余调用点加注释说明为什么不能再用。

### A6 · 越界防护

按 id 取的单体接口一律：**取到后比对 `entity.tenant_id != ctx.tenant` → 返回 404**（不是 403 —— 避免"这个 id 存在但属于别人"变成枚举 oracle）。

`/api/topology/host/first` 类接口天然只在本租户 store 里查，不需要这层。

### A7 · 默认租户与 probe

| 项 | 现在 | 改成 |
|---|---|---|
| `default_tenant_id_async()` | 拿库里第一个 host 的租户 | 删掉；用 cells 文件的 `default_tenant` 或"唯一 cell" |
| probe 租户 | 常量 UUID | 保持不变，但**只写 default store**；多客户站点 probe 不影响任何 cell |
| probe 主机过滤 | `PROBE_HOST` 常量 | 不变 |

### A8 · `/healthz`

增加 `cells` 块（**不输出连接串**）：

```json
{ "status": "ok", "cells": [{ "cust_id": "c-a", "tenant_id": "…" }] }
```

健康探测沿用现有 probe（只探 default）；每 cell 的探活列为后续项，不在本轮。

### A9 · 测试矩阵

| # | 用例 | 断言 |
|---|---|---|
| 1 | 两个 cell（两个 Memory store）各写一份 DSNAP | 各自 store 有 host，互不出现 |
| 2 | 读 `?tenant=c-a` | 只返回 c-a 的 host/service |
| 3 | 读不带 `?tenant=`，cells=2 | 400 `tenant_required` |
| 4 | 读 `?tenant=c-x` | 403 `tenant_not_allowed`，响应体不含客户清单 |
| 5 | 写未登记 `cust_id` | 400 `tenant_unregistered`；目标 store 无新增行 |
| 6 | `GET /api/topology/host/{c-b 的 id}` 且 `?tenant=c-a` | **404** |
| 7 | 无 cells 文件（老行为） | 一切照旧，`?tenant` 可选 |
| 8 | 启动播种 | `tenant` 表有 (uuid, cust_id)；重复启动不报错 |
| 9 | 配置非法（重复 `cust_id` / 缺密码） | 启动失败且错误信息指出具体条目 |

---

## 3. 栈侧任务

### S1 · `add-customer.sh`（diff 草案）

> 目标：一个客户登记 = 证据库 + 拓扑库 + 固定的 `atlas_tenant_id`，仍然只维护一份 `cells.json`。

**① 参数增加**

```diff
- CUST=""
- DATA_ROOT="${FIELD_DATA_ROOT:-./customers}"
- PG_PORT=""
- APPLY=0
+ CUST=""
+ DATA_ROOT="${FIELD_DATA_ROOT:-./customers}"
+ PG_PORT=""
+ APPLY=0
+ # 从已有拓扑库恢复映射时用（`select tenant_ref, tenant_id from tenant`）
+ ATLAS_TENANT_ID_OVERRIDE=""
@@ while 处理参数
+    --atlas-tenant-id) ATLAS_TENANT_ID_OVERRIDE="${2:-}"; shift 2 ;;
```

**② 拓扑库的连接参数（紧随现有 `PG_PASSWORD` 校验之后）**

```bash
ATLAS_PG_USER="${ATLAS_PG_USER:-atlas}"
ATLAS_PG_DB="${ATLAS_PG_DB:-wist_atlas}"
ATLAS_PG_PASSWORD="${ATLAS_PG_PASSWORD:-}"
[ -n "${ATLAS_PG_PASSWORD}" ] || die "ATLAS_PG_PASSWORD 为空：先跑 gops sys localize（或检查 values/）"
ATLAS_PG_HOST="pg-${CUST}-atlas"
ATLAS_PG_DIR="${DATA_DIR}/pg-atlas"
```

**③ 目录（与现有 PG/objects 一起建）**

```diff
- mkdir -p "${PG_DIR}" "${OBJECTS_DIR}"
- note "data dirs: ${PG_DIR} , ${OBJECTS_DIR}"
+ mkdir -p "${PG_DIR}" "${OBJECTS_DIR}" "${ATLAS_PG_DIR}"
+ note "data dirs: ${PG_DIR} , ${OBJECTS_DIR} , ${ATLAS_PG_DIR}"
```

**④ `cells.json`：写入 `atlas_tenant_id`（**已有则复用，绝不重算**）**

```bash
# 先把清单文件准备好（后面要读它判断是否已注册）
mkdir -p "${CELLS_DIR}"
[ -f "${CELLS_JSON}" ] || printf '[]\n' >"${CELLS_JSON}"

# 租户 id 只在"第一次登记"时生成一次，之后从 cells.json 复用。
# 不在运行时派生（原因见 docs/multi-customer.md §5.7.9）。
ATLAS_TENANT_ID="$(python3 - "${CELLS_JSON}" "${CUST}" "${ATLAS_TENANT_ID_OVERRIDE}" <<'PY'
import json, sys, uuid
path, cust, override = sys.argv[1:4]
try:
    with open(path, encoding="utf-8") as handle:
        cells = json.load(handle)
except FileNotFoundError:
    cells = []
existing = next((c.get("atlas_tenant_id") for c in cells if c.get("cust_id") == cust), None)
chosen = (override or existing or str(uuid.uuid4())).strip()
uuid.UUID(chosen)  # 非法直接抛，别写进清单
print(chosen)
PY
)"
note "atlas tenant: ${CUST} -> ${ATLAS_TENANT_ID}"
```

**⑤ 幂等写入的 entry 增加两个字段**

```diff
 entry = {
     "cust_id": cust,
     "objects_dir": f"/data-customers/{cust}/objects",
     "database_url": "${" + secret_key + "}",
     "host_dir": data_dir,
+    # 拓扑库：一个客户一个库；租户 UUID 注册时固化，atlas 只读
+    "atlas_tenant_id": atlas_tenant_id,
+    "atlas_host_dir": f"{data_dir}/pg-atlas",
 }
```
（对应 `python3 - ... <<'PY'` 的 `sys.argv` 多传一个 `ATLAS_TENANT_ID`。）

**⑥ compose 片段：同时生成证据库与拓扑库**

```python
lines.append(f"  pg-{cust}:")            # 现有：证据库
...
lines.append(f"  pg-{cust}-atlas:")      # 新增：拓扑库
lines.append(f"    container_name: ${{CELL_NAME:-wist-field-stack}}-pg-{cust}-atlas")
lines.append("    image: ${PG_REGISTRY:-docker.io/library}/postgres:${PG_IMAGE_TAG:-16}")
lines.append("    restart: unless-stopped")
lines.append("    environment:")
lines.append("      POSTGRES_DB: ${ATLAS_PG_DB:-wist_atlas}")
lines.append("      POSTGRES_USER: ${ATLAS_PG_USER:-atlas}")
lines.append("      POSTGRES_PASSWORD: ${ATLAS_PG_PASSWORD}")
lines.append("      TZ: ${TZ:-Asia/Shanghai}")
lines.append("    volumes:")
lines.append(f'      - {cell["atlas_host_dir"]}/pg-atlas:/var/lib/postgresql/data')
lines.append("    healthcheck:")
lines.append('      test: ["CMD-SHELL", "pg_isready -U ${ATLAS_PG_USER:-atlas} -d ${ATLAS_PG_DB:-wist_atlas}"]')
lines.append("      interval: 5s")
lines.append("      timeout: 5s")
lines.append("      retries: 20")
```

**⑦ 结尾提示**

```diff
- note "  验证：docker compose --project-directory . -f sys/docker-compose.yml ps pg-${CUST}"
+ note "  验证：docker compose --project-directory . -f sys/docker-compose.yml ps pg-${CUST}"
+ note "  拓扑库：psql -c 'select tenant_ref, tenant_id from tenant'  # 应看到 ${CUST}"
```

> 注意：脚本**不**直接 `psql` 播种 `tenant` 表 —— 由 atlas 启动时按 cells 文件幂等 upsert（A2），
> 少一个"脚本依赖容器已就绪"的时序问题。

### S2 · `init-field-config.sh`

新增（放在 evidence cells 生成之后）：

```bash
ATLAS_DIR="${STACK_ROOT}/configs/atlas"
ATLAS_CELLS_JSON='{"default_tenant":null,"cells":[]}'
if [ -f "${CELLS_JSON}" ]; then
  ATLAS_CELLS_JSON="$(python3 - "${CELLS_JSON}" "${EVIDENCE_TENANT}" <<'PY'
import json, sys
cells_path, default_tenant = sys.argv[1:3]
with open(cells_path, encoding="utf-8") as handle:
    cells = json.load(handle)
out = {
    "default_tenant": default_tenant or None,
    "cells": [
        {
            "cust_id": c["cust_id"],
            "tenant_id": c["atlas_tenant_id"],
            "host": f'pg-{c["cust_id"]}-atlas',
            "database": "wist_atlas",
            "user": "atlas",
        }
        for c in cells
        if c.get("atlas_tenant_id")
    ],
}
print(json.dumps(out, ensure_ascii=False))
PY
)"
fi
mkdir -p "${ATLAS_DIR}"
printf '%s\n' "${ATLAS_CELLS_JSON}" >"${ATLAS_DIR}/cells.json"
chmod 0644 "${ATLAS_DIR}/cells.json"
```

> 生成的 `cells.json` **不含密码**，所以可以放 `configs/`（0644）；密码由 compose 以
> `WIST_ATLAS_PG_PASSWORD` 注入。

### S3 · compose / 工作流

`sys/docker-compose.yml` 的 `atlas` 服务：

```diff
     environment:
       DATABASE_URL: postgres://${ATLAS_PG_USER}:${ATLAS_PG_PASSWORD}@atlas-postgres:5432/${ATLAS_PG_DB}
       WIST_ATLAS_TOKEN: ${ATLAS_API_TOKEN}
       WIST_ATLAS_PROBE: ${ATLAS_PROBE}
       WIST_ATLAS_PROBE_INTERVAL_SECS: ${ATLAS_PROBE_INTERVAL_SECS}
+      # 多客户：客户清单（cust_id → 固定的 tenant UUID + 库地址）。
+      # 空清单 = 单库老行为；文件由 init-field-config.sh 渲染。
+      WIST_ATLAS_CELLS_FILE: /etc/wist-atlas/cells.json
+      WIST_ATLAS_PG_PASSWORD: ${ATLAS_PG_PASSWORD}
+      ATLAS_PG_USER: ${ATLAS_PG_USER}
+      ATLAS_PG_DB: ${ATLAS_PG_DB}
       TZ: ${TZ}
+    volumes:
+      - ./configs/atlas:/etc/wist-atlas:ro
```

`configs/cells/compose.yml` 的骨架不变（`services: {}`；脚本全量重写，现在会多出 `pg-<cust>-atlas`）。

`sys/setting/vars.yml`：无需新增变量（`ATLAS_PG_USER` / `ATLAS_PG_DB` / `ATLAS_PG_PASSWORD` 已有或补上默认值）。
`init-stack.sh`：把 `configs/atlas` 加进"必须存在"的目录兜底（与 `configs/cells` 同处理）。

---

## 4. BFF（`wist-field-api`）

### S4 · 短期兜底（可与 atlas 任务并行）

> **状态：已实现**（`wist-field-api` 0.7.2；0.7.1 因 CI DNS 故障未出镜像）。闸门位置在 `proxy_atlas` 里
> `atlas_not_configured` 之后，因此“atlas 未配置”仍回 404，不会被 501 遮盖；未认证仍先回 401。

`src/api.rs` 的 `proxy_atlas`，在取到 `atlas` 配置之后：

```rust
// atlas 尚未按客户隔离（docs/multi-customer.md §5.7）：多客户站点直接关掉，
// 避免"看着能用、实际跨客户可见"。
if state.config.evidence.allowed_tenants.len() > 1 {
    return error_response(
        StatusCode::NOT_IMPLEMENTED,
        "atlas_not_multi_tenant",
        "atlas is not tenant-isolated yet; disable asset topology on multi-customer sites",
    );
}
```

测试：`tests/contract.rs` 增一条（多客户配置 → 501）。

### S5 · 隔离完成后

- `proxy_atlas` 解析 `?tenant=`（复用 `resolve_tenant`），把 `tenant=<cust_id>` 追加到上游 query；
- 删除 S4 的 501 分支与其用例；
- `/api/session` 不动（仍不返回默认客户）。

---

## 5. 数据面（`wist-gateway-stack`）

### G1 · OML

`sys/data-plane/models/oml/agent_uplink/agent_uplink_obs_dsnap/adm.oml`：

```diff
-// 1. `cust_id` 是 atlas **内部租户 UUID**，不是客户号（传客户号会 `400 ... is not a UUID`）。
-//    本站点由客户号 `1000000000000000001` 确定性派生：
-//    `uuid5(NAMESPACE_OID, "1000000000000000001") = 40a59f7d-df92-5958-adef-61def418d257`
-//    ⚠ 换客户必须同步改这里 —— OML 不能读环境变量，模型是共享的。
-cust_id = chars("40a59f7d-df92-5958-adef-61def418d257");
+// `cust_id` = 客户号（与证据侧、网关绑定注入的 `tenant_id` 同一 ID 空间）。
+// atlas 侧按 `cells.json` 解析成内部租户 UUID，未登记会返回 400（进 rescue）。
+cust_id = read(tenant_id) { _ : chars("unknown") };
```

验收：wparse 投一帧 → atlas 返回 200；`select tenant_ref, count(*) from tenant join host_inventory ...` 能看到客户号。

---

## 6. 里程碑与发布顺序

| 里程碑 | 内容 | 可独立上线？ | 回滚 |
|---|---|---|---|
| **M1.7a** | A1–A4 + A9（1,5,7,8,9） | ✅ 无 cells 文件时行为不变 | 删除 cells 文件 |
| **M1.7b** | A5–A8 + S5 | ✅ | 同上 |
| **M1.7c** | S1–S3 + G1 | ✅ | 恢复 OML 死值；库不动 |

**顺序不能反**：先发 atlas（向后兼容）→ 再让栈生成 cells + 拓扑库 → 最后切数据面发客户号。
若先切 OML，atlas 还是旧版 → 400 直接进 rescue（可回滚但会丢一段时间的数据）。

**S4（501）建议先于 M1.7a 上线**：它独立、成本极低，先把"跨客户可见"这个风险关掉。

---

## 7. 回归面（改完必须跑）

| 仓 | 命令 |
|---|---|
| `wist-atlas` | `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`（含容器测试） |
| `wist-field-api` | 同上 + `cargo test --test contract` |
| `wist-field-stack` | `./dev/lint.sh && bash dev/tests/env-example-drift.test.sh && gops sys localize && gops run config` |
| 端到端 | 见 `docs/multi-customer.md` §5.7.7 的 6 条验收 |
