#!/usr/bin/env bash
# 备料 configs/ 的**渲染值**（`gx.tpl` 的输入）—— 由 `gx run localize` 调用。
#
# 用法：
#   sys/scripts/init-field-config.sh
#
# 产出（全部幂等；内容不变就不碰 mtime，避免每次 localize 都触发容器重启）：
#   configs/field-api/field-api.value.json    BFF 配置模板的渲染值
#   configs/field-api/cred.value.json         cred 接入模板的渲染值
#   configs/evidence/wist-evidence.value.json 证据服务模板的渲染值
#
# 值从哪来：**栈根 `.env`**（`gops sys localize` 生成，含 `values/<系统>/sys_value.yml` 的现场覆盖），
# 显式环境变量优先（gops localize 会把合并后的值直接注入流程环境）。
#
# 这里**没有密钥**：模板里的 `${SEC_…}` 原样保留，由服务启动时从 `.wist/sec-value.yml` 展开。
# 密钥不该出现在渲染值 / 渲染产物里 —— 那两份都会被备份、被 `find`、被人看。
#
# 为什么必须是脚本而不是在 GXL 里 printf：
#   GXL 字符串字面量**不做转义还原**（`\"` 会原样留下反斜杠），而命令由 `/bin/sh -c` 执行、
#   Debian/Ubuntu 的 /bin/sh 是 **dash**（printf 不认 `\"`）→ 反斜杠写进文件 → 非法 JSON →
#   `gx.tpl` 报 `parse json data file`，localize 中断；macOS 上 sh 是 bash（printf 吃掉反斜杠）
#   所以看不出问题 —— 典型「本机好好的、上云就炸」。写成脚本文件就没有这一层。
set -euo pipefail

# `set -e` 的静默退出是排查黑洞：脚本半途死掉、stderr 空白。
# 任何未被 if/&& 接住的失败都把行号打到 stderr。
# 为什么用 $0 / $? 而不用中间变量：`$(basename "$0")` 是**命令替换**，
# 在同一个字符串里先展开它会把 `$?` 冲成 0（已实测），行号与退出码就都错了。
trap 'echo "$0 失败：第 ${LINENO} 行（退出码 $?）" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# 现场值：栈根 `.env`（显式环境变量优先）
# shellcheck source=lib/env-defaults.sh
. "${SCRIPT_DIR}/lib/env-defaults.sh"
load_env_defaults "${STACK_ROOT}"

FIELD_API_DIR="${STACK_ROOT}/configs/field-api"
EVIDENCE_DIR="${STACK_ROOT}/configs/evidence"

note() { echo "  $*"; }
die() {
  echo "错误：$*" >&2
  exit 1
}

# ── 取值 + 校验 ────────────────────────────────────────────────────────────
#
# 校验是**为了不写出「看着成了」的坏配置**：值来自环境变量，一个多打的分号就会让
# `docker compose up` 之后才在服务启动日志里炸（而那时 localize 早就报成功了）。
need() {
  local key="$1"
  local value="${!key:-}"
  [ -n "${value}" ] || die "${key} 为空：先跑 \`gops sys localize\`（它生成栈根 .env），或看 \`values/<系统>/sys_value.yml\`"
  printf '%s' "${value}"
}

# 主机名 / IP（允许 IPv6 的方括号写法）
host_like() {
  local key="$1" value="$2"
  case "${value}" in
    *[!A-Za-z0-9.:_-]*) die "${key} 含非法字符：'${value}'（只允许 [A-Za-z0-9.:_-]）" ;;
  esac
  printf '%s' "${value}"
}

port_like() {
  local key="$1" value="$2"
  case "${value}" in
    '' | *[!0-9]*) die "${key} 不是端口号：'${value}'" ;;
  esac
  case "${value}" in
    0*) die "${key} 不是合法端口：'${value}'" ;;
  esac
  printf '%s' "${value}"
}

# 自由文本（URL / 容器内路径 / true|false / 标识符）：只挡会破坏 JSON 的字符
text_like() {
  local key="$1" value="$2"
  case "${value}" in
    *'"'* | *\\*) die "${key} 含引号或反斜杠，无法安全写进渲染值：'${value}'" ;;
    *$'\n'*) die "${key} 含换行" ;;
  esac
  printf '%s' "${value}"
}

EVIDENCE_READ_PORT="$(port_like EVIDENCE_READ_PORT "$(need EVIDENCE_READ_PORT)")"
EVIDENCE_TENANT="$(text_like EVIDENCE_TENANT "$(need EVIDENCE_TENANT)")"
EVIDENCE_SINK_HOST_PORT="$(port_like EVIDENCE_SINK_HOST_PORT "$(need EVIDENCE_SINK_HOST_PORT)")"
EVIDENCE_SINK_PUBLIC_HOST="$(host_like EVIDENCE_SINK_PUBLIC_HOST "$(need EVIDENCE_SINK_PUBLIC_HOST)")"
ATLAS_INGEST_HOST_PORT="$(port_like ATLAS_INGEST_HOST_PORT "$(need ATLAS_INGEST_HOST_PORT)")"
ATLAS_INGEST_PUBLIC_HOST="$(host_like ATLAS_INGEST_PUBLIC_HOST "$(need ATLAS_INGEST_PUBLIC_HOST)")"
VM_HOST_PORT="$(port_like VM_HOST_PORT "$(need VM_HOST_PORT)")"
METRICS_SINK_PUBLIC_HOST="$(host_like METRICS_SINK_PUBLIC_HOST "$(need METRICS_SINK_PUBLIC_HOST)")"
CREDENTIALS_HOST_PORT="$(port_like CREDENTIALS_HOST_PORT "$(need CREDENTIALS_HOST_PORT)")"
FIELD_API_AUDIENCE="$(text_like FIELD_API_AUDIENCE "$(need FIELD_API_AUDIENCE)")"

