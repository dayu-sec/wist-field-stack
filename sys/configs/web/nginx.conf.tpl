# 数据场前端（field-web）的站点配置**模板**（handlebars，由 `gx run localize` 渲染）。
# src: `sys/configs/web/nginx.conf.tpl`
# dst: `configs/web/nginx.conf`（compose 挂到 /etc/nginx/conf.d/default.conf）
#
# 为什么要模板（而不是直接推一个 nginx.conf）：这份文件跟进**代码版本**。
# 0.3.0 之前它是 `init-stack.sh` 从种子一次性拷的，升级后现场还是旧文件——
# 典型症状：新版加了 `location /__init`，现场却没有，初始化页直接掉到 SPA。
#
# 这份模板里**没有**站点相关的量（整份文件没有一个占位符）：`server_name _` 是有意的 ——
# 入口只有一张证书（SAN 同时含域名 / localhost / 127.0.0.1）、只有一个 server，
# 写成固定名字反而会让「用 IP 访问」落到另一个默认 server 上。
#
# 证书目录 `identity/web` 挂到 `/certs`；证书由 `sys/scripts/init-web-tls.sh <域名>` 生成
# （两级：web CA + 叶），把 `identity/web/public/web-ca.crt.pem` 导入浏览器信任库一次即可免提示。

# ── 80：只留健康检查（健康检查不走证书，避免证书过期把容器拖成 unhealthy）──
# 注意：本端口**不发布到宿主**；对外只有 443。这里不留跳转 ——
# 把 80 跳到 https 会把错误的端口（80）带进 URL。
server {
    listen 80;
    server_name _;

    location = /healthz {
        access_log off;
        add_header Content-Type text/plain;
        return 200 'ok';
    }

    location / {
        return 404;
    }
}

# ── 443：真正的入口 ──────────────────────────────────────────────────────────
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /certs/public/web-tls.crt.pem;
    ssl_certificate_key /certs/private/web-tls.key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    root /usr/share/nginx/html;
    index index.html;

    # 容器重建后 IP 会变。`proxy_pass http://field-api:8080` 这种写法只在**启动时**解析一次，
    # 上游一重建，这里就会拿着旧 IP 回 404/502（症状：页面能开、所有 /api 挂掉）。
    # 用变量 + resolver 让 nginx 按 TTL 重新解析（Docker 内嵌 DNS：127.0.0.11）。
    resolver 127.0.0.11 valid=10s ipv6=off;

    # 凭据 bearer 不进日志：默认 access_log 只记请求行，不记 Authorization 头；
    # 这里显式声明一次，避免以后有人加 `log_format` 时把整头打进去。
    access_log /var/log/nginx/access.log;

    # BFF：浏览器只跟本容器说话。
    #
    # 身份（VPN/堡垒机 + mTLS）由**入口**终结，注入到请求头里；
    # 本容器不持有证据服务的客户端证书，也不直接连证据服务。
    location /api {
        set $field_api_upstream field-api:8080;
        proxy_pass http://$field_api_upstream;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Authorization $http_authorization;
        proxy_read_timeout 120s;
    }

    # 自注册（初始化页）：未初始化时只这一条能用，初始化后它自己回 409。
    # 不经过 `/api`（那里会被 503 门拦下），也不带任何身份——
    # 它的门是 setup code（部署生成）+ 一次性券。
    location /__init {
        set $field_api_init_upstream field-api:8080;
        proxy_pass http://$field_api_init_upstream;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
    }

    # 资产拓扑画布已组件化进 field-web（`@dayu-sec/wist-atlas-graph`），数据走
    # `/api/atlas/*`（上面的 BFF 位置）—— 已经没有 `/atlas/` 与 atlas-web 容器。

    # SPA 路由回退。图标与入口 HTML 不缓存（换版本后要能立刻拿到新 bundle）。
    location ~* ^/(favicon\.(svg|ico)|apple-touch-icon\.png)$ {
        add_header Cache-Control "no-cache, max-age=0, must-revalidate";
        try_files $uri =404;
    }

    location = /index.html {
        add_header Cache-Control "no-cache, max-age=0, must-revalidate";
    }

    location = / {
        add_header Cache-Control "no-cache, max-age=0, must-revalidate";
        try_files /index.html =404;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
