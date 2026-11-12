#!/usr/bin/env bash
# 客户 id 在 field **内部**的四处必须一致（S1）。
#
#   ./dev/tests/customer-id-alignment.test.sh
#
# 为什么钉：一套栈里客户 id 出现在四个地方 ——
#   ① `configs/cells/cells.json`                 客户清单（唯一真相，add-customer.sh 维护）
#   ② `configs/cells/compose.yml`                每客户的 PG 编排片段
#   ③ `configs/evidence/wist-evidence.toml`      `[[storage.cell]]`（证据库路由）
#   ④ `configs/atlas/cells.json`                 拓扑库路由
#   ⑤ `configs/field-api/field-api.toml`         `allowed_tenants`（BFF 可选客户）
# 只要有一处落后（忘了 localize、手改了清单），就会出现「客户 A 的证据能写、拓扑看不到」
# 这种半通不通的状态，而且**没有任何报错**。
#
# 边界（**重要**）：这是 **field 内部**的一致性。
# `cells.json` 只服务 field 自己（evidence / atlas / BFF），**与中心、网关没有共享校验** ——
# 客户 id 必须等于网关绑定的 `tenant_id`，那是网关侧的事（见 docs/multi-customer.md §6），
# 本用例**不读** `.env`、中心、`identity/gwlinkd/business-identity.json`，也不比对它们。
#
# 两段：
#   A. 沙箱：用产品默认 `.env` 从零生成一遍，比较生成物（CI 只跑这一段 —— 无现场态）
#   B. 现场：栈根 `configs/` 已有渲染产物时，比较**运行时真正读到的那几份**（本地 / 现场跑）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=lib/sandbox.sh
. "${HERE}/lib/sandbox.sh"

# 计数器由 `lib/sandbox.sh` 里的 test_ok / test_no 维护（跨文件，shellcheck 看不见）
# shellcheck disable=SC2034
TEST_PASS=0
# shellcheck disable=SC2034
TEST_FAIL=0

# 从各份清单里取 cust_id 集合（每行一个，已排序去重），用于 diff。
dump_cust_ids() {
  python3 - "$1" "$2" <<'PY'
import json
import re
import sys

kind, path = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

if kind == "cells_json":
    values = [cell["cust_id"] for cell in json.loads(text)]
elif kind == "evidence_value":
    values = [cell["cust_id"] for cell in json.loads(text)["evidence_cells"]]
elif kind == "atlas_cells":
    values = [cell["cust_id"] for cell in json.loads(text)["cells"]]
elif kind == "allowed_value":
    # 渲染值是**字符串**：`"A", "B"`（模板用三花括号原样塞进 TOML 的数组里）
    raw = json.loads(text)["evidence_allowed_tenants"].strip()
    values = json.loads("[" + raw + "]") if raw else []
elif kind == "allowed_toml":
    match = re.search(r"^allowed_tenants\s*=\s*\[(.*?)\]", text, re.M | re.S)
    raw = match.group(1).strip() if match else ""
    values = json.loads("[" + raw + "]") if raw else []
elif kind == "evidence_toml":
    # 每个 `[[storage.cell]]` 段里的 cust_id（段体里有 `[storage.cell.index]`，
    # 所以不能靠「遇到 `[` 就停」，用下一段 `[[storage.cell]]` 当边界）。
    values = []
    for block in re.findall(
        r"^\[\[storage\.cell\]\][^\n]*\n(.*?)(?=^\[\[storage\.cell\]\]|\Z)",
        text,
        re.M | re.S,
    ):
        found = re.search(r'^cust_id\s*=\s*"([^"]+)"', block, re.M)
        if found:
            values.append(found.group(1))
elif kind == "compose":
    # 服务名 `pg-<cust>` / `pg-<cust>-atlas` → cust
    values = []
    for match in re.finditer(r"^  (pg-\S+):\s*$", text, re.M):
        name = match.group(1)[len("pg-"):]
        if name.endswith("-atlas"):
            name = name[: -len("-atlas")]
        values.append(name)
else:
    raise SystemExit(f"unknown kind: {kind}")

print("\n".join(sorted(set(values))))
PY
}

# expect_same <标签> <基准文件> <待比对文件>
expect_same() {
  local label="$1" base="$2" other="$3"
  if diff -q "${base}" "${other}" >/dev/null; then
    test_ok "${label}"
  else
    test_no "${label}（< 基准 | > 这份）"
    diff "${base}" "${other}" | sed 's/^/       /' >&2
  fi
}

# ── A. 沙箱：从零生成一遍 ────────────────────────────────────────────────
echo "① 沙箱：两客户从零生成，四处清单必须一致"
sandbox_init
# 暂存目录放在沙箱里：退出时随沙箱一起删（不另注册 EXIT trap，免得互相覆盖）。
TMP="${SANDBOX}/.test-tmp"
mkdir -p "${TMP}"
# 客户 id 挑成「带连字符」的形状：它同时是目录名、compose 服务后缀、密钥变量名片段。
sandbox_run add-customer.sh DEV-X4 >/dev/null
sandbox_run add-customer.sh DEV-Y5 >/dev/null
sandbox_run init-field-config.sh >/dev/null

