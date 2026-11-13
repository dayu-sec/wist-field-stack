#!/usr/bin/env bash
# wist-harvest（云资产采集）集成的配置回归。
#
#   ./dev/tests/harvest-config.test.sh
#
# 为什么钉这一组：harvest 的启用是**三个变量 + 一份渲染值**共同决定的
#（`HARVEST_TENANT_ID` / `HARVEST_SINK_ENDPOINT` / `COMPOSE_PROFILES`），
# 而渲染层有两个典型的静默错误：
#   · handlebars 把**不存在的占位符渲染成空串**（拼错一个字母 = 配置项悄悄消失）；
#   · 「关掉」很容易做成「文件消失」或「渲染出一个空租户的数据源」——
#     后者会真的拿错租户去云上采一遍，错得静默且彻底。
#
# 全部在沙箱里跑（`lib/sandbox.sh`）：不碰真栈的 `.env`、`configs/`、密钥。
# 模板渲染用 `gx run -c <临时 gxl>`（真 handlebars，不是测试里伪造的渲染）：
# 没装 gx 时只跳过渲染断言，其余照跑。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sandbox.sh
. "${HERE}/lib/sandbox.sh"

# 计数器由 `lib/sandbox.sh` 里的 test_ok / test_no 维护（跨文件，shellcheck 看不见）
# shellcheck disable=SC2034
TEST_PASS=0
# shellcheck disable=SC2034
TEST_FAIL=0

sandbox_init
S="${SANDBOX}"
HARVEST_DIR="${S}/configs/harvest"
VALUE_JSON="${HARVEST_DIR}/harvest.value.json"
SOURCE_TOML="${HARVEST_DIR}/sources.d/source.toml"
SERVICE_TOML="${HARVEST_DIR}/harvest.toml"
COMPOSE="${S}/sys/docker-compose.yml"

# 只跑两个 tpl 步骤的最小流程：`gx.tpl` 是真实的 galaxy-flow 动作。
GXL="${S}/harvest-tpl.gxl"
cat >"${GXL}" <<'GXL'
mod tpls {
  flow render {
    gx.tpl ( tpl: "./sys/configs/harvest/harvest.toml.tpl", dst: "./configs/harvest/harvest.toml", file: "./configs/harvest/harvest.value.json" );
    gx.tpl ( tpl: "./sys/configs/harvest/sources.d/source.toml.tpl", dst: "./configs/harvest/sources.d/source.toml", file: "./configs/harvest/harvest.value.json" );
  }
}

mod envs  {
  #[usage(desp="default", color="green")]
  env default     {}
}

mod main : tpls {
}
GXL

expect() { # expect <标签> <期望> <实际>
  if [ "$2" = "$3" ]; then
    test_ok "$1"
  else
    test_no "$1：期望「$2」，实际「$3」"
  fi
}

# 渲染值里的某一项：`jraw` 按 JSON 输出（bool / 数组好读），`jstr` 取原始值。
jraw() {
  python3 - "${VALUE_JSON}" "$1" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
print(json.dumps(data[sys.argv[2]], ensure_ascii=False))
PY
}
jstr() {
  python3 - "${VALUE_JSON}" "$1" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
print(data[sys.argv[2]])
PY
}

# 凭据表的键名顺序（`name` 列表，逗号分隔）
jcred() {
  python3 - "${VALUE_JSON}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
print(",".join(item["name"] for item in data["harvest_credentials"]))
PY
}

# 在沙箱里带一组变量跑 init-field-config.sh（**子 shell**：变量不泄漏到下一条用例）
with_env() { # with_env <VAR=VAL>... -- <命令...>
  local assigns=()
  while [ "$1" != "--" ]; do
    assigns+=("$1")
    shift
  done
  shift
  ( export "${assigns[@]}"
    "$@" ) >/dev/null 2>&1
}

render_tpls() {
  command -v gx >/dev/null 2>&1 || return 2
  (cd "${S}" && gx run -c "${GXL}" render >/dev/null 2>&1)
}

# 主 compose 里某个服务的段落
compose_block() {
  awk -v svc="  $1:" '
    $0 == svc { inside = 1; print; next }
    inside && /^  [A-Za-z0-9_-]+:$/ { inside = 0 }
    inside { print }
  ' "${COMPOSE}"
}

echo "① 默认（产品默认值）：采集不启用"
sandbox_run init-field-config.sh >/dev/null || test_no "init-field-config.sh 失败"
expect "harvest_enabled" "false" "$(jraw harvest_enabled)"
expect "sink 端点为空" "" "$(jstr harvest_sink_endpoint)"
expect "vendor 归一成 harvest 认的字面量" "TENCENT_CLOUD" "$(jstr harvest_vendor)"
expect "腾讯云凭据只写引用（两件套，顺序固定）" "secret_id,secret_key" "$(jcred)"
expect "地域默认 auto" '"auto"' "$(jstr harvest_regions_literal)"

