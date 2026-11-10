#!/usr/bin/env bash
# 栈根运行态备料（幂等）—— 由 `gx run localize` 在渲染完 configs/ 之后调用；
# 也可以人工单跑（它自己读栈根 `.env`，显式环境变量优先）。
#
# 为什么用**栈根**而不是 `sys/`：`gops` 用栈根作为 compose 的 project directory，
# 所以 compose 里的 `./configs/...`、`./.wist` 解析到栈根。
#
# **configs/ 不在这里**：它是 `sys/configs/*.tpl` 的渲染产物，由 `gx run localize` 的
# `gx.tpl` 生成（0.3.0 起）。以前这个脚本按“只补缺”拷种子，代价是“栈升了、运行态那份
# 还是旧的”——新加的配置项永远不生效（典型：`[metrics] write_url`、`nginx` 的 `/__init`）。
#
# 这里只管那些“不能渲染、只能备料”的东西：目录 / 密钥文件 / 自注册 setup code /
# cred 材料自检 / 前端 TLS 证书。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

note() { echo "  $*"; }

# 现场值从栈根 `.env`（`gops sys localize` 生成）读进来；显式给出的环境变量优先。
#
# 为什么必须读：本脚本按 `WEB_DOMAIN` 签 web 叶证书，而 `gops run start` **不会**
# 把 `.env` 导出给这个脚本；手工跑时不读它就会回落 `localhost`，签出一张名字
# 与站点域名不符的证书（症状：浏览器报名字不符、`init-stack.sh` 自己的回显都写着 localhost）。
# shellcheck source=lib/env-defaults.sh
. "${SCRIPT_DIR}/lib/env-defaults.sh"
load_env_defaults "${STACK_ROOT}"

# 只读挂载的属组必须是**容器 gid**：`evidence` / `field-api` 以 10001:10001 运行，
# 而 Linux 的 bind 不改属主，属组是唯一共享通道。
# 部署账号通常不是 root、也不在 10001 组里：chgrp 失败就退到 0755/0644 让栈能起
# （本机所有用户可读密钥），并提示用 root 跑 `gops sys perms --apply` 收紧。
CONTAINER_GID="${CONTAINER_GID:-10001}"

# align_ro_perms <路径> <dir|file>
align_ro_perms() {
  local path="$1" kind="$2"
  if chgrp "${CONTAINER_GID}" "${path}" 2>/dev/null; then
    if [ "${kind}" = "dir" ]; then chmod 2750 "${path}"; else chmod 0640 "${path}"; fi
    return 0
  fi
  if [ "${kind}" = "dir" ]; then chmod 0755 "${path}"; else chmod 0644 "${path}"; fi
  note "⚠ 无法把 ${path} 的属组改成 ${CONTAINER_GID}（需要 root 或属于该组）"
  note "  → 已退回 0755/0644 让容器能读（本机用户均可读）；随后以 root 执行 gops sys perms --apply 收紧"
  return 1
}

# 1) 运行态目录（栈根）
mkdir -p "${STACK_ROOT}/configs/evidence" "${STACK_ROOT}/configs/field-api" "${STACK_ROOT}/configs/web" "${STACK_ROOT}/.wist"
# 证据正文（`objects.kind = file`）：宿主上可直接看。容器内是 uid 10001，
# 而部署账号不是 10001，所以这里给到 0777（仅开发/测试栈；生产用 COS）。
# 必须先建：否则 compose 会自己建一个 root:root 的目录，容器写不进去。
mkdir -p "${STACK_ROOT}/data/evidence-objects"
chmod 0777 "${STACK_ROOT}/data/evidence-objects"
# 凭据摘要表（`store_path`）：只存 sha256，验证侧私有状态。
# 容器内是 uid 10001，与证据正文同理给到 0777（仅开发/测试栈）。
mkdir -p "${STACK_ROOT}/data/field-api"
chmod 0777 "${STACK_ROOT}/data/field-api"
note "runtime dirs: ${STACK_ROOT}/configs, ${STACK_ROOT}/.wist, ${STACK_ROOT}/data/{evidence-objects,field-api}"

# 2) configs/ 不在这里：它是 `sys/configs/*.tpl` 的渲染产物（`gx run localize` 的 gx.tpl）。
#    见文件头 —— 一次性拷贝就是 0.2.x 里“升了栈、配置还是旧的”的根因。

