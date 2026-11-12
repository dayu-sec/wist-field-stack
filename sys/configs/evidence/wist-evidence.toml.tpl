# 证据服务（wist-evidence）配置**模板**（handlebars，由 `gx run localize` 渲染）。
# src: `sys/configs/evidence/wist-evidence.toml.tpl`
# dst: `configs/evidence/wist-evidence.toml`（compose 挂到 /etc/wist-evidence/wist-evidence.toml）
# 渲染值：`configs/evidence/wist-evidence.value.json`（`sys/scripts/init-field-config.sh` 生成）
#
# `${SEC_...}` 的真值在 `.wist/sec-value.yml`（0640），不写在这里、也不渲染。

# ── 写面：数据面直投（明文，只在内网）─────────────────────────────────────
[sink]
listen_addr = "0.0.0.0:8080"
max_body_bytes = 4194304
# P0 只开调查报告；`diagnose_report` 等加进这个列表即可。
allowed_kinds = ["investigation_report"]

# 三字段形状（`cust_id` / `cmd_id` / `content`）的默认口径。
# **租户就是客户**：`cust_id` 直接当分区键（对象键第一段 + 索引租户列）。
default_kind = "investigation_report"
default_schema = "wist.evidence/v1"
default_sensitivity = "paths"

# 认证：写入端点不校验（内网可信）；P1 换成 HTTPS 双向认证。

# ── 读面：field-api（BFF）调用（P0 明网 + 身份头；mTLS 在 P1）─────────────────
# 端口由渲染值 `evidence_read_port` 给（栈变量 `EVIDENCE_READ_PORT`），
# 与 field-api 的 `[evidence].base_url`、compose 健康检查同一个来源。
[read]
listen_addr = "0.0.0.0:{{evidence_read_port}}"

# ── 写探针：每 5 分钟给**每个客户**各投一条真证据，验证「对象 + 索引」都能写。──
# 探针产物 `subject_id = "_probe"`（客户 id 用该 cell 自己的，否则会被当成未登记客户
# 直接 400）；超过 `retention_hours` 的每小时扫一次删掉。
# 也要看结果：证据服务的 `/healthz` 会多一个 `probe` 块（数据场「接口可用性」页读它）。
[probe]
enabled = true
interval_secs = 300
retention_hours = 24
# 可选：覆盖探针要打的写端点（默认由 sink 监听地址推 127.0.0.1:<port>）
# url = "http://127.0.0.1:8080/internal/evidence"

# ── 索引 / 对象：**按客户分**，没有全局默认后端 ────────────────
#
# 客户清单的真相是 `configs/cells/cells.json`（`sys/scripts/add-customer.sh` 维护），
# 由 `init-field-config.sh` 转成渲染值 `evidence_cells`，下面按客户展开成 `[[storage.cell]]`。
#
# **一个客户都没有就起不来**（0.3.0 去掉了默认后端）：默认库养出来的是「数据落错库」的
# 可能，而现场从来没有客户真用过那个库。单客户站点也要登记一条 cell。
#
# 每个 cell 必须自带 index 与 objects（不继承 default）：静默继承会把两个客户写进同一个库。
# 对象存储两种模式（与以前顶层 `[objects]` 同一口径，只是现在按客户给）：
#   file：本地目录，重启不丢、能直接看文件；**不支持预签名**（BFF 走代理读正文）。
#   s3  ：生产用（腾讯 COS / MinIO），支持 60s 短签名 URL。
#         把下面这四行换进 `[storage.cell.objects]`，并删掉 `dir`：
#           kind = "s3"
#           endpoint = "${SEC_COS_ENDPOINT}"
#           region = "${SEC_COS_REGION}"
#           access_key = "${SEC_COS_SECRET_ID}"
#           secret_key = "${SEC_COS_SECRET_KEY}"
{{#each evidence_cells}}

[[storage.cell]]
cust_id = "{{cust_id}}"

[storage.cell.index]
kind = "postgres"
database_url = "{{database_url}}"

[storage.cell.objects]
kind = "file"
dir = "{{objects_dir}}"
{{/each}}
