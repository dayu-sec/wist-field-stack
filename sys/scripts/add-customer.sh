#!/usr/bin/env bash
# 加一个客户：建数据目录 + 一个独立 postgres + 登记到证据服务的存储路由。
#
# 用法：
#   sys/scripts/add-customer.sh <cust_id> [--data-root DIR] [--pg-port PORT] [--atlas-tenant-id UUID] [--apply]
#   sys/scripts/add-customer.sh --remove <cust_id> [--purge-data]
#
#   <cust_id>     客户 id，必须与**写入 body 的 `cust_id`**（以及网关绑定的 `tenant_id`）
#                 完全一致 —— 这是路由的唯一依据。
#   --data-root   数据根目录，默认取栈根 `.env` 的 `FIELD_DATA_ROOT`（默认 `./customers`）
#   --pg-port     给该客户的 PG 绑一个宿主端口（默认不绑：容器网络内够用，也更安全）
#   --atlas-tenant-id  沿用现场已有的拓扑租户 UUID（不继承就会新生成一个）；
#                 从 `psql -c 'select tenant_ref, tenant_id from tenant'` 里取。
#   --apply       本脚本末尾直接跑 `gops sys localize && gops run start`
#   --remove      注销：从 cells.json 与密钥文件里移除该客户
#   --purge-data  配合 --remove：同时删除它的两个容器与数据目录（**不可逆**）
#
# 它写的东西（都可重入，重复跑结果一样）：
#   1. `<data-root>/<cust>/{pg,objects,pg-atlas}`    数据目录（证据 PG / 证据正文 / 拓扑 PG）
#   2. `configs/cells/cells.json`                    客户清单（**唯一真相**，含固化的 `atlas_tenant_id`）
#   3. `.wist/sec-value.yml` 的 `SEC_EVIDENCE_DB_URL_<CUST>`（幂等，0640）
#
# **它不写 compose**：客户 PG 的编排片段（`configs/cells/compose.yml`）和
# evidence/atlas/BFF 的客户清单一样，都是 localize 从 `cells.json` **全量生成**的产物。
# 所以加完客户必须跑 `gops sys localize`，否则运行时还是旧清单。
#
# 为什么客户清单放 `configs/`：它是**站点现场态**。`sys/` 目录升级时会被包整体覆盖，
# 客户定义写进去一升级就没了；`configs/` 在 `sys-prj.yml` 的 `protect` 里。
set -euo pipefail

trap 'echo "$0 失败：第 ${LINENO} 行（退出码 $?）" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=lib/env-defaults.sh
. "${SCRIPT_DIR}/lib/env-defaults.sh"
load_env_defaults "${STACK_ROOT}"

CELLS_DIR="${STACK_ROOT}/configs/cells"
CELLS_JSON="${CELLS_DIR}/cells.json"
SEC_FILE="${STACK_ROOT}/.wist/sec-value.yml"

note() { echo "  $*"; }
die() {
  echo "错误：$*" >&2
  exit 1
}

CUST=""
DATA_ROOT="${FIELD_DATA_ROOT:-./customers}"
PG_PORT=""
APPLY=0
# 注销模式：只改登记（清单 / compose / 密钥），数据默认保留。
REMOVE=0
PURGE=0
# 沿用现场已有的拓扑租户 UUID（从 `select tenant_id from tenant` 取）；不给就新生成。
ATLAS_TENANT_ID_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --data-root) DATA_ROOT="${2:-}"; shift 2 ;;
    --pg-port) PG_PORT="${2:-}"; shift 2 ;;
    --atlas-tenant-id) ATLAS_TENANT_ID_OVERRIDE="${2:-}"; shift 2 ;;
    --remove) REMOVE=1; shift ;;
    --purge-data) PURGE=1; shift ;;
    --apply) APPLY=1; shift ;;
    -h | --help) sed -n '2,28p' "$0"; exit 0 ;;
    -*) die "未知参数：$1（--help 看用法）" ;;
    *)
      [ -z "${CUST}" ] || die "只能给一个 cust_id（已给：${CUST}）"
      CUST="$1"
      shift
      ;;
  esac
done

[ -n "${CUST}" ] || die "缺少 <cust_id>（--help 看用法）"
[ "${PURGE}" = "0" ] || [ "${REMOVE}" = "1" ] || die "--purge-data 只能跟 --remove 一起用"

# 校验：它同时是目录名、compose 服务名后缀、环境变量名片段、对象键第一段。
case "${CUST}" in
  *[!A-Za-z0-9_.-]*) die "cust_id 只允许 [A-Za-z0-9_.-]：'${CUST}'" ;;
  .* | -* | *. | *-) die "cust_id 不能以 . / - 开头或结尾：'${CUST}'" ;;
esac
[ "${#CUST}" -le 64 ] || die "cust_id 太长（<= 64）：'${CUST}'"

case "${PG_PORT}" in
  '') ;;
  *[!0-9]*) die "--pg-port 必须是数字：'${PG_PORT}'" ;;
esac

command -v python3 >/dev/null 2>&1 || die "需要 python3（用来维护 cells.json）"

