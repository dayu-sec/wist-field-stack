#!/usr/bin/env bash
# 旧对象布局（0.5.0 前）的检测与迁移：
#   <数据根>/<cust>/objects/  →  <数据根>/objects/<cust>/objects/
#
#   ./dev/tests/legacy-objects.test.sh
#
# 为什么钉：布局换了但旧文件不会自己移动；索引还在 PG 里，页面表现为
# 「证据列表有、打开正文 502」。迁移必须只补不覆盖、可重复执行、不删旧目录。
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

sandbox_run add-customer.sh DEV-1 >/dev/null || test_no "add-customer.sh DEV-1 失败"

LEGACY_ROOT="${S}/customers/DEV-1/objects"
LEGACY="${LEGACY_ROOT}/DEV-1/investigation_report/2026/11"
TARGET="${S}/customers/objects/DEV-1/objects/DEV-1/investigation_report/2026/11"
mkdir -p "${LEGACY}"
printf 'old-a' >"${LEGACY}/art_a.json.zst"
printf 'old-b' >"${LEGACY}/art_b.json.zst"

echo "① localize 检测旧布局：只提醒，不失败"
if sandbox_run init-field-config.sh >"${TMP}/localize1.log" 2>&1; then
  test_ok "旧布局不阻塞 localize"
else
  test_no "localize 不应因旧布局失败：$(tail -3 "${TMP}/localize1.log")"
fi
if grep -q '发现旧对象布局' "${TMP}/localize1.log"; then
  test_ok "localize 提醒了旧对象布局"
else
  test_no "localize 没有提醒旧对象布局"
fi

echo "② dry-run 只检查，不复制"
sandbox_run migrate-legacy-objects.sh >"${TMP}/dry.log" 2>&1 || test_no "dry-run 失败"
if [ -e "${TARGET}/art_a.json.zst" ]; then
  test_no "dry-run 不该复制文件"
else
  test_ok "dry-run 没有复制文件"
fi
if grep -q '2 个文件' "${TMP}/dry.log"; then
  test_ok "dry-run 报出待迁移文件数"
else
  test_no "dry-run 没有报出文件数：$(tail -3 "${TMP}/dry.log")"
fi

echo "③ --apply 迁到当前挂载布局"
sandbox_run migrate-legacy-objects.sh --apply >"${TMP}/apply.log" 2>&1 || test_no "--apply 失败"
if [ "$(cat "${TARGET}/art_a.json.zst" 2>/dev/null)" = "old-a" ]; then
  test_ok "旧文件已复制到新布局"
else
  test_no "新布局没有 art_a.json.zst"
fi
if [ -f "${LEGACY_ROOT}/.migrated-to-new-layout" ]; then
  test_ok "旧目录写了迁移标记"
else
  test_no "旧目录没有迁移标记（localize 会一直提醒）"
fi

echo "④ 有标记后默认跳过，且不覆盖已有文件"
printf 'new-a' >"${TARGET}/art_a.json.zst"
printf 'old-c' >"${LEGACY}/art_c.json.zst"
sandbox_run migrate-legacy-objects.sh --apply >"${TMP}/apply2.log" 2>&1 || test_no "第二次 --apply 失败"
if [ "$(cat "${TARGET}/art_a.json.zst")" = "new-a" ]; then
  test_ok "已有文件没有被旧文件覆盖"
else
  test_no "已有文件被覆盖了（应为只补不覆盖）"
fi
if [ -e "${TARGET}/art_c.json.zst" ]; then
  test_no "有标记时不该自动扫描新增旧文件（应加 --force）"
else
  test_ok "有标记时默认跳过（需 --force 才重扫）"
fi

echo "⑤ 有迁移标记后 localize 不再重复提醒"
sandbox_run init-field-config.sh >"${TMP}/localize2.log" 2>&1 || test_no "localize 失败"
if grep -q '发现旧对象布局' "${TMP}/localize2.log"; then
  test_no "有标记后仍在提醒旧布局"
else
  test_ok "有标记后不再提醒"
fi

echo "⑥ --force 重新扫描并补标记之后新增的旧文件"
printf 'old-d' >"${LEGACY}/art_d.json.zst"
sandbox_run migrate-legacy-objects.sh --force --apply >"${TMP}/force.log" 2>&1 || test_no "--force --apply 失败"
if [ -f "${TARGET}/art_c.json.zst" ] && [ -f "${TARGET}/art_d.json.zst" ]; then
  test_ok "--force 补进了标记之后新增的旧文件"
else
  test_no "--force 没有补进 art_c / art_d"
fi

echo "⑦ 客户清单缺失时两个脚本都明确失败"
rm -f "${CELLS}"
if sandbox_run migrate-legacy-objects.sh >"${TMP}/no-cells-migrate.log" 2>&1; then
  test_no "缺清单时 migrate 应该失败"
else
  test_ok "缺清单时 migrate 失败"
fi
grep -q '客户清单' "${TMP}/no-cells-migrate.log" && test_ok "migrate 的错误信息提到客户清单" \
  || test_no "migrate 的错误信息没提客户清单"
if sandbox_run init-field-config.sh >"${TMP}/no-cells-localize.log" 2>&1; then
  test_no "缺清单时 localize 应该失败"
else
  test_ok "缺清单时 localize 失败"
fi
grep -q '客户清单' "${TMP}/no-cells-localize.log" && test_ok "localize 的错误信息提到客户清单" \
  || test_no "localize 的错误信息没提客户清单"

test_summary