S="${SANDBOX}"
BASE="${TMP}/base.txt"
dump_cust_ids cells_json "${S}/configs/cells/cells.json" >"${BASE}"
if [ "$(wc -l <"${BASE}" | tr -d ' ')" = "2" ]; then
  test_ok "清单固化两个客户（$(tr '\n' ' ' <"${BASE}")）"
else
  test_no "清单应有 2 个客户，实际：$(tr '\n' ' ' <"${BASE}")"
fi

dump_cust_ids evidence_value "${S}/configs/evidence/wist-evidence.value.json" >"${TMP}/evidence_value.txt"
expect_same "证据库路由（evidence_cells）与清单一致" "${BASE}" "${TMP}/evidence_value.txt"

dump_cust_ids atlas_cells "${S}/configs/atlas/cells.json" >"${TMP}/atlas.txt"
expect_same "拓扑库路由（atlas cells.json）与清单一致" "${BASE}" "${TMP}/atlas.txt"

dump_cust_ids allowed_value "${S}/configs/field-api/field-api.value.json" >"${TMP}/allowed.txt"
expect_same "BFF 可选客户（allowed_tenants）与清单一致" "${BASE}" "${TMP}/allowed.txt"

dump_cust_ids compose "${S}/configs/cells/compose.yml" >"${TMP}/compose.txt"
expect_same "compose 片段（pg-<cust> 与 pg-<cust>-atlas）与清单一致" "${BASE}" "${TMP}/compose.txt"

# 删一个客户后四处一起缩：只改清单不动别处，是最常见的半成品状态。
sandbox_run add-customer.sh --remove DEV-Y5 >/dev/null
sandbox_run init-field-config.sh >/dev/null
dump_cust_ids cells_json "${S}/configs/cells/cells.json" >"${BASE}"
for pair in \
  "evidence_value:configs/evidence/wist-evidence.value.json" \
  "atlas_cells:configs/atlas/cells.json" \
  "allowed_value:configs/field-api/field-api.value.json" \
  "compose:configs/cells/compose.yml"; do
  kind="${pair%%:*}"
  file="${pair#*:}"
  dump_cust_ids "${kind}" "${S}/${file}" >"${TMP}/after.txt"
  expect_same "注销一个客户后仍一致：${file}" "${BASE}" "${TMP}/after.txt"
done

# ── B. 现场：运行时真正读到的那几份 ─────────────────────────────────────
echo "② 现场：栈根 configs/ 的渲染产物（没有就跳过）"
LIVE_EVIDENCE="${REPO}/configs/evidence/wist-evidence.toml"
LIVE_FIELD_API="${REPO}/configs/field-api/field-api.toml"
LIVE_CELLS="${REPO}/configs/cells/cells.json"
LIVE_COMPOSE="${REPO}/configs/cells/compose.yml"
LIVE_ATLAS="${REPO}/configs/atlas/cells.json"

if [ -f "${LIVE_CELLS}" ] && [ -f "${LIVE_EVIDENCE}" ] && [ -f "${LIVE_FIELD_API}" ]; then
  dump_cust_ids cells_json "${LIVE_CELLS}" >"${TMP}/live_base.txt"
  test_ok "现场清单：$(tr '\n' ' ' <"${TMP}/live_base.txt")"

  dump_cust_ids evidence_toml "${LIVE_EVIDENCE}" >"${TMP}/live_evidence.txt"
  expect_same "configs/evidence/wist-evidence.toml 的 [[storage.cell]] 与清单一致" \
    "${TMP}/live_base.txt" "${TMP}/live_evidence.txt"

  dump_cust_ids allowed_toml "${LIVE_FIELD_API}" >"${TMP}/live_allowed.txt"
  expect_same "configs/field-api/field-api.toml 的 allowed_tenants 与清单一致" \
    "${TMP}/live_base.txt" "${TMP}/live_allowed.txt"

  if [ -f "${LIVE_ATLAS}" ]; then
    dump_cust_ids atlas_cells "${LIVE_ATLAS}" >"${TMP}/live_atlas.txt"
    expect_same "configs/atlas/cells.json 与清单一致" "${TMP}/live_base.txt" "${TMP}/live_atlas.txt"
  else
    test_no "缺 configs/atlas/cells.json（localize 没跑过？）"
  fi

  if [ -f "${LIVE_COMPOSE}" ]; then
    dump_cust_ids compose "${LIVE_COMPOSE}" >"${TMP}/live_compose.txt"
    expect_same "configs/cells/compose.yml 与清单一致" "${TMP}/live_base.txt" "${TMP}/live_compose.txt"
  else
    test_no "缺 configs/cells/compose.yml（localize 没跑过？）"
  fi
else
  echo "  跳过：本仓没有渲染产物（CI 正常；现场跑这个用例才有意义）"
fi

test_summary