# 3) 权限：配置 0644（不含密钥）；密钥目录 2750、密钥文件 0640，属组 = 容器 gid
#
# **不要**把 `.wist` 收成 0700：它是只读挂进容器的，容器以 10001:10001 运行，
# 0700（属主 root）会让容器 stat 不到里面的文件 —— 症状是
# `secrets file not found: /sec/sec-value.yml`，文件明明在，只是没权限。
chmod 0755 "${STACK_ROOT}/configs" "${STACK_ROOT}/configs/evidence" "${STACK_ROOT}/configs/field-api" "${STACK_ROOT}/configs/web"
# 配置里没有密钥（密钥是 `${SEC_…}` 占位 + `.wist/` 里的真值），所以整目录 0644。
# 不只 `*.toml`：`nginx.conf` 也是渲染产物，靠容器读者（nginx master 以 root 起，后面降权）能读。
find "${STACK_ROOT}/configs" -type f -exec chmod 0644 {} +
align_ro_perms "${STACK_ROOT}/.wist" dir || true
if [ -f "${STACK_ROOT}/.wist/sec-value.yml" ]; then
  align_ro_perms "${STACK_ROOT}/.wist/sec-value.yml" file || true
else
  note "缺少 ${STACK_ROOT}/.wist/sec-value.yml：至少需要 SEC_EVIDENCE_DB_URL"
fi

# 自注册的 setup code：**部署生成**的秘密，保护“谁能给这台机器指定 cred 地址”。
# 它不能有默认值（那等于没有），也不该让人现编 —— 幂等生成，0640。
SEC_FILE="${STACK_ROOT}/.wist/sec-value.yml"
if [ -f "${SEC_FILE}" ] && ! grep -q '^SEC_FIELD_API_PEER_SETUP_CODE:' "${SEC_FILE}"; then
  setup_code="crp_$(openssl rand -hex 16 2>/dev/null || echo "$(date +%s)$$" | shasum -a 256 | cut -c1-32)"
  printf 'SEC_FIELD_API_PEER_SETUP_CODE: %s\n' "${setup_code}" >> "${SEC_FILE}"
  align_ro_perms "${SEC_FILE}" file || true
  note "已生成自注册 setup code（写入 .wist/sec-value.yml）"
  note "  → /__init 页面上要填这个；接入券（wot_…）由 cred 页面另发"
  note "  → 现在就要用的话：  echo ${setup_code}"
fi

# 4) 凭据接入材料：**两种来源**，落到同一个目录、同一套文件名
#    a) 自注册（默认）：`configs/field-api/cred.toml` 带 `[init]`，首次启动只开 `/__init`，
#       三件材料由服务自己写进 `identity/field-api/cred/`；
#    b) 接入命令（join.sh）预先写好三件材料（它写的 cred.toml 会让栈渲染的那份覆盖 ——
#       `[verify]` 本来就应该由栈决定）。
#    目录必须先存在：compose 把它可写挂到 `/cred`，源目录缺失时 docker 会建一个 root 属主的目录。
mkdir -p "${STACK_ROOT}/identity/field-api/cred"
CRED_DIR="${STACK_ROOT}/identity/field-api/cred"
RENDERED_CRED="${STACK_ROOT}/configs/field-api/cred.toml"
# 老现场收尾：`configs/field-api/cred.toml` 缺失时，docker 会在 `/cred` 里再建一个
# `cred.toml` 目录（就是上面那个坏源连带的挂载点）。留着它，`up --force-recreate`
# 会直接失败 `mount ... not a directory`。空目录清掉；非空就停下来。
if [ -d "${CRED_DIR}/cred.toml" ]; then
  if rmdir "${CRED_DIR}/cred.toml" 2>/dev/null; then
    note "  ↑ 清掉误建的目录 ${CRED_DIR}/cred.toml（应是挂载点文件）"
  else
    echo "  ✗ ${CRED_DIR}/cred.toml 是目录且非空：先人工处理，否则 field-api 起不来" >&2
    exit 1
  fi