render_tpls
render_rc=$?
if [ "${render_rc}" -eq 2 ]; then
  echo "  skip 未安装 gx：跳过模板渲染断言"
else
  if [ "${render_rc}" -ne 0 ]; then
    test_no "gx tpl 渲染失败（源码见 ${GXL}）"
  fi
  if grep -q '^source_code' "${SOURCE_TOML}"; then
    test_no "未启用时渲染出了可用的数据源（会拿空租户去采）"
  else
    test_ok "未启用时数据源渲染成「只有注释」"
  fi
  if grep -q '采集未启用' "${SOURCE_TOML}"; then
    test_ok "未启用的原因与启用步骤写在了渲染产物里"
  else
    test_no "渲染产物没有说明「为什么没启用」"
  fi
  if grep -q '^endpoint = ""$' "${SERVICE_TOML}"; then
    test_ok "服务配置端点为空（服务不启动，端点是现场值）"
  else
    test_no "服务配置的 endpoint 不是空串"
  fi
fi

echo "② 腾讯云 + 账单账号：启用"
with_env HARVEST_TENANT_ID=DEV-1 HARVEST_SINK_ENDPOINT=wparse:9101 \
  HARVEST_BILLING_ACCOUNT=100041355715 -- sandbox_run init-field-config.sh \
  || test_no "init-field-config.sh（启用态）失败"
expect "harvest_enabled" "true" "$(jraw harvest_enabled)"
expect "tenant_id" "DEV-1" "$(jstr harvest_tenant_id)"
expect "成本链路随账单账号打开" "true" "$(jraw harvest_cost_enabled)"
expect "币种由厂商定（腾讯云国内账号）" "CNY" "$(jstr harvest_cost_currency)"

if [ "${render_rc}" -ne 2 ]; then
  render_tpls || test_no "gx tpl 渲染失败（启用态）"
  for line in \
    '^tenant_id = "DEV-1"$' \
    '^vendor = "TENCENT_CLOUD"$' \
    '^billing_account = "100041355715"$' \
    '^currency = "CNY"$' \
    '^secret_id = \{ file = "/sec/sec-value.yml", field = "SEC_TENCENT_SECRET_ID" \}$' \
    '^secret_key = \{ file = "/sec/sec-value.yml", field = "SEC_TENCENT_SECRET_KEY" \}$'; do
    if grep -qE "${line}" "${SOURCE_TOML}"; then
      test_ok "数据源里有 ${line}"
    else
      test_no "数据源里缺 ${line}"
    fi
  done
  if grep -q '^endpoint = "wparse:9101"$' "${SERVICE_TOML}"; then
    test_ok "服务配置渲染出现场 sink 端点"
  else
    test_no "服务配置没有渲染出 sink 端点"
  fi
  # TOML 必须能被真正解析：占位符拼错时 handlebars 渲成空串，这里才会露出来。
  if python3 -c 'import tomllib' 2>/dev/null; then
    if python3 - "${SOURCE_TOML}" "${SERVICE_TOML}" <<'PY'
import sys
import tomllib

for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        tomllib.load(handle)
PY
    then
      test_ok "渲染产物是合法 TOML（tomllib）"
    else
      test_no "渲染产物不是合法 TOML"
    fi
  else
    echo "  skip python3 没有 tomllib（< 3.11）：跳过 TOML 解析断言"
  fi
fi

echo "③ AWS：厂商专属的凭据键 / vendor_options / 地域列表"
with_env HARVEST_TENANT_ID=DEV-1 HARVEST_SINK_ENDPOINT=wparse:9101 HARVEST_VENDOR=aws \
  HARVEST_AWS_PARTITION=aws-cn HARVEST_SOURCE_CODE=aws-prod \
  HARVEST_REGIONS='ap-east-1, us-east-1' HARVEST_BILLING_ACCOUNT=123456789012 \
  -- sandbox_run init-field-config.sh || test_no "init-field-config.sh（AWS）失败"
expect "vendor 归一成 AWS" "AWS" "$(jstr harvest_vendor)"
expect "AWS 凭据键名" "access_key_id,secret_access_key" "$(jcred)"
expect "地域列表转成 TOML 数组字面量" '["ap-east-1", "us-east-1"]' "$(jstr harvest_regions_literal)"
expect "AWS 账单未实现：不渲染成本链路" "false" "$(jraw harvest_cost_enabled)"

