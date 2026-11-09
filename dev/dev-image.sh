#!/usr/bin/env bash
# 把组件源码交叉编译成 Linux 二进制，打成「本地开发镜像」，并挂到本栈上。
#
#   ./dev/dev-image.sh --svc api   --api   <wist-field-api 仓>    [选项]
#   ./dev/dev-image.sh --svc evidence --evidence <wist-evidence 仓> [选项]
#   ./dev/dev-image.sh --svc atlas --atlas <wist-atlas 仓>        [选项]
#
# 选项：
#   --svc <api|evidence|atlas>  要构建哪个（默认 api）
#   --api <dir>        wist-field-api 源码仓（--svc api）
#   --evidence <dir>   wist-evidence 源码仓（--svc evidence）
#   --atlas <dir>      wist-atlas 源码仓（--svc atlas）
#   --stack <dir>      站点栈目录（默认：本仓根目录）
#   --tag <tag>        镜像 tag（默认 v<version.txt>-local）
#   --release          用 release 档编译（默认 debug：更快，测试够用）
#   --no-recreate      只构建镜像，不动容器
#   -h | --help
#
# 为什么这么绕：macOS 二进制跑不进 Linux 容器（Mach-O ≠ ELF），而容器里全量 cargo build
# 要 20+ 分钟且每次改源码都重来。zig 交叉编译在宿主原生跑，增量 5–15 秒。
#
# 为什么 tag 一定是 vX.Y.Z-local：这个镜像不在任何 registry 里。带 -local 后缀，
# 既不会让 docker compose pull 误以为它存在，也不会被误当成某次发布产物。
#
# 三个组件的打包方式不同（都只换二进制，运行时形状保持发布态）：
#   field-api / evidence  用仓库自带的 docker/Dockerfile（base = ubuntu:24.04）；
#   atlas      仓库 Dockerfile 会在容器里编译（慢），本地改成「从已发布镜像派生」：
#              FROM <ATLAS_REGISTRY>/wist-atlas:<当前 tag> + 只覆盖 /usr/local/bin/wist-atlas。
set -euo pipefail

die() {
  echo "错误：$*" >&2
  exit 1
}
note() { echo "  $*"; }

SVC="api"
FIELD_API_SRC=""
EVIDENCE_SRC=""
ATLAS_SRC=""
WEB_SRC=""
STACK=""
TAG=""
PROFILE="debug"
RECREATE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --svc) SVC="${2:-}"; shift 2 ;;
    --api) FIELD_API_SRC="${2:-}"; SVC="api"; shift 2 ;;
    --evidence) EVIDENCE_SRC="${2:-}"; SVC="evidence"; shift 2 ;;
    --atlas) ATLAS_SRC="${2:-}"; SVC="atlas"; shift 2 ;;
    --web) WEB_SRC="${2:-}"; SVC="web"; shift 2 ;;
    --stack) STACK="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --release) PROFILE="release"; shift ;;
    --no-recreate) RECREATE=0; shift ;;
    -h | --help) sed -n '2,28p' "$0"; exit 0 ;;
    *) die "未知参数：$1（--help 看用法）" ;;
  esac
done

case "${SVC}" in
  api)
    SRC="${FIELD_API_SRC}"
    [[ -n "${SRC}" ]] || die "缺少 --api <wist-field-api 仓>"
    [[ -f "${SRC}/Cargo.toml" ]] || die "--api 不是 wist-field-api 仓：${SRC}"
    CARGO_ARGS=()
    BIN="wist-field-api"
    IMAGE_NAME="wist-field-api"
    REGISTRY_VAR="FIELD_REGISTRY"
    TAG_VAR="FIELD_API_IMAGE_TAG"
    COMPOSE_SERVICE="field-api"
    CONTAINER="wist-field-stack-field-api"
    ;;
  evidence)
    SRC="${EVIDENCE_SRC}"
    [[ -n "${SRC}" ]] || die "缺少 --evidence <wist-evidence 仓>"
    [[ -f "${SRC}/Cargo.toml" ]] || die "--evidence 不是 wist-evidence 仓：${SRC}"
    CARGO_ARGS=()
    BIN="wist-evidence"
    IMAGE_NAME="wist-evidence"
    REGISTRY_VAR="FIELD_REGISTRY"
    TAG_VAR="EVIDENCE_IMAGE_TAG"
    COMPOSE_SERVICE="evidence"
    CONTAINER="wist-field-stack-evidence"
    ;;
  web)
    SRC="${WEB_SRC}"
    [[ -n "${SRC}" ]] || die "缺少 --web <wist-field-web 仓>"
    [[ -f "${SRC}/package.json" ]] || die "--web 不是 wist-field-web 仓：${SRC}"
    [[ -d "${SRC}/node_modules" ]] || die "还没装依赖：cd ${SRC} && npm install"
    CARGO_ARGS=()
    BIN=""
    IMAGE_NAME="wist-field-web"
    REGISTRY_VAR="FIELD_REGISTRY"
    TAG_VAR="FIELD_WEB_IMAGE_TAG"
    COMPOSE_SERVICE="web"
    CONTAINER="wist-field-stack-web"
    ;;
  atlas)
    SRC="${ATLAS_SRC}"
    [[ -n "${SRC}" ]] || die "缺少 --atlas <wist-atlas 仓>"
    [[ -f "${SRC}/Cargo.toml" ]] || die "--atlas 不是 wist-atlas 仓：${SRC}"
    CARGO_ARGS=(-p atlas-app)
    BIN="wist-atlas"
    IMAGE_NAME="wist-atlas"
    REGISTRY_VAR="ATLAS_REGISTRY"
    TAG_VAR="ATLAS_IMAGE_TAG"
    COMPOSE_SERVICE="atlas"
    CONTAINER="wist-field-stack-atlas"
    ;;
  *)
    die "--svc 只能是 api|evidence|atlas|web，收到 ${SVC}" ;;
