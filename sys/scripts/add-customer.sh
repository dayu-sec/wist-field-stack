#!/usr/bin/env bash
# 加一个客户：建数据目录 + 一个独立 postgres + 登记到证据服务的存储路由。
#
# 用法：
#   sys/scripts/add-customer.sh <cust_id> [--data-root DIR] [--pg-port PORT] [--apply]
#
#   <cust_id>     客户 id，必须与**写入 body 的 `cust_id`**（以及网关绑定的 `tenant_id`）
#                 完全一致 —— 这是路由的唯一依据。
#   --data-root   数据根目录，默认取栈根 `.env` 的 `FIELD_DATA_ROOT`（默认 `./customers`）
#   --pg-port     给该客户的 PG 绑一个宿主端口（默认不绑：容器网络内够用，也更安全）
#   --apply       本脚本末尾直接跑 `gops sys localize && gops run start`
#
# 它写三样东西（都可重入，重复跑结果一样）：
#   1. `<data-root>/<cust>/{pg,objects}`                 数据目录（PG 与证据正文分开）
#   2. `configs/cells/cells.json`                        客户清单（**唯一真相**）
#   3. `configs/cells/compose.yml`                       由清单全量生成的 compose 片段
#                                                       （主 compose 用 include 引入）
#   4. `.wist/sec-value.yml` 的 `SEC_EVIDENCE_DB_URL_<CUST>`（幂等，0640）
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
CELLS_COMPOSE="${CELLS_DIR}/compose.yml"
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

while [ $# -gt 0 ]; do
  case "$1" in
    --data-root) DATA_ROOT="${2:-}"; shift 2 ;;
    --pg-port) PG_PORT="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -h | --help) sed -n '2,26p' "$0"; exit 0 ;;
    -*) die "未知参数：$1（--help 看用法）" ;;
    *)
      [ -z "${CUST}" ] || die "只能给一个 cust_id（已给：${CUST}）"
      CUST="$1"
      shift
      ;;
  esac
done

[ -n "${CUST}" ] || die "缺少 <cust_id>（--help 看用法）"

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

command -v python3 >/dev/null 2>&1 || die "需要 python3（用来维护 cells.json 与生成 compose 片段）"

# 数据根：相对路径相对栈根（与 compose 的解析口径一致）
case "${DATA_ROOT}" in
  /*) DATA_ROOT_ABS="${DATA_ROOT}" ;;
  *) DATA_ROOT_ABS="${STACK_ROOT}/${DATA_ROOT#./}" ;;
esac
DATA_DIR="${DATA_ROOT_ABS}/${CUST}"
OBJECTS_DIR="${DATA_DIR}/objects"
PG_DIR="${DATA_DIR}/pg"

# 环境变量名：cust_id 里非 [A-Za-z0-9_] 的字符一律换成 `_`
SEC_KEY="SEC_EVIDENCE_DB_URL_$(printf '%s' "${CUST}" | tr -c 'A-Za-z0-9_' '_' | tr '[:lower:]' '[:upper:]')"

PG_USER="${EVIDENCE_PG_USER:-evidence}"
PG_DB="${EVIDENCE_PG_DB:-wist_evidence}"
PG_PASSWORD="${EVIDENCE_PG_PASSWORD:-}"
[ -n "${PG_PASSWORD}" ] || die "EVIDENCE_PG_PASSWORD 为空：先跑 gops sys localize（或检查 values/）"
PG_HOST="pg-${CUST}"

# 1) 数据目录（PG 与对象分开：PG 要小页 IO、对象是大文件）
mkdir -p "${PG_DIR}" "${OBJECTS_DIR}"
note "data dirs: ${PG_DIR} , ${OBJECTS_DIR}"

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

# 3) 客户清单（cells.json）——**唯一真相**，compose 片段由它生成
mkdir -p "${CELLS_DIR}"
[ -f "${CELLS_JSON}" ] || printf '[]\n' >"${CELLS_JSON}"

python3 - "${CELLS_JSON}" "${CUST}" "${PG_PORT}" "${SEC_KEY}" "${DATA_DIR}" <<'PY'
import json
import sys

path, cust, port, secret_key, data_dir = sys.argv[1:6]

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

# 4) compose 片段：从清单**全量重写**（不靠手改标记块，天然幂等）
python3 - "${CELLS_JSON}" "${CELLS_COMPOSE}" <<'PY'
import json
import sys

cells_path, compose_path = sys.argv[1:3]

with open(cells_path, encoding="utf-8") as handle:
    cells = json.load(handle)

header = """# 由 `sys/scripts/add-customer.sh` 从 cells.json **全量生成**，不要手改。
#
# 每个客户一个独立 postgres：独立数据目录 = 独立故障域/备份粒度。
# 不绑宿主端口（证据服务在 compose 网络上直连 `pg-<cust>:5432`）。
# 要开放给运维排查，用 `add-customer.sh <cust> --pg-port <port>` 重新生成一次。
"""

lines = [header]
if not cells:
    lines.append("services: {}\n")
else:
    lines.append("services:")
    for cell in cells:
        cust = cell["cust_id"]
        lines.append(f"  pg-{cust}:")
        lines.append(
            f"    container_name: ${{CELL_NAME:-wist-field-stack}}-pg-{cust}"
        )
        lines.append(
            "    image: ${PG_REGISTRY:-docker.io/library}/postgres:${PG_IMAGE_TAG:-16}"
        )
        lines.append("    restart: unless-stopped")
        lines.append("    environment:")
        lines.append("      POSTGRES_DB: ${EVIDENCE_PG_DB:-wist_evidence}")
        lines.append("      POSTGRES_USER: ${EVIDENCE_PG_USER:-evidence}")
        lines.append("      POSTGRES_PASSWORD: ${EVIDENCE_PG_PASSWORD}")
        lines.append("      TZ: ${TZ:-Asia/Shanghai}")
        if cell.get("pg_port"):
            lines.append("    ports:")
            lines.append(
                f'      - "${{PG_BIND_IP:-127.0.0.1}}:{cell["pg_port"]}:5432"'
            )
        lines.append("    volumes:")
        lines.append(f'      - {cell["host_dir"]}/pg:/var/lib/postgresql/data')
        lines.append("    healthcheck:")
        lines.append(
            '      test: ["CMD-SHELL", "pg_isready -U '
            '${EVIDENCE_PG_USER:-evidence} -d ${EVIDENCE_PG_DB:-wist_evidence}"]'
        )
        lines.append("      interval: 5s")
        lines.append("      timeout: 5s")
        lines.append("      retries: 20")
        lines.append("")
    # 去重空行
    while lines and lines[-1] == "":
        lines.pop()
    lines.append("")

with open(compose_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))
PY
note "compose 片段已生成：${CELLS_COMPOSE}"

# 5) 下一步
echo
note "客户 ${CUST} 已登记。下一步："
note "  gops sys localize    # 把 cell 渲染进 configs/evidence/wist-evidence.toml"
note "  gops run start       # 起 pg-${CUST} 并重载 evidence"
note "  验证：docker compose --project-directory . -f sys/docker-compose.yml ps pg-${CUST}"

if [ "${APPLY}" = "1" ]; then
  echo
  note "--apply：执行 localize + start"
  (cd "${STACK_ROOT}" && gops sys localize && gops run start)
fi