fi
if [ -f "${CRED_DIR}/server.crt" ] && [ -f "${CRED_DIR}/server.key" ]; then
  # 容器以 uid 10001 读这份材料（server.key 由接入命令/自注册写成 0600），
  # 所以**必须**对齐属主/权限：Linux 上跑 `gops sys perms --apply`。
  note "cred materials: ${CRED_DIR}"
  note '  → 记得跑 gops sys perms --apply（容器以 uid 10001 读 server.key）'

  # 材料是不是这个服务的？接入命令可以在任何 --dir 下跑，放错了目录会表现为
  # 「一切都对，但永远 401」—— 所以这里对 audience 和角色各校一次。
  if [ -f "${CRED_DIR}/cred.toml" ]; then
    audience="$(sed -n 's/^audience[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "${CRED_DIR}/cred.toml" | head -1)"
    if [ "${audience}" != "wist-field-api" ]; then
      note "  ⚠ cred.toml 的 audience 是 \"${audience:-<空>}\"，不是 wist-field-api —— 这份材料属于别的认证系统"
    fi
    if ! grep -q '"read"' "${CRED_DIR}/cred.toml"; then
      note "  ⚠ cred.toml 的 [verify].roles 里没有 read：签发出来的令牌一律 403"
    fi
    # 这里很容易造出“改了但没生效”的假象：栈渲染的 cred.toml 盖在 `/cred/cred.toml` 上，
    # 接入命令写的那份因此**只贡献材料**，不贡献 [verify]。
    note "  ⚠ 若存在 configs/field-api/cred.toml，它会覆盖本目录的 cred.toml：[verify] 以栈为准"
    note "    （验签是否强制：FIELD_API_REQUIRE_CRED_SIGNATURE）"
  fi
  # 证书 SAN 必须覆盖 cred 连的那个名字（接入命令的 --host）。
  if [ -f "${SCRIPT_DIR}/lib/tls-san.sh" ]; then
    # shellcheck source=lib/tls-san.sh
    . "${SCRIPT_DIR}/lib/tls-san.sh"
    for name in "$(hostname)" "$(hostname -s 2>/dev/null || hostname)"; do
      if ! wist_san_covers_domain "${CRED_DIR}/server.crt" "$name" >/dev/null 2>&1; then
        note "  ⚠ server.crt 的 SAN 不含 ${name}：cred 用这个名字连过来会证书校验失败"
      fi
    done
  fi
else
  # 没材料：只要栈渲染的 cred.toml 带 `[init]`，就是正常的自注册路径。
  if [ -f "${RENDERED_CRED}" ] && grep -q '^\[init\]' "${RENDERED_CRED}"; then
    note "cred materials: 待自注册（${CRED_DIR} 还没有 server.crt / server.key / client-ca.pem）"
    note "  → 起栈后打开 https://${WEB_DOMAIN:-localhost}:${WEB_HOST_PORT:-8088}/__init"
    note "    填 setup code + 接入券；材料写进该目录，收数监听自动起来（无需重启）"
    note "  → FIELD_API_ADVERTISE_HOST 必须是真主机名，否则 field-api 启动期就拒"
  else
    note "⚠ ${RENDERED_CRED} 没有 [init]，也没有接入命令写的材料"
    note "  → field-api 会拒启。先让栈渲染出 [init]（设 FIELD_API_ADVERTISE_HOST + FIELD_API_CRED_URL），"
    note "    或者用接入命令写材料：curl -fsSLk 'https://<cred>/enroll/<券>/join.sh' | bash -s -- --dir './identity/field-api/cred' --host <本机名>"
  fi
fi

# 5) 前端 TLS：唯一浏览器入口在 web 容器里终结，没有证书 nginx 起不来。
#    已有证书则幂等复用（CA 只建一次），并打印「该导哪份 CA」。
DOMAIN="${WEB_DOMAIN:-localhost}"
if [ -x "${STACK_ROOT}/sys/scripts/init-web-tls.sh" ]; then
  bash "${STACK_ROOT}/sys/scripts/init-web-tls.sh" "$DOMAIN" "${STACK_ROOT}/identity/web" >/dev/null \
    || { echo "  ✗ 生成 web TLS 证书失败（缺 openssl？）" >&2; exit 1; }
  note "web TLS: ${STACK_ROOT}/identity/web（SAN: ${DOMAIN},localhost,127.0.0.1）"
else
  note "⚠ 缺少 sys/scripts/init-web-tls.sh：web 容器会因缺证书起不来"
fi

note "done"
