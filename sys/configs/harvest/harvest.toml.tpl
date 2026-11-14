# wist-harvest（云资产采集）服务配置**模板**（handlebars，由 `gx run localize` 渲染）。
# src: `sys/configs/harvest/harvest.toml.tpl`
# dst: `configs/harvest/harvest.toml`（compose 只读挂到 `/etc/wist-harvest/harvest.toml`）
# 渲染值: `configs/harvest/harvest.value.json`（`sys/scripts/init-field-config.sh` 生成）
#
# 与 field-api / evidence 同一套规矩：
#   · **部署值**（数据平面端点）写成占位符 —— 现场在 `values/<系统>/sys_value.yml` 覆盖
#     `HARVEST_SINK_ENDPOINT`，不要改这个文件；
#   · **密钥**不在这一层：数据源里只写「从 `.wist/sec-value.yml` 的哪个键读」。
#
# 本文件里**没有厂商差异**：签名、端点、分页协议、字段归一全在 `harvest-{vendor}` crate 里，
# 这里只放「所有云都一样」的运行参数。
#
# 下面这些数字是**应用契约**（harvest 的缺省值，改之前先看设计说明 §2.1）：
#   page_size          单页 100：腾讯云单页上限就是 100；AWS 走 NextToken 游标，不看它
#   max_frame_bytes    单帧 32MiB：超限即 Aborted（推动下游分片组装，不拆 snap_id）
#   max_response_bytes 单次响应 16MiB
#   concurrency        1 = P0 顺序采集（字段留着，避免下一阶段改配置结构）
#   allow_empty        false：空 ≠ 失败 —— 只有范围完整且云端确实为空才允许发空快照
#   max_resume_age_ms  可续跑 spool 的最大年龄（24h）：超龄就弃旧开新，
#                      否则一个「永久失败」的工作项会让每轮都续跑同一份旧 spool
[service]
# 采集开关（运行时）：`false` = 进程常驻但不调度（healthcheck 只探活）。
# 管理面关掉采集时容器不必销毁；改回 true 后重启即恢复。
enabled = {{harvest_enabled}}
spool_dir = "/var/lib/wist-harvest/spool"
state_dir = "/var/lib/wist-harvest/state"
page_size = 100
max_frame_bytes = 33554432
max_response_bytes = 16777216
request_timeout_ms = 30000
concurrency = 1
allow_empty = false
max_resume_age_ms = 86400000

[retry]
max_attempts = 4
base_delay_ms = 200
max_delay_ms = 5000

[rate]
# 默认限速：云 API 有配额，多站点同日采集时靠它错开，而不是靠调大重试。
default_qps = 5.0
default_burst = 5.0

[sink]
# 数据平面入口：**warp-parse 的 `harvest_1` source**（`framing = "len"`、ndjson）。
#
# 本栈**不跑 wparse**（数据面在网关栈），所以这是现场值：填一个「从 harvest 容器可达的
# host:port」。留空 = 采集不启用（另见 `HARVEST_TENANT_ID`：两个都齐才算启用）。
endpoint = "{{harvest_sink_endpoint}}"
# 明文 TCP：warp-parse 的 tcp_src 只开明文，这条链路只走内网。
# 改成 false 需要 sink 侧的信任锚与客户端证书（ca_file / cert_file / key_file），当前没有对端支持 ——
# 换成 HTTP / MQ 那种**有应答**的 sink 时再一起改这两项。
allow_plaintext = true
connect_timeout_ms = 5000
ack_timeout_ms = 15000
publish_attempts = 3
# 不等应答：warp-parse 的 tcp_src 没有应用层 ACK。等的话每次发布都会超时 →
# 运行永远 Aborted、spool 永不清理（帧其实已经送到了）。
expect_ack = false
