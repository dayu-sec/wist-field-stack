#!/usr/bin/env bash
# 从栈根 `.env` 读现场值注入环境变量（**显式给出的环境变量优先**）。
#
# 为什么需要它：`gops run start` / `gx run localize` 都**不会**把 `.env` 导出给子进程。
# `gx run localize` 由 `gops sys localize` 拉起时，合并后的系统变量已经以**环境变量**注入
# （那是最全的一份）；但人工跑 `gx run localize` / `bash sys/scripts/init-stack.sh` 时没有 ——
# 不读 `.env` 就会回落脚本里的兜底值（症状：证书签给 localhost、渲染出 127.0.0.1）。
#
# 不 `source` 而逐行解析：避免 `.env` 里的内容被当成 shell 执行。
#
# 用法：
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/env-defaults.sh"
#   load_env_defaults "${STACK_ROOT}"
load_env_defaults() {
  local stack_root="$1"
  local env_file="${stack_root}/.env" line key value
  [ -f "${env_file}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in '' | '#'*) continue ;; esac
    case "${line}" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    # 键必须是合法变量名（挡掉 `export K=V` 这类写法）
    case "${key}" in '' | *[!A-Za-z0-9_]*) continue ;; esac
    # 去外层引号（gops 会把空值写成 `KEY=""`）
    case "${value}" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    value="${value%$'\r'}"
    # 已经显式给过的环境变量不覆盖（bash 3.2 没有 ${!var}，用 printenv 判空）
    if [ -z "$(printenv "${key}" || true)" ]; then
      export "${key}=${value}"
    fi
  done < "${env_file}"
}