esac

# 后面要 cd 进栈目录，先把两个路径都换成绝对路径（否则相对路径会拼成 xx/xx/…）。
SRC="$(cd "${SRC}" && pwd)"
if [[ -z "${STACK}" ]]; then
  STACK="$(cd "$(dirname "$0")/.." && pwd)"
fi
[[ -d "${STACK}" ]] || die "--stack 不是目录：${STACK}"
[[ -f "${STACK}/.env" && -f "${STACK}/sys/docker-compose.yml" ]] ||
  die "--stack 不像 gops 栈目录（缺 .env 或 sys/docker-compose.yml）：${STACK}"
STACK="$(cd "${STACK}" && pwd)"

command -v docker >/dev/null 2>&1 || die "缺少 docker"

if [[ "${SVC}" != "web" ]]; then
  command -v zig >/dev/null 2>&1 || die "缺少 zig：brew install zig"
  command -v cargo-zigbuild >/dev/null 2>&1 ||
    die "缺少 cargo-zigbuild：cargo install cargo-zigbuild --locked"
  case "$(uname -m)" in
    arm64 | aarch64) RUST_TARGET="aarch64-unknown-linux-gnu"; DOCKER_ARCH="arm64" ;;
    x86_64) RUST_TARGET="x86_64-unknown-linux-gnu"; DOCKER_ARCH="amd64" ;;
    *) die "不支持的宿主架构：$(uname -m)" ;;
  esac
  rustup target list --installed 2>/dev/null | grep -qx "${RUST_TARGET}" ||
    die "未安装 Rust 目标：rustup target add ${RUST_TARGET}"
fi

VERSION="$(tr -d '[:space:]' <"${SRC}/version.txt" 2>/dev/null || echo dev)"
[[ -n "${TAG}" ]] || TAG="v${VERSION}-local"

env_value() { sed -n "s/^$1=//p" "${STACK}/.env" | head -1 | tr -d '"'; }
REGISTRY="$(env_value "${REGISTRY_VAR}")"
[[ -n "${REGISTRY}" ]] || REGISTRY="ghcr.io/dayu-sec"
CURRENT_TAG="$(env_value "${TAG_VAR}")"
IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"

echo "== 构建（${SVC}）"
BUILD_ARGS=()
[[ "${PROFILE}" == "release" ]] && BUILD_ARGS+=(--release)
if [[ "${SVC}" == "web" ]]; then
  (cd "${SRC}" && npm run build >/dev/null)
  note "ok（dist/）"
else
  (cd "${SRC}" && cargo zigbuild --target "${RUST_TARGET}" \
    ${CARGO_ARGS[@]+"${CARGO_ARGS[@]}"} ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"})
  BIN_PATH="${SRC}/target/${RUST_TARGET}/${PROFILE}/${BIN}"
  [[ -f "${BIN_PATH}" ]] || die "没找到产物：${BIN_PATH}"
  file "${BIN_PATH}" | grep -q ELF || die "产物不是 ELF（交叉编译没生效？）：$(file -b "${BIN_PATH}")"
  note "ok"
fi

echo "== 打包镜像（${IMAGE}）"
CTX="$(mktemp -d)"
trap 'rm -rf "${CTX}"' EXIT
if [[ "${SVC}" != "web" ]]; then
  mkdir -p "${CTX}/${DOCKER_ARCH}"
  cp "${BIN_PATH}" "${CTX}/${DOCKER_ARCH}/${BIN}"
fi

if [[ "${SVC}" == "atlas" ]]; then
  # 派生而不是重建：base 是**已发布镜像**，基底 / uid / entrypoint / 另一个二进制都原样保留。
  #
  # 必须用发布 tag 当 base，不能用 `.env` 里当前生效的 tag —— 它可能已经是上一份 `-local`，
  # 那样每改一次代码就在上一份镜像上再叠一层（实测 274MB → 524MB）。
  PUBLISHED_TAG="$(awk -v key="${TAG_VAR}" '
    index($0, "- name: " key) { want = 1; next }
    want && $1 == "value:" { print $2; exit }
  ' "${STACK}/sys/setting/vars.yml" 2>/dev/null | tr -d '\"')"
  case "${PUBLISHED_TAG}" in
    "" | *-local) die "找不到已发布的 ${IMAGE_NAME} tag：检查 ${STACK}/sys/setting/vars.yml 的 ${TAG_VAR}" ;;
  esac
  BASE_IMAGE="${REGISTRY}/${IMAGE_NAME}:${PUBLISHED_TAG}"
  docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1 ||
    die "本地没有 ${BASE_IMAGE}：先 docker pull 它（派生镜像要求 base 在本地）"
  cat >"${CTX}/Dockerfile" <<EOF
