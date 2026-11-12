#!/usr/bin/env bash
# `dev/tests/*.test.sh` 的公共夹具：在临时目录里造一个「只有 sys/ + 产品默认 .env」的栈根。
#
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sandbox.sh"
#   sandbox_init                       # → $SANDBOX，EXIT 时自动删
#   sandbox_run add-customer.sh DEV-1  # 在沙箱栈根里跑 sys/scripts/<脚本>
#
# 为什么不在真栈根上跑：这些用例会写 `cells.json` / 密钥文件 / compose 片段，
# 在真栈上跑等于拿现场的客户清单做实验。
#
# 为什么 `.env` 取 `.env.example`：那是**入库的产品默认**（含 dev 口令）。
# 现场 `.env` 是 localize 生成物、不入库，也不该被测试读到。
sandbox_init() {
  local here repo
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo="$(cd "${here}/../../.." && pwd)"

  SANDBOX="$(mktemp -d)"
  # shellcheck disable=SC2064  # 故意在注册时展开
  trap "rm -rf '${SANDBOX}'" EXIT

  cp -R "${repo}/sys" "${SANDBOX}/sys"
  # `sys/.wist/` 是现场密钥（gitignored）；沙箱不需要，也不能往 /tmp 里抄一份。
  rm -rf "${SANDBOX}/sys/.wist"
  cp "${repo}/.env.example" "${SANDBOX}/.env"
  export SANDBOX
}

# 在沙箱栈根里跑一个 `sys/scripts/` 下的脚本（参数原样透传）。
sandbox_run() {
  local script="$1"
  shift
  (cd "${SANDBOX}" && bash "sys/scripts/${script}" "$@")
}

# 极简断言工具（与 `dev/tests/env-example-drift.test.sh` 同一套输出口径）
test_ok() {
  TEST_PASS=$((TEST_PASS + 1))
  printf '  ok   %s\n' "$*"
}
test_no() {
  TEST_FAIL=$((TEST_FAIL + 1))
  printf '  FAIL %s\n' "$*" >&2
}
test_summary() {
  echo
  printf '通过 %d，失败 %d\n' "${TEST_PASS}" "${TEST_FAIL}"
  [ "${TEST_FAIL}" -eq 0 ]
}
