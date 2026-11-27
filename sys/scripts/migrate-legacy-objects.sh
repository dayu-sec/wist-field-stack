#!/usr/bin/env bash
# 迁移旧证据对象布局（0.5.0 之前）：
#   <数据根>/<cust>/objects/  →  <数据根>/objects/<cust>/objects/
#
# 用法：
#   sys/scripts/migrate-legacy-objects.sh [--dry-run|--apply] [--force] [<cust_id>]
#
#   --dry-run   只检查并列出要迁移的文件（默认）
#   --apply     执行复制（幂等；**只补不覆盖**，已有文件一律跳过）
#   --force     忽略 `.migrated-to-new-layout` 标记，重新扫一遍
#   <cust_id>   只处理这个客户（默认处理 cells.json 里的全部客户）
#
# 为什么需要它：当前 compose 把 `<数据根>/objects` 挂到 `/data-customers`，cell 的
# `objects_dir` 是 `/data-customers/<cust>/objects`，所以宿主上必须落在
# `<数据根>/objects/<cust>/objects`。旧布局把正文写在 `<数据根>/<cust>/objects`，
# 索引还在 PG 里，但按新路径取文件会 404 —— 页面表现为「列表有、打开正文 502」。
#
# 脚本**不删旧目录**；迁移成功后会在旧目录写 `.migrated-to-new-layout`，
# `gops sys localize` 的旧布局提醒会据此安静下来。确认新路径可读后再自行归档旧目录。
set -euo pipefail

trap 'echo "$0 失败：第 ${LINENO} 行（退出码 $?）" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CELLS_JSON="${STACK_ROOT}/configs/cells/cells.json"

MODE="dry-run"
CUST=""
FORCE=0

die() {
  echo "错误：$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --apply) MODE="apply"; shift ;;
    --force) FORCE=1; shift ;;
    -h | --help) sed -n '2,19p' "$0"; exit 0 ;;
    -*) die "未知参数：$1（--help 看用法）" ;;
    *)
      [ -z "${CUST}" ] || die "只能给一个 cust_id（已给：${CUST}）"
      CUST="$1"
      shift
      ;;
  esac
done

[ -f "${CELLS_JSON}" ] || die "缺少客户清单：${CELLS_JSON}；先运行 sys/scripts/add-customer.sh <cust_id>"
command -v python3 >/dev/null 2>&1 || die "需要 python3（读取 cells.json）"

python3 - "${CELLS_JSON}" "${MODE}" "${CUST}" "${FORCE}" <<'PY'
import json
import os
import shutil
import sys
import time

cells_path, mode, only, force = sys.argv[1:5]
force = force == "1"

try:
    with open(cells_path, encoding="utf-8") as handle:
        cells = json.load(handle)
except (OSError, json.JSONDecodeError) as err:
    print("读取客户清单失败：%s: %s" % (cells_path, err), file=sys.stderr)
    raise SystemExit(2)
if not isinstance(cells, list):
    print("客户清单顶层必须是数组：%s" % cells_path, file=sys.stderr)
    raise SystemExit(2)

if only:
    cells = [cell for cell in cells if cell.get("cust_id") == only]
    if not cells:
        print("客户清单里没有「%s」：%s" % (only, cells_path), file=sys.stderr)
        raise SystemExit(2)

pending = 0
for cell in cells:
    cust = cell.get("cust_id")
    host = cell.get("host_dir")
    if not cust or not host:
        print("跳过：清单项缺 cust_id / host_dir：%r" % (cell,), file=sys.stderr)
        continue
    host = os.path.normpath(host)
    if os.path.basename(host) != cust:
        print("跳过 %s：host_dir 末段不是 cust_id（%s）" % (cust, host), file=sys.stderr)
        continue

    legacy = os.path.join(host, "objects")
    target = os.path.join(os.path.dirname(host), "objects", cust, "objects")
    marker = os.path.join(legacy, ".migrated-to-new-layout")

    if not os.path.isdir(legacy):
        print("%s：没有旧对象目录（%s），跳过" % (cust, legacy))
        continue
    if os.path.exists(marker) and not force:
        print("%s：已迁移（%s），跳过；重新检查加 --force" % (cust, marker))
        continue

    files = []
    for root, _, names in os.walk(legacy):
        for name in names:
            if name == ".migrated-to-new-layout":
                continue
            files.append(os.path.relpath(os.path.join(root, name), legacy))
    if not files:
        print("%s：旧对象目录为空，跳过" % cust)
        continue

    print("%s：" % cust)
    print("  旧：%s（%d 个文件）" % (legacy, len(files)))
    print("  新：%s" % target)
    missing = [rel for rel in files if not os.path.exists(os.path.join(target, rel))]
    print("  待迁移：%d（新布局已有 %d）" % (len(missing), len(files) - len(missing)))
    if not missing:
        print("  新布局已包含全部旧文件")
    if mode != "apply":
        print("  dry-run：确认后加 --apply 执行（只补不覆盖）")
        pending += len(missing)
        continue

    os.makedirs(target, exist_ok=True)
    copied = 0
    skipped = 0
    for rel in files:
        src = os.path.join(legacy, rel)
        dst = os.path.join(target, rel)
        if os.path.exists(dst):
            skipped += 1
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        try:
            shutil.copyfile(src, dst)
            # 时间戳只是方便排查；保留失败不应让迁移失败（不同文件系统可能不支持）。
            try:
                shutil.copystat(src, dst)
            except OSError:
                pass
        except OSError as err:
            print("  复制失败：%s -> %s: %s" % (src, dst, err), file=sys.stderr)
            raise SystemExit(2)
        copied += 1

    try:
        with open(marker, "w", encoding="utf-8") as handle:
            handle.write("target=%s\nat=%s\n" % (target, time.strftime("%Y-%m-%dT%H:%M:%S%z")))
    except OSError as err:
        print("  警告：写迁移标记失败（下一轮 localize 会再提醒）：%s" % err, file=sys.stderr)
    print("  完成：新增 %d，已存在跳过 %d" % (copied, skipped))
    pending += copied

print()
if mode == "apply":
    print("迁移完成。旧目录保留；确认新路径可读后可自行归档/删除。")
    print("Linux：随后跑 gops sys localize（或 gops sys perms --apply）对齐属组/权限。")
else:
    print("dry-run 完成：共 %d 个文件待迁移；加 --apply 执行。" % pending)
PY
