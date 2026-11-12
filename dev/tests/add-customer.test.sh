#!/usr/bin/env bash
# `add-customer.sh` 的回归：登记 / 幂等 / 注销 / 删除保护（S10）。
#
#   ./dev/tests/add-customer.test.sh
#
# 为什么钉：客户登记是「加一个客户」的唯一入口，它写的是**现场态**（清单 / 密钥 / 数据目录），
# 错一步的代价是「客户数据落到别人的库」「注销后密钥还在」「误删客户目录」。
# 全部在沙箱里跑：不碰真栈的清单、密钥与数据目录。
#
# 这里**不**断言 compose 片段（那是 localize 的产物，见 customer-id-alignment.test.sh）——
# 反而要钉住「add-customer 不再改编排」，否则两份生成器又会分叉。
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
TMP="${S}/.test-tmp"
mkdir -p "${TMP}"
CELLS="${S}/configs/cells/cells.json"
COMPOSE="${S}/configs/cells/compose.yml"
SEC="${S}/.wist/sec-value.yml"

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

# 客户清单里某个客户的某个字段（`-` = 没有这个客户）
cell_field() {
  python3 - "${CELLS}" "$1" "$2" <<'PY'
import json
import sys

path, cust, field = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    cells = json.load(handle)
hit = next((cell for cell in cells if cell.get("cust_id") == cust), None)
print("-" if hit is None else hit.get(field, "-"))
PY
}

cell_count() {
  python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1], encoding="utf-8"))))' "${CELLS}"
}

expect() { # expect <标签> <期望> <实际>
  if [ "$2" = "$3" ]; then
    test_ok "$1"
  else
    test_no "$1：期望「$2」，实际「$3」"
  fi
}

echo "① 登记一个客户"
sandbox_run add-customer.sh DEV-1 >/dev/null || test_no "add-customer.sh DEV-1 失败"
expect "清单里只有 1 个客户" "1" "$(cell_count)"
expect "cust_id" "DEV-1" "$(cell_field DEV-1 cust_id)"
expect "证据库对象目录（容器内）" "/data-customers/DEV-1/objects" "$(cell_field DEV-1 objects_dir)"
expect "证据库 DSN 走密钥占位" '${SEC_EVIDENCE_DB_URL_DEV_1}' "$(cell_field DEV-1 database_url)"
expect "数据根" "${S}/customers/DEV-1" "$(cell_field DEV-1 host_dir)"
expect "拓扑库数据目录" "${S}/customers/DEV-1/pg-atlas" "$(cell_field DEV-1 atlas_host_dir)"
if python3 -c 'import sys,uuid; uuid.UUID(sys.argv[1])' "$(cell_field DEV-1 atlas_tenant_id)" 2>/dev/null; then
  test_ok "拓扑租户是固化下来的 UUID（$(cell_field DEV-1 atlas_tenant_id)）"
else
  test_no "拓扑租户不是合法 UUID：$(cell_field DEV-1 atlas_tenant_id)"
fi
for dir in pg objects pg-atlas; do
  if [ -d "${S}/customers/DEV-1/${dir}" ]; then
    test_ok "数据目录已建：customers/DEV-1/${dir}"
  else
    test_no "缺数据目录：customers/DEV-1/${dir}"
  fi
done
if grep -q '^SEC_EVIDENCE_DB_URL_DEV_1: "postgres://evidence:evidence-dev-only@pg-DEV-1:5432/wist_evidence"$' "${SEC}"; then
  test_ok "密钥已写入（库地址指向 pg-DEV-1）"
else
  test_no "密钥内容不对：$(grep '^SEC_EVIDENCE_DB_URL_DEV_1:' "${SEC}" || echo '缺失')"
fi
expect "密钥文件权限" "640" "$(file_mode "${SEC}")"

# S3 的契约：加客户**不**改编排，等 localize 从清单重生成。
if [ -f "${COMPOSE}" ]; then
  test_no "add-customer.sh 不该生成 compose 片段（应留给 localize）"
else
  test_ok "没有越权生成 compose 片段"
fi

echo "② 重复登记是幂等的"
ATLAS_BEFORE="$(cell_field DEV-1 atlas_tenant_id)"
sandbox_run add-customer.sh DEV-1 >/dev/null
expect "仍然只有 1 个客户（不重复插）" "1" "$(cell_count)"
expect "拓扑租户 UUID 不变（不重算）" "${ATLAS_BEFORE}" "$(cell_field DEV-1 atlas_tenant_id)"

