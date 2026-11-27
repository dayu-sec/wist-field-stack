#!/usr/bin/env python3
"""示例 1：给令牌做一次「体检」——它对应谁、何时过期、能看哪些客户。

**这不是登录会话。** `POST /api/login` 只把令牌解成身份（subject / roles / audience /
expires_at），不设 cookie、不返回 session id；后续每个 `/api/*` 请求仍然各自带
`Authorization: Bearer wcr_…`，由 BFF 独立验一次。`GET /api/session` 虽然叫 session，
也是无状态的：返回的是**当前这把令牌**的 subject / roles / tenants。

所以这个脚本是可选的：跳过它，直接带同一个令牌跑 `02_health.py` 也没问题。
它存在的意义是先把 401/403 的原因（令牌错 / 过期 / audience 不对 / 角色不够）单独暴露出来。

本地栈可以零参数跑：

    python3 examples/field-api/01_token_identity.py

它会自动：
  - 用默认入口 `https://127.0.0.1:8088`；
  - 信任本栈 `identity/web/public/web-ca.crt.pem`（不用再传 `--insecure`）；
  - 没有令牌时，从可发现的本地 cred 领一把 5 分钟 dev 令牌
    （`WIST_FIELD_NO_DEV_TOKEN=1` 关闭；`WIST_CRED_SECRET_FILE` / `WIST_CRED_SITE` 指定 cred）。

跨环境 / 生产显式给入口和令牌：

    export WIST_FIELD_URL=https://<站点入口>:<端口>
    export WIST_FIELD_TOKEN=wcr_xxx
    python3 examples/field-api/01_token_identity.py

多客户站点再加 `--tenant c-001`（或 `WIST_FIELD_TENANT`）。
`auth.mode = ingress` 的部署没有令牌，用 `--operator 张三`。
"""

import argparse
import datetime
import json
import sys

from field_client import (
    FieldApiError,
    add_common_args,
    client_from_args,
    explain,
    require_auth,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="wist-field：令牌体检与客户选择")
    add_common_args(parser)
    args = parser.parse_args()

    client = client_from_args(args)
    if not require_auth(client):
        return 2

    try:
        # 不调 `/healthz`：脚本走的是栈的 web 入口，这个路径由 nginx / 前端接管，
        # 返回的是页面而不是 BFF JSON。BFF 对外的探活是 `/api/health`（需要令牌）。

        # `POST /api/login` 只回答“这串令牌是谁”，不是后续请求的前置步骤；
        # 它不换 session / cookie，后面的每个请求仍然各带一次 Bearer。
        if client.token:
            who = client.login()
            print("subject :", who.get("subject"))
            print("roles   :", who.get("roles"))
            print("audience:", who.get("audience"))
            expires_at = who.get("expires_at")
            if isinstance(expires_at, (int, float)):
                # login 契约里是 Unix 秒，不是毫秒。
                local = datetime.datetime.fromtimestamp(expires_at).astimezone()
                print("expires :", local.isoformat())
        else:
            print("auth    : ingress（入口已认证，操作员写在 x-field-operator）")

        # `GET /api/session` 只是“当前令牌能看哪些客户”，不是登录会话；
        # BFF 故意不给默认客户。
        session = client.session()
        print("session :", json.dumps(session, ensure_ascii=False))

        tenant = client.resolve_tenant()
        if tenant:
            print("tenant  :", tenant)
        else:
            print("tenant  : (单客户站点，未配置客户清单，由 BFF 兜底)")

        # 拿这个 client 继续调别的接口即可（它已经把 Bearer 和 ?tenant= 带上了）。
        health = client.health()
        print("bff     :", "version=%s stack=%s" % (
            health.get("version"), health.get("stack_version")
        ))
        return 0

    except FieldApiError as err:
        print(explain(err), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