# 下面三个**合法地可以为空**（空 = 另一个分支）：
#   FIELD_API_ADVERTISE_HOST 空 → field-api 启动期就拒（有意如此，不签空名字的证书）
#   FIELD_API_CRED_URL       空 → 初始化页上让操作者填
#   FIELD_API_CRED_CA_FILE   空 → 必须开 insecure_tls
FIELD_API_ADVERTISE_HOST="$(host_like FIELD_API_ADVERTISE_HOST "${FIELD_API_ADVERTISE_HOST:-}")"
FIELD_API_CRED_URL="$(text_like FIELD_API_CRED_URL "${FIELD_API_CRED_URL:-}")"
FIELD_API_CRED_CA_FILE="$(text_like FIELD_API_CRED_CA_FILE "${FIELD_API_CRED_CA_FILE:-}")"
FIELD_API_CRED_INSECURE_TLS="$(text_like FIELD_API_CRED_INSECURE_TLS "${FIELD_API_CRED_INSECURE_TLS:-false}")"
FIELD_API_REQUIRE_CRED_SIGNATURE="$(text_like FIELD_API_REQUIRE_CRED_SIGNATURE "${FIELD_API_REQUIRE_CRED_SIGNATURE:-false}")"

# 渲染值只在内容变化时落盘
write_json() {
  local dst="$1"
  shift
  local tmp
  tmp="$(mktemp "${dst}.XXXXXX")"
  "$@" >"${tmp}"
  chmod 644 "${tmp}"
  if [ -f "${dst}" ] && cmp -s "${tmp}" "${dst}"; then
    rm -f "${tmp}"
    note "渲染值一致，跳过：${dst}"
  else
    mv -f "${tmp}" "${dst}"
    note "已写渲染值：${dst}"
  fi
}

mkdir -p "${FIELD_API_DIR}" "${EVIDENCE_DIR}" "${STACK_ROOT}/configs/web"

# 老现场收尾：bind 源缺失时 docker 会把**文件级**挂载目标建成**同名目录**
# （`configs/field-api/cred.toml` 变成目录）—— 之后 `gx.tpl` 往目录里写就会失败，
# 容器则报 `read ...: Is a directory`。这一步从 `init-stack.sh` 的 `copy_missing` 接过来了
# （那里已经不拷 configs），必须坚在渲染**之前**。
prune_bogus_dirs() {
  local path
  for path in \
    "${FIELD_API_DIR}/field-api.toml" \
    "${FIELD_API_DIR}/cred.toml" \
    "${EVIDENCE_DIR}/wist-evidence.toml" \
    "${STACK_ROOT}/configs/web/nginx.conf"; do
    [ -d "${path}" ] || continue
    if rmdir "${path}" 2>/dev/null; then
      note "清掉误建的目录：${path}（应是挂载点文件）"
    else
      die "${path} 是目录且非空，但本应是文件：人工确认后删掉再跑"
    fi
  done
}
prune_bogus_dirs

# ① BFF：`[evidence]` / `[atlas]` / `[metrics]` / `[integration]`
write_json "${FIELD_API_DIR}/field-api.value.json" cat <<EOF
{
  "evidence_read_port": ${EVIDENCE_READ_PORT},
  "evidence_tenant": "${EVIDENCE_TENANT}",
  "evidence_sink_public_host": "${EVIDENCE_SINK_PUBLIC_HOST}",
  "evidence_sink_host_port": ${EVIDENCE_SINK_HOST_PORT},
  "atlas_ingest_public_host": "${ATLAS_INGEST_PUBLIC_HOST}",
  "atlas_ingest_host_port": ${ATLAS_INGEST_HOST_PORT},
  "metrics_sink_public_host": "${METRICS_SINK_PUBLIC_HOST}",
  "vm_host_port": ${VM_HOST_PORT}
}
EOF

# ② cred 接入：`[verify]` / `[init]` / `[publish]`
#
# `require_signature` / `insecure_tls` 用**字符串**（`"true"`）而不是 bool：
# cred-peer 的配置解析两种都认，但字符串能原样表达“这一版还没定”的空值。
write_json "${FIELD_API_DIR}/cred.value.json" cat <<EOF
{
  "field_api_audience": "${FIELD_API_AUDIENCE}",
  "field_api_require_cred_signature": "${FIELD_API_REQUIRE_CRED_SIGNATURE}",
  "field_api_insecure_tls": "${FIELD_API_CRED_INSECURE_TLS}",
  "field_api_cred_url": "${FIELD_API_CRED_URL}",
  "field_api_cred_ca_file": "${FIELD_API_CRED_CA_FILE}",
  "field_api_advertise_host": "${FIELD_API_ADVERTISE_HOST}",
  "credentials_host_port": ${CREDENTIALS_HOST_PORT}
}
EOF

# ③ 证据服务：读监听端口（与 BFF / compose 健康检查同一个来源）
write_json "${EVIDENCE_DIR}/wist-evidence.value.json" cat <<EOF
{
  "evidence_read_port": ${EVIDENCE_READ_PORT}
}
EOF