echo "③ localize 从清单生成编排"
sandbox_run init-field-config.sh >/dev/null || test_no "init-field-config.sh 失败"
for service in pg-DEV-1 pg-DEV-1-atlas; do
  if grep -q "^  ${service}:\$" "${COMPOSE}"; then
    test_ok "compose 片段有 ${service}"
  else
    test_no "compose 片段缺 ${service}"
  fi
done
if grep -q '^      - .*/customers/DEV-1/pg-atlas:/var/lib/postgresql/data$' "${COMPOSE}"; then
  test_ok "拓扑库卷不重复拼 pg-atlas 前缀"
else
  test_no "拓扑库卷路径不对：$(grep 'pg-atlas:/var/lib' "${COMPOSE}" || echo '缺失')"
fi

echo "④ --pg-port 只给该客户开宿主端口"
sandbox_run add-customer.sh DEV-2 --pg-port 55499 >/dev/null
sandbox_run init-field-config.sh >/dev/null
if grep -q '55499:5432' "${COMPOSE}"; then
  test_ok "compose 片段带上 55499:5432"
else
  test_no "compose 片段没有 55499:5432"
fi
# 再登记一次不带 --pg-port：端口应消失（清单是唯一真相，不是叠加）
sandbox_run add-customer.sh DEV-2 >/dev/null
sandbox_run init-field-config.sh >/dev/null
if grep -q '55499:5432' "${COMPOSE}"; then
  test_no "重新登记后端口没被清掉（清单与编排分叉）"
else
  test_ok "重新登记（不带 --pg-port）后端口被清掉"
fi

echo "⑤ 注销：只退登记，数据默认保留"
sandbox_run add-customer.sh --remove DEV-2 >/dev/null
expect "清单里没有 DEV-2" "-" "$(cell_field DEV-2 cust_id)"
[ "$(cell_count)" = "1" ] && test_ok "清单剩 1 个客户" || test_no "清单应剩 1 个，实际 $(cell_count)"
if grep -q '^SEC_EVIDENCE_DB_URL_DEV_2:' "${SEC}"; then
  test_no "注销后密钥还在（SEC_EVIDENCE_DB_URL_DEV_2）"
else
  test_ok "密钥已移除"
fi
if [ -d "${S}/customers/DEV-2" ]; then
  test_ok "数据目录保留（不加 --purge-data 不许删）"
else
  test_no "数据目录被删了（未加 --purge-data）"
fi
sandbox_run init-field-config.sh >/dev/null
if grep -q 'pg-DEV-2' "${COMPOSE}"; then
  test_no "注销后编排片段仍有 pg-DEV-2"
else
  test_ok "编排片段跟着清单缩"
fi

echo "⑥ 删除保护：目录末段不是 cust_id 时拒绝 --purge-data"
sandbox_run add-customer.sh DEV-3 >/dev/null
# 把清单里的 host_dir 改成「末段不等于 DEV-3」的目录（模拟早期手工登记 / 抄错的清单）
python3 - "${CELLS}" "${S}/customers/not-DEV-3" <<'PY'
import json
import sys

path, bogus = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    cells = json.load(handle)
for cell in cells:
    if cell.get("cust_id") == "DEV-3":
        cell["host_dir"] = bogus
        cell["atlas_host_dir"] = bogus + "/pg-atlas"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(cells, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
mkdir -p "${S}/customers/not-DEV-3/pg"
if sandbox_run add-customer.sh --remove DEV-3 --purge-data >"${TMP}/purge.log" 2>&1; then
  test_no "--purge-data 应该被拒绝（目录末段不是 DEV-3）"
else
  test_ok "--purge-data 被拒绝（$(tail -1 "${TMP}/purge.log" | sed 's/^ *//')）"
fi
if [ -d "${S}/customers/not-DEV-3" ]; then
  test_ok "可疑目录没有被删"
else
  test_no "可疑目录被删了（删除保护失效）"
fi

echo "⑦ 客户 id 校验"
if sandbox_run add-customer.sh 'bad id' >"${TMP}/bad.log" 2>&1; then
  test_no "非法 cust_id 应该被拒绝"
else
  test_ok "非法 cust_id 被拒绝（$(head -1 "${TMP}/bad.log")）"
fi

test_summary