# 数据根：相对路径相对栈根（与 compose 的解析口径一致）
case "${DATA_ROOT}" in
  /*) DATA_ROOT_ABS="${DATA_ROOT}" ;;
  *) DATA_ROOT_ABS="${STACK_ROOT}/${DATA_ROOT#./}" ;;
esac
DATA_DIR="${DATA_ROOT_ABS}/${CUST}"
OBJECTS_DIR="${DATA_DIR}/objects"
PG_DIR="${DATA_DIR}/pg"
ATLAS_PG_DIR="${DATA_DIR}/pg-atlas"

# 环境变量名：cust_id 里非 [A-Za-z0-9_] 的字符一律换成 `_`
SEC_KEY="SEC_EVIDENCE_DB_URL_$(printf '%s' "${CUST}" | tr -c 'A-Za-z0-9_' '_' | tr '[:lower:]' '[:upper:]')"

PG_USER="${EVIDENCE_PG_USER:-evidence}"
PG_DB="${EVIDENCE_PG_DB:-wist_evidence}"
PG_PASSWORD="${EVIDENCE_PG_PASSWORD:-}"
[ -n "${PG_PASSWORD}" ] || die "EVIDENCE_PG_PASSWORD 为空：先跑 gops sys localize（或检查 values/）"
PG_HOST="pg-${CUST}"

# 拓扑库（atlas）：一个客户一个库，租户 UUID 在这里**生成一次并固化**。
# 不在运行时派生（原因见 docs/multi-customer.md §5.7.9）；口令由 compose 注入，
# 不进 cells.json（那份清单是 0644 可读的）。
ATLAS_PG_USER="${ATLAS_PG_USER:-atlas}"
ATLAS_PG_DB="${ATLAS_PG_DB:-wist_atlas}"
ATLAS_PG_PASSWORD="${ATLAS_PG_PASSWORD:-}"
[ -n "${ATLAS_PG_PASSWORD}" ] || die "ATLAS_PG_PASSWORD 为空：先跑 gops sys localize（或检查 values/）"

# ── 注销一个客户（--remove）───────────────────────────────────────
#
# 只改「登记」：`cells.json` 条目与密钥文件里的 DB URL。
# 容器与数据目录默认**保留**（删数据不可逆）；加 `--purge-data` 才一起删。
# 为什么走脚本而不是手改：清单是唯一真相，手改很快就会被下一次全量生成抹平。
if [ "${REMOVE}" = "1" ]; then
  [ -f "${CELLS_JSON}" ] || die "没有客户清单：${CELLS_JSON}"
  REMOVED_HOST_DIR="$(python3 - "${CELLS_JSON}" "${CUST}" <<'PY'
import json
import sys

path, cust = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    cells = json.load(handle)
hit = [cell for cell in cells if cell.get("cust_id") == cust]
if not hit:
    raise SystemExit(1)
print(hit[0].get("host_dir", ""))
PY
)" || die "客户清单里没有「${CUST}」，无需删除"

  python3 - "${CELLS_JSON}" "${CUST}" <<'PY'
import json
import sys

path, cust = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    cells = json.load(handle)
cells = [cell for cell in cells if cell.get("cust_id") != cust]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(cells, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
  note "已从清单移除：${CUST}（${CELLS_JSON}）"

  SEC_KEY_REMOVE="SEC_EVIDENCE_DB_URL_$(printf '%s' "${CUST}" | tr -c 'A-Za-z0-9_' '_' | tr '[:lower:]' '[:upper:]')"
  if [ -f "${SEC_FILE}" ] && grep -q "^${SEC_KEY_REMOVE}:" "${SEC_FILE}"; then
    grep -v "^${SEC_KEY_REMOVE}:" "${SEC_FILE}" >"${SEC_FILE}.new"
    chmod 0640 "${SEC_FILE}.new"
    mv -f "${SEC_FILE}.new" "${SEC_FILE}"
    note "已移除密钥：${SEC_KEY_REMOVE}"
  else
    note "密钥文件里没有 ${SEC_KEY_REMOVE}（跳过）"
  fi

  if [ "${PURGE}" = "1" ]; then
    CONTAINER_PREFIX="${CELL_NAME:-wist-field-stack}"
    for name in "${CONTAINER_PREFIX}-pg-${CUST}" "${CONTAINER_PREFIX}-pg-${CUST}-atlas"; do
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${name}"; then
        docker rm -f "${name}" >/dev/null
        note "已删除容器：${name}"
      fi
    done
    # 删目录前先确认它真的是「这个客户的数据根」：非空、绝对路径或栈内相对路径、末段等于 cust_id。
    case "${REMOVED_HOST_DIR}" in
      "" | "/" | "." | "..") die "拒绝删除可疑数据目录：「${REMOVED_HOST_DIR}」" ;;
    esac
    [ "$(basename "${REMOVED_HOST_DIR}")" = "${CUST}" ] || die "数据目录末段不是 ${CUST}，拒绝删除：「${REMOVED_HOST_DIR}」"
    if [ -d "${REMOVED_HOST_DIR}" ]; then
      rm -rf "${REMOVED_HOST_DIR}"
      note "已删除数据目录：${REMOVED_HOST_DIR}"
    else
      note "数据目录不存在（跳过）：${REMOVED_HOST_DIR}"
    fi
  else
    note "容器与数据未动；确认要连数据一起删就加 --purge-data"
  fi

  echo
  note "客户 ${CUST} 已注销。下一步："
  note "  gops sys localize && gops run start   # 让 evidence / atlas / BFF 按新清单重载"
  exit 0
fi

# 1) 数据目录（PG 与对象分开：PG 要小页 IO、对象是大文件；拓扑库再一套）
mkdir -p "${PG_DIR}" "${OBJECTS_DIR}" "${ATLAS_PG_DIR}"
note "data dirs: ${PG_DIR} , ${OBJECTS_DIR} , ${ATLAS_PG_DIR}"

# 2) 密钥：该客户的 DB URL（幂等；已存在则保留现场值）
if [ ! -f "${SEC_FILE}" ]; then
  mkdir -p "$(dirname "${SEC_FILE}")"
  : >"${SEC_FILE}"
  chmod 0640 "${SEC_FILE}"
fi
if grep -q "^${SEC_KEY}:" "${SEC_FILE}"; then
  note "密钥已存在，保留：${SEC_KEY}"
else
  printf '%s: "postgres://%s:%s@%s:5432/%s"\n' \
    "${SEC_KEY}" "${PG_USER}" "${PG_PASSWORD}" "${PG_HOST}" "${PG_DB}" >>"${SEC_FILE}"
  chmod 0640 "${SEC_FILE}"
  note "已写入密钥：${SEC_KEY}（${SEC_FILE}）"
fi

# 3) 客户清单（cells.json）——**唯一真相**，compose 片段与渲染值都由 localize 从它生成
mkdir -p "${CELLS_DIR}"
[ -f "${CELLS_JSON}" ] || printf '[]\n' >"${CELLS_JSON}"

# 拓扑库的租户 UUID：已有就复用（幂等）；否则按 `--atlas-tenant-id` 或新生成一个。
# 一旦写进清单就**不再重算**：换客户号只改映射，历史数据不动。
ATLAS_TENANT_ID="$(python3 - "${CELLS_JSON}" "${CUST}" "${ATLAS_TENANT_ID_OVERRIDE}" <<'PY'
import json
import sys
import uuid

path, cust, override = sys.argv[1:4]
try:
    with open(path, encoding="utf-8") as handle:
        cells = json.load(handle)
except (FileNotFoundError, json.JSONDecodeError):
    cells = []
existing = next((c.get("atlas_tenant_id") for c in cells if c.get("cust_id") == cust), None)
chosen = (override or existing or str(uuid.uuid4())).strip()
uuid.UUID(chosen)  # 非法直接抛错，别把垃圾写进清单
print(chosen)
PY
)"
note "atlas tenant: ${CUST} -> ${ATLAS_TENANT_ID}"

python3 - "${CELLS_JSON}" "${CUST}" "${PG_PORT}" "${SEC_KEY}" "${DATA_DIR}" "${ATLAS_TENANT_ID}" <<'PY'
import json
import sys

path, cust, port, secret_key, data_dir, atlas_tenant_id = sys.argv[1:7]

with open(path, encoding="utf-8") as handle:
    cells = json.load(handle)
if not isinstance(cells, list):
    raise SystemExit(f"{path}: 顶层必须是数组")

entry = {
    "cust_id": cust,
    # 容器内路径：宿主 {data_root}/{cust}/objects 挂到 /data-customers/{cust}/objects
    "objects_dir": f"/data-customers/{cust}/objects",
    # 密钥文件里的键，渲染进 TOML 后由服务展开（明文不落 configs/）
    "database_url": "${" + secret_key + "}",
    "host_dir": data_dir,
    # 拓扑库：一个客户一库；租户 UUID 登记时固化，atlas 只读
    "atlas_tenant_id": atlas_tenant_id,
    "atlas_host_dir": f"{data_dir}/pg-atlas",
}
if port:
    entry["pg_port"] = int(port)

cells = [cell for cell in cells if cell.get("cust_id") != cust]
cells.append(entry)
cells.sort(key=lambda cell: cell["cust_id"])

with open(path, "w", encoding="utf-8") as handle:
    json.dump(cells, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
note "客户清单已更新：${CELLS_JSON}"

# 5) 下一步

echo
note "客户 ${CUST} 已登记：证据库 + 拓扑库，atlas 租户 ${ATLAS_TENANT_ID}。下一步："
note "  gops sys localize    # 从清单重生成：compose 片段 + evidence cells + configs/atlas/cells.json"
note "  gops run start       # 起 pg-${CUST} / pg-${CUST}-atlas 并重载 evidence + atlas"
note "  验证：docker compose --project-directory . -f sys/docker-compose.yml ps pg-${CUST} pg-${CUST}-atlas"
note "  拓扑租户：psql -c 'select tenant_ref, tenant_id from tenant'  # 应看到 ${CUST}"

if [ "${APPLY}" = "1" ]; then
  echo
  note "--apply：执行 localize + start"
  (cd "${STACK_ROOT}" && gops sys localize && gops run start)
fi