# 本地开发镜像：从**已发布**镜像派生，只覆盖二进制（运行时形状与发布态一致）。
FROM ${BASE_IMAGE}
COPY ${DOCKER_ARCH}/${BIN} /usr/local/bin/${BIN}
EOF
  docker build -q -f "${CTX}/Dockerfile" -t "${IMAGE}" "${CTX}" >/dev/null
elif [[ "${SVC}" == "web" ]]; then
  # 静态前端：node 阶段在本机跑（容器里 `npm ci` 又要拉包又慢），
  # 镜像从发布镜像派生，只换 `/usr/share/nginx/html`（nginx.conf / 健康检查原样保留）。
  PUBLISHED_TAG="$(awk -v key="${TAG_VAR}" '
    index($0, "- name: " key) { want = 1; next }
    want && $1 == "value:" { print $2; exit }
  ' "${STACK}/sys/setting/vars.yml" 2>/dev/null | tr -d '\"')"
  case "${PUBLISHED_TAG}" in
    "" | *-local) die "找不到已发布的 ${IMAGE_NAME} tag：检查 ${STACK}/sys/setting/vars.yml 的 ${TAG_VAR}" ;;
  esac
  BASE_IMAGE="${REGISTRY}/${IMAGE_NAME}:${PUBLISHED_TAG}"
  docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1 ||
    die "本地没有 ${BASE_IMAGE}：先 docker pull 它（派生镜像要求 base 在本地）"
  cp -R "${SRC}/dist" "${CTX}/dist"
  cat >"${CTX}/Dockerfile" <<EOF
# 本地开发镜像：从**已发布**镜像派生，只换静态文件（nginx 配置 / 版本目录结构保持一致）。
FROM ${BASE_IMAGE}
COPY dist/ /usr/share/nginx/html/
EOF
  docker build -q -f "${CTX}/Dockerfile" -t "${IMAGE}" "${CTX}" >/dev/null
else
  [[ -f "${SRC}/docker/Dockerfile" ]] || die "缺少 ${SRC}/docker/Dockerfile（运行时形状的唯一来源）"
  docker build -q -f "${SRC}/docker/Dockerfile" \
    --build-arg TARGETARCH="${DOCKER_ARCH}" \
    -t "${IMAGE}" "${CTX}" >/dev/null
fi
note "ok（$(docker image inspect "${IMAGE}" --format '{{.Size}}' 2>/dev/null | awk '{printf "%.0fMB", $1/1024/1024}')）"

if [[ "${RECREATE}" != "1" ]]; then
  echo "完成：${IMAGE}（--no-recreate，容器没动）"
  exit 0
fi

COMPOSE=(-f "${STACK}/sys/docker-compose.yml" --project-directory "${STACK}" --env-file "${STACK}/.env")
echo "== 切站点栈的 ${TAG_VAR} → ${TAG}"
BACKUP="/tmp/$(basename "${STACK}").env.bak.$(date +%Y%m%d%H%M%S)"
cp "${STACK}/.env" "${BACKUP}"
awk -v key="${TAG_VAR}" -v tag="${TAG}" '
  index($0, key "=") == 1 { print key "=" tag; next }
  { print }
' "${BACKUP}" >"${STACK}/.env"
note "ok（原文件备份在 ${BACKUP}）"

echo "== 只重建 ${COMPOSE_SERVICE}（不要跑 gops sys localize：它会按 values/ 覆盖 .env）"
(cd "${STACK}" && docker compose "${COMPOSE[@]}" up -d --force-recreate "${COMPOSE_SERVICE}") >/dev/null
sleep 2
(cd "${STACK}" && docker compose "${COMPOSE[@]}" ps "${COMPOSE_SERVICE}" --format '{{.Image}} {{.Status}}') || true

cat <<EOF

完成。自检：
  docker ps --filter name=${CONTAINER} --format '{{.Image}}\t{{.Status}}'
  ./dev/dev-token.sh --cred-site <cred 栈目录>

回滚：
  cp ${BACKUP} ${STACK}/.env
  cd ${STACK} && docker compose -f sys/docker-compose.yml --project-directory . --env-file .env \\
    up -d --force-recreate ${COMPOSE_SERVICE}

改了源码之后：重跑本脚本即可（增量编译 5–15 秒）。
EOF
