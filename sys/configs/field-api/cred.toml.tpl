# 数据场的 cred 接入配置（**模板**）—— 由 `gx run localize` 渲染成 `configs/field-api/cred.toml`，
# 盖在 `identity/field-api/cred/cred.toml`（接入命令写的那份）上。
# src: `sys/configs/field-api/cred.toml.tpl`
# 渲染值：`configs/field-api/cred.value.json`（`sys/scripts/init-field-config.sh` 生成）
#
# 部署事实（认证系统名 / 收数主机名 / 端口）写成 handlebars 占位符 —— 现场在 `values/` 覆盖；
# 密钥写 `${SEC_…}` —— 不渲染，由服务从 `.wist/sec-value.yml` 展开。
#
# 三种段，三种归属：
#   [verify]  本服务的决定（认谁、能验什么）
#   [init]    首次注册的授权：setup code 由部署生成（密钥文件），一次性券由 cred 页面签发
#   [publish] 本机在 cred 眼里的收数地址：**部署事实**，由栈按端口映射渲染
#
# [identity] 段故意不写：它由注册产物决定（server.crt / server.key / client-ca.pem 就在
# 本文件同一目录），由 wist-cred-peer 在初始化成功后写入。
#
# 切换存储 / 信任锚靠**变量**，不改本文件：
#   FIELD_API_ADVERTISE_HOST     收数地址的主机名（= 证书 SAN；不填启动就失败）
#   FIELD_API_CRED_URL           cred 注册入口（留空则初始化页上填）
#   FIELD_API_CRED_CA_FILE       入口自签时的信任锚（容器内路径）
#   FIELD_API_CRED_INSECURE_TLS  明确跳过入口证书校验（与 ca_file 互斥）

[verify]
# 认证系统名：凭据的 `audience` 不等于它就拒（401 `audience_mismatch`）。
# 它是**部署事实**（必须与 cred 侧那个 peer 同名），所以走渲染值，站点在 values/ 里设
# `FIELD_API_AUDIENCE`（产品默认 `wist-field-api`）。
audience = "{{field_api_audience}}"
allowed_issuers = ["wist-cred"]
roles = ["read"]
# 授权记录要不要**强制验签**（Ed25519）：mTLS 已经认了 cred 的身份，这一层防的是
# “推送链路里的中间人不改内容”（纵深防御）。
# 公钥在自注册成功后由 cred 写进同目录（issuer-signing.pub）；手动接入时由 join.sh 写。
# 强制开着但公钥不在 → 启动期就报（不静默退化成“不验签”）。
# 字符串形式（`"true"` / `"false"`）与字面 bool 都认；这里用字符串是因为渲染值是文本。
require_signature = "{{field_api_require_cred_signature}}"
issuer_public_key_file = "issuer-signing.pub"

[init]
# 从密钥文件展开（`WIST_FIELD_SEC_FILE` → `.wist/sec-value.yml` 的 field_api_peer_setup_code）。
setup_code = "${SEC_FIELD_API_PEER_SETUP_CODE}"
# cred 的注册入口；留空 = 初始化页上让操作者填。
cred_url = "{{field_api_cred_url}}"
# 信任锚：入口自签时填它的 CA（容器内路径）。留空 = 不配（那就要开 insecure_tls）。
ca_file = "{{field_api_cred_ca_file}}"
insecure_tls = "{{field_api_insecure_tls}}"

[publish]
# cred 往这里推摘要、往这里探活。主机名必须等于证书 SAN（同一个变量渲染）。
endpoint = "https://{{field_api_advertise_host}}:{{credentials_host_port}}/api/v1/internal/credentials"
