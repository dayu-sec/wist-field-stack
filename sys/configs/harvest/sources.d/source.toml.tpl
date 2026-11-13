# wist-harvest（云资产采集）数据源定义**模板**（handlebars，由 `gx run localize` 渲染）。
# src: `sys/configs/harvest/sources.d/source.toml.tpl`
# dst: `configs/harvest/sources.d/source.toml`（compose 只读挂到 `/etc/wist-harvest/sources.d/`）
# 渲染值: `configs/harvest/harvest.value.json`（与服务配置共用一份）
#
# **为什么文件名固定是 `source.toml`**（而不是 `<source_code>.toml`）：
#   `gx.tpl` 的 dst 是**字面路径**，不按变量取名。让模板与 compose 两边都写死同一个名字，
#   就不会出现「渲染到 A、容器去读 B」这种错位。**身份是文件里的 `source_code`**，
#   文件名不参与任何语义。
#
# 一个云账号一个数据源；多账号 = 多加一个 harvest 服务实例（`sources.d/` 就是为它留的）。
#
# 关闭态（`HARVEST_TENANT_ID` / `HARVEST_SINK_ENDPOINT` 任一为空）渲染成**只有注释**：
# 它是合法 TOML，但不是合法数据源（缺 `source_code`）。于是「绕过 profile 硬起容器」会当场
# `source_config` FAIL，而不是拿一个空租户去云上把某个账号采一遍 —— 那种错是静默且彻底的。
{{#if harvest_enabled}}
source_code = "{{harvest_source_code}}"
# 租户 = 客户 id（与 `configs/cells/cells.json` 的 `cust_id` 同源）；下游按它做作用域隔离。
# 换实现（换厂商 / 换语言）**不能换** source_code，下游按它做资源匹配。
tenant_id = "{{harvest_tenant_id}}"
# 厂商：选择适配器。**必填且必须显式** —— 不写/写错就启动失败，绝不猜
#（猜错 = 拿一个账号的数据按另一家的 API 去采，错得静默且彻底）。
vendor = "{{harvest_vendor}}"
group = "inventory"
env_ref = "{{harvest_env_ref}}"
# 地域范围：`"auto"` = 运行时用 DescribeRegions 解析（只取 AVAILABLE）；
# 或固定列表（站点变量 `HARVEST_REGIONS` 写逗号分隔，脚本转成 TOML 数组字面量）。
regions = {{{harvest_regions_literal}}}
{{#if harvest_cost_enabled}}
# 账单账号（腾讯云 UIN / AWS 账号 id）：账单接口按它记账，与凭据里的 SecretId 没有推导关系，
# 所以必须显式给。留空 = 只采资产，不渲染成本链路。
billing_account = "{{harvest_billing_account}}"
{{/if}}

[assets]
# 能力开关只能**收紧**（关掉某一类 = 不采）。打开一个该云不提供的类型会在启动/计划阶段失败，
# 不会静默跳过。
cloud_host = true
eip = true
vpc = true
subnet = true

[credential]
# 只写「从哪读」，永远不写值：
#   `.wist/sec-value.yml`（0640）是栈里唯一的密钥真值，属组由 `gops sys perms` 对到容器 gid
#   （harvest 以 10001 运行，靠属组读；**不塞进 compose 环境变量**，否则 `docker inspect` 里裸奔）。
# 键名由**厂商**定，脚本按 `HARVEST_VENDOR` 展开（腾讯云 secret_id/secret_key，
# AWS access_key_id/secret_access_key[/session_token]）。
{{#each harvest_credentials}}{{name}} = { file = "/sec/sec-value.yml", field = "{{field}}" }
{{/each}}
{{#if harvest_cost_enabled}}
[cost]
# 账单分片落到 `<state_dir>/cost`，而 state 已挂到宿主 `${HARVEST_RUN_DIR}/state`，
# 所以 wist-cost 直接读宿主上那份 —— 成本**不进数据平面**（O(资源×天×18 个月)，不是资产的一类）。
# 币种由厂商定（腾讯云国内账号 CNY）；AWS 的账单 reader 还没实现，所以这里不会出现 USD。
currency = "{{harvest_cost_currency}}"
{{/if}}
{{#if harvest_has_vendor_options}}
[vendor_options]
# 厂商专属参数：core 不解析，由 `harvest-{vendor}` 用 `deny_unknown_fields` 强类型解析。
# AWS：`partition` 决定域名后缀（aws / aws-cn / aws-us-gov）。
{{{harvest_vendor_options_literal}}}
{{/if}}
{{else}}
# ── 采集未启用（本文件不是可用数据源）────────────────────────────────────
# 原因：`HARVEST_TENANT_ID` 或 `HARVEST_SINK_ENDPOINT` 为空（至少一个）。
#
# 启用步骤（现场值写 `values/<系统>/sys_value.yml`，然后 `gops sys localize`）：
#   1. HARVEST_TENANT_ID     = 客户 id（与 `configs/cells/cells.json` 的 cust_id 一致）
#   2. HARVEST_SINK_ENDPOINT = warp-parse 的 `harvest_1` source，`host:port`，**容器可达**
#   3. COMPOSE_PROFILES      = harvest（compose profile，服务默认不启动）
#   4. HARVEST_VENDOR        = tencent | aws
#   5. 凭据写进 `.wist/sec-value.yml`（腾讯云：SEC_TENCENT_SECRET_ID / SEC_TENCENT_SECRET_KEY），
#      再跑 `gops sys perms --apply` 把属组对到容器 gid（10001）。
{{/if}}
