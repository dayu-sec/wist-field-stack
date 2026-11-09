#!/usr/bin/env bash
# `.env.example` 必须与 `sys/merged_vars.yml` 逐键一致。
#
#   ./dev/tests/env-example-drift.test.sh
#
# 为什么钉：`.env.example` 是**入库文件**、CI 拿它渲染 compose，但 `gops sys update`
# **不会**重写它。于是每加一个变量 / 每升一个镜像 tag，只要忘了手工同步，它就会静默落后
# —— 之前它还钉着 CONSOLE_* 与 v0.1.13-alpha，落后了好几个发布。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_REAL="$(cd "${HERE}/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*" >&2; }

# merged_vars.yml：`- name: KEY` 后面跟 `  value: VALUE`（value 可能带引号）
awk '
  /^- name: / { key = $3; next }
  /^  value:/ {
    line = $0
    sub(/^  value:[[:space:]]*/, "", line)
    gsub(/^["'"'"']/, "", line)
    gsub(/["'"'"']$/, "", line)
    if (key != "") print key "=" line
    key = ""
  }
' "${STACK_REAL}/sys/merged_vars.yml" | sort >"${TMP}/merged.txt"

# .env.example：KEY=VALUE（跳过注释与空行）
awk '!/^[[:space:]]*(#|$)/ && index($0, "=") > 0 { print }' \
  "${STACK_REAL}/.env.example" | sort >"${TMP}/example.txt"

echo "① 键集合必须一致"
if diff -q <(cut -d= -f1 "${TMP}/merged.txt" | sort) \
  <(cut -d= -f1 "${TMP}/example.txt" | sort) >/dev/null; then
  ok "键集合一致（$(wc -l <"${TMP}/merged.txt" | tr -d ' ') 个）"
else
  no "键集合不一致："
  diff <(cut -d= -f1 "${TMP}/merged.txt" | sort) \
    <(cut -d= -f1 "${TMP}/example.txt" | sort) | sed 's/^/       /' >&2
fi

echo "② 同名键的值必须一致（tag 落后就是在这里露出来的）"
if diff -q "${TMP}/merged.txt" "${TMP}/example.txt" >/dev/null; then
  ok "值全部一致"
else
  no "值不一致（< merged_vars.yml | > .env.example）："
  diff "${TMP}/merged.txt" "${TMP}/example.txt" | sed 's/^/       /' >&2
fi

echo
printf '通过 %d，失败 %d\n' "${pass}" "${fail}"
[[ ${fail} -eq 0 ]]
