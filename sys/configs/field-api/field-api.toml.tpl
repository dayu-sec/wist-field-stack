# field-api 配置**模板**（handlebars，由 `gops sys localize` 的 `gx run localize` 渲染）。
# src: 本文件（`sys/configs/field-api/field-api.toml.tpl`）
# dst: `configs/field-api/field-api.toml`（compose 挂到 /etc/wist-field-api/field-api.toml）
# 渲染值：`configs/field-api/field-api.value.json`（`sys/scripts/init-field-config.sh` 生成）
#
# 两条规矩（与 wist-gateway-stack / wist-cred-stack 同一套）：   · **部署值**（端口、数据面视角的主机名、租户…）写成 handlebars 占位符 —— 现场在
#     `values/<系统>/sys_value.yml` 覆盖，不要改这个文件；
#   · **密钥**写 `${SEC_…}` —— 不渲染、不落盘，由服务启动时从 `.wist/sec-value.yml` 展开。
#
# 浏览器只跟 BFF 说话；到证据服务的租户 / scope / 敏感度只在这里。

[server]
listen_addr = "0.0.0.0:8080"

[auth]
# cred：访问令牌（`wist-cred` 签发，`Authorization: Bearer wcr_…`）由 BFF 用摘要表验。
#       cred 通过 mTLS 把摘要推到本服务的 `credentials.listen_addr`。
# ingress：完全交给入口（VPN / 堡垒机 / 反代）认证并注入 `x-field-operator`，
#       BFF 不验 token —— 只有在入口确实做了认证、且能保证头不被伪造时才选它。
#
# **没有「不校验」这一档。**
mode = "cred"
operator_header = "x-field-operator"

[credentials]
# `cred.toml` 由接入命令写入（identity + verify 两段），**不要手改、也不要抄到这里**：
#   curl -fsSLk 'https://<cred>/enroll/<券>/join.sh' | bash -s -- --dir './identity/field-api/cred'
# 材料随 `sys/` 一起进镜像/卷，相对路径按 cred.toml 所在目录解。
file = "/cred/cred.toml"
# cred 推送摘要的 mTLS 监听（容器内固定；宿主端口由编排决定）。
listen_addr = "0.0.0.0:3103"
# 摘要表（**只存 sha256**）：验证侧私有状态，不进 PG、不备份。
store_path = "/var/lib/wist-field-api/credentials.json"
# 进本服务需要的角色：cred 页面签发时选的角色组合里至少命中一个。
required_roles = ["read"]

# 身份：**这里的 tenant 就是客户 id**（证据服务的租户=客户）。
# 想同时看多个客户需要本服务侧加客户筛选（当前一页一个客户）。
# 端口由渲染值 `evidence_read_port` 给（来自栈变量 `EVIDENCE_READ_PORT`），
# 与证据服务的读监听、compose 健康检查同一个来源。
[evidence]
base_url = "http://evidence:{{evidence_read_port}}"
# 租户就是客户 id（证据服务的租户 = 客户）。每个站点不同，所以走渲染值而不是写死。
tenant = "{{evidence_tenant}}"
scopes = ["evidence:read"]
max_sensitivity = "paths"
timeout_secs = 10

# 资产拓扑：`base_url` 用于 `/api/health` 探活与 `/api/atlas/*` 代理（读 `/healthz` 与 `/api/*`）；
# `sink_url` 是**数据面视角**的写端点，只用于「接入」页展示 / copy。
# 主机名来自栈变量 `ATLAS_INGEST_PUBLIC_HOST`（每个部署实例不同），端口与那条 bind 映射同一个来源。
# 画布已是 field-web 的一个组件，不再有 atlas-web 容器。
[atlas]
base_url = "http://atlas:8080"
# 读接口令牌：atlas 从 0.3.4 起要求 `Authorization: Bearer`。值来自栈变量
# `ATLAS_API_TOKEN`（compose 以 `SEC_ATLAS_API_TOKEN` 传进来）。空 = 对面没开鉴权。
auth_token = "${SEC_ATLAS_API_TOKEN}"
sink_url = "http://{{atlas_ingest_public_host}}:{{atlas_ingest_host_port}}"

# 运行指标：VictoriaMetrics。
# `base_url` 是 **BFF 视角**（栈内）的查询入口，用于探活与指标页。
# `write_url` 是 **数据面视角**的写入端点，只用于接入页展示 / copy ——
# 不配就不展示运行指标的写入样板（不编造占位地址）。
[metrics]
base_url = "http://metrics:8428"
# 数据面视角的主机名 / 端口：与证据（EVIDENCE_SINK_PUBLIC_HOST）/ atlas
# （ATLAS_INGEST_PUBLIC_HOST）同一粒度 —— 每条通道各一个，虽然常常同值。
write_url = "http://{{metrics_sink_public_host}}:{{vm_host_port}}"

# 业务层：把「主机集合」归到一个命名的逻辑单元（指标页第 1 层，用来算投入产出比）。
#
# 业务单元 **不是** `app`：`app` 表达用途，业务单元表达归属；一个业务可以跨多台主机。
# 归属关系只在这里配，**不下沉到数据面** —— 改归属不用重启 agentd / wparse。
# 一台主机只能属于一个业务（跨业务共用会让投入重复计账，启动时直接报错）；
# 不在任何业务里的主机会在指标页单列为「未归类」。
#
# 主机 id 就是指标里的 `agent` label，在指标页「4 · 计算资源层」可以看到。
#
# [[business.units]]
# id = "billing"
# name = "计费服务"
# agents = ["agent-host-a55a338d7723"]

# 展示在「数据面接入」页的写端点（**数据面视角**的地址，不是容器内地址）。
# 主机名 / 端口都是栈变量：现场在 `values/<系统>/sys_value.yml` 覆盖
# `EVIDENCE_SINK_PUBLIC_HOST` / `EVIDENCE_SINK_HOST_PORT`，不要改本文件。
[integration]
sink_url = "http://{{evidence_sink_public_host}}:{{evidence_sink_host_port}}"
# 上面那个地址 BFF 到不了，所以写端点的**探活**另给一条 BFF 视角的地址：
# 证据写监听在容器内 8080，与读监听（8443）分开。
sink_health_url = "http://evidence:8080/healthz"