if [ "${render_rc}" -ne 2 ]; then
  render_tpls || test_no "gx tpl 渲染失败（AWS）"
  for line in \
    '^vendor = "AWS"$' \
    '^regions = \["ap-east-1", "us-east-1"\]$' \
    '^access_key_id = \{ file = "/sec/sec-value.yml", field = "SEC_AWS_ACCESS_KEY_ID" \}$' \
    '^partition = "aws-cn"$'; do
    if grep -qE "${line}" "${SOURCE_TOML}"; then
      test_ok "数据源里有 ${line}"
    else
      test_no "数据源里缺 ${line}"
    fi
  done
  if grep -q '^\[cost\]' "${SOURCE_TOML}" || grep -q '^billing_account' "${SOURCE_TOML}"; then
    test_no "AWS 渲染了成本链路（账单 reader 还没实现，会必然报错且币种是错的）"
  else
    test_ok "AWS 没有渲染成本链路"
  fi
fi

echo "④ 模板占位符必须都有渲染值（handlebars 会把未定义的渲成空串）"
python3 - "${S}" <<'PY'
import json
import re
import sys

stack = sys.argv[1]
data = json.load(open(f"{stack}/configs/harvest/harvest.value.json", encoding="utf-8"))


def all_keys(node):
    """渲染值里可用的名字：顶层键 + 数组元素对象的键（`{{#each}}` 里的 item 字段）。"""
    keys = set()
    if isinstance(node, dict):
        for key, value in node.items():
            keys.add(key)
            keys |= all_keys(value)
    elif isinstance(node, list):
        for item in node:
            keys |= all_keys(item)
    return keys


available = all_keys(data)
tpls = [
    f"{stack}/sys/configs/harvest/harvest.toml.tpl",
    f"{stack}/sys/configs/harvest/sources.d/source.toml.tpl",
]
helpers = {"if", "each", "else", "unless", "with"}
missing = []
used = set()
for path in tpls:
    text = open(path, encoding="utf-8").read()
    for raw in re.findall(r"\{\{\{?\s*([^}]+?)\s*\}?\}\}", text):
        raw = raw.strip()
        if raw.startswith("!"):
            continue
        token = raw.lstrip("#/^").strip()
        name = token.split()[-1] if token.split() else ""
        if not name or name in helpers:
            continue
        used.add(name)
        if name not in available:
            missing.append(f"{path}: {name}")

if missing:
    print("  FAIL 占位符没有渲染值：" + ", ".join(missing))
    sys.exit(1)
print(f"  ok   占位符全部有渲染值（{len(used)} 个）")
PY
[[ $? -eq 0 ]] || test_no "模板占位符与渲染值不一致"

echo "⑤ compose 接线：可选 profile / 运行身份 / 挂载 / 健康检查"
BLOCK="$(compose_block harvest)"
if [ -n "${BLOCK}" ]; then
  test_ok "主 compose 定义了 harvest 服务"
else
  test_no "主 compose 没有 harvest 服务"
fi
for pattern in \
  'profiles: ["harvest"]' \
  'user: "10001:10001"' \
  './configs/harvest:/etc/wist-harvest:ro' \
  './.wist:/sec:ro'; do
  if printf '%s\n' "${BLOCK}" | grep -qF "${pattern}"; then
    test_ok "harvest 段有 ${pattern}"
  else
    test_no "harvest 段缺 ${pattern}"
  fi
done
if printf '%s\n' "${BLOCK}" | grep -q '^\s*ports:'; then
  test_no "harvest 发布了宿主端口（它没有入站面）"
else
  test_ok "harvest 没有宿主端口"
fi
if printf '%s\n' "${BLOCK}" | grep -q 'diagnose'; then
  test_ok "健康检查用 diagnose（离线、不输出凭据）"
else
  test_no "健康检查没有用 diagnose"
fi
if printf '%s\n' "${BLOCK}" | grep -q 'SEC_TENCENT_SECRET_ID'; then
  test_no "凭据进了 compose 环境变量（会在 docker inspect 里裸奔）"
else
  test_ok "凭据没有进 compose 环境变量（只从 .wist 读）"
fi

echo "⑥ 配错就当场失败（不静默）"
if with_env HARVEST_TENANT_ID=DEV-1 HARVEST_SINK_ENDPOINT=wparse:9101 HARVEST_VENDOR=gcp \
  -- sandbox_run init-field-config.sh; then
  test_no "未知厂商应该被拒绝"
else
  test_ok "未知厂商被拒绝"
fi
if with_env HARVEST_TENANT_ID=DEV-1 HARVEST_SINK_ENDPOINT=no-port \
  -- sandbox_run init-field-config.sh; then
  test_no "sink 端点缺端口应该被拒绝"
else
  test_ok "sink 端点缺端口被拒绝"
fi

test_summary
