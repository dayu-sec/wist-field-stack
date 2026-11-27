#!/usr/bin/env python3
"""wist-field-api（计算区 BFF）的最小 Python 客户端。

只依赖标准库，Python 3.8+。示例脚本共用的就是这一个文件。

约定（与 BFF 的契约一致）：

- 所有 `/api/*` 都带 `Authorization: Bearer wcr_…`；
- 多客户站点必须显式选客户（`?tenant=`），单客户站点不传；
- 失败响应统一是 `{"error": {"code", "message"}}`；
- `/healthz` 不需要令牌，只回客户清单与 auth 模式。

环境变量：

    WIST_FIELD_URL        BFF 入口，默认 https://127.0.0.1:8088（本栈 web 入口）
    WIST_FIELD_TOKEN      访问令牌（wcr_…）
    WIST_FIELD_TENANT     客户 id（多客户站点必填）
    WIST_FIELD_OPERATOR   ingress 模式下入口写入的操作员（无令牌时用）
    WIST_FIELD_INSECURE   https 自签入口时设为 1（仅开发态）
    WIST_FIELD_TIMEOUT    超时秒数，默认 15

注意：容器里的 BFF 监听 8080，但栈**只发布 web 入口**（宿主 8443/8088 → 容器 443，
反向代理 `/api` 到 BFF）。所以脚本填的是站点入口地址，不是 field-api 的 8080。
"""

from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, Iterator, NoReturn, Optional, Tuple

DEFAULT_URL = "https://127.0.0.1:8088"


class FieldApiError(RuntimeError):
    """BFF（或它代理的上游）返回的错误。"""

    def __init__(self, status: int, code: str, message: str, body: bytes = b""):
        super().__init__("%s %s: %s" % (status, code, message))
        self.status = status
        self.code = code
        self.message = message
        self.body = body


# 示例目录在 <stack>/examples/field-api，栈根就是再上两级。
STACK_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def _is_local_url(url: str) -> bool:
    return urllib.parse.urlparse(url).hostname in ("127.0.0.1", "localhost", "::1")


def _find_local_ca(base_url: str) -> Optional[str]:
    """本地入口的自签 CA；只对 localhost 自动启用，生产不做隐式信任。"""
    explicit = os.environ.get("WIST_FIELD_CA_FILE")
    if explicit:
        return explicit if os.path.isfile(explicit) else None
    if not _is_local_url(base_url):
        return None
    candidate = os.path.join(STACK_ROOT, "identity", "web", "public", "web-ca.crt.pem")
    return candidate if os.path.isfile(candidate) else None


def _cred_site_candidates() -> Iterator[str]:
    seen = set()
    for value in (
        os.environ.get("WIST_CRED_SITE"),
        os.path.join(STACK_ROOT, "..", "..", "local-work", "cred-local", "wist-cred-stack"),
        os.path.join(STACK_ROOT, "..", "local-work", "cred-local", "wist-cred-stack"),
        os.path.join(STACK_ROOT, "..", "..", "cred-local", "wist-cred-stack"),
    ):
        if not value:
            continue
        path = os.path.abspath(value)
        if path not in seen:
            seen.add(path)
            yield path


def _find_cred_secret() -> Optional[str]:
    explicit = os.environ.get("WIST_CRED_SECRET_FILE")
    if explicit:
        return explicit if os.path.isfile(explicit) else None
    for site in _cred_site_candidates():
        path = os.path.join(site, ".wist", "sec-value.yml")
        if os.path.isfile(path):
            return path
    return None


def _cred_url(secret_file: str) -> str:
    explicit = os.environ.get("WIST_CRED_URL")
    if explicit:
        return explicit.rstrip("/")
    site = os.path.dirname(os.path.dirname(secret_file))
    port = "4444"
    try:
        with open(os.path.join(site, ".env"), "r", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("WEB_HOST_PORT="):
                    value = line.split("=", 1)[1].strip().strip('"').strip("'")
                    if value:
                        port = value
                    break
    except OSError:
        pass
    return "https://127.0.0.1:%s" % port


def _read_cred_password(secret_file: str) -> Optional[str]:
    with open(secret_file, "r", encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("cred_web_password:"):
                value = line.split(":", 1)[1].strip().strip('"').strip("'")
                if value:
                    return value
    return None


def _field_audience() -> str:
    value = os.environ.get("WIST_FIELD_AUDIENCE")
    if value and value.strip():
        return value.strip()
    try:
        with open(os.path.join(STACK_ROOT, ".env"), "r", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("FIELD_API_AUDIENCE="):
                    value = line.split("=", 1)[1].strip().strip('"').strip("'")
                    if value:
                        return value
    except OSError:
        pass
    try:
        with open(os.path.join(STACK_ROOT, "configs", "field-api", "cred.toml"),
                  "r", encoding="utf-8") as handle:
            for line in handle:
                stripped = line.strip()
                if stripped.startswith("audience") and "=" in stripped:
                    value = stripped.split("=", 1)[1].strip().strip('"').strip("'")
                    if value:
                        return value
    except OSError:
        pass
    return "wist-field-api"


def mint_dev_token(timeout: float = 10.0) -> Tuple[str, str]:
    """从本地 cred 领一把 5 分钟令牌（只用于本地开发；不打印令牌）。"""
    secret = _find_cred_secret()
    if not secret:
        raise FieldApiError(
            0, "dev_token_unavailable",
            "没找到本地 cred 密钥：设置 WIST_CRED_SECRET_FILE 或 WIST_CRED_SITE",
        )
    password = _read_cred_password(secret)
    if not password:
        raise FieldApiError(0, "dev_token_unavailable", "%s 里没有 cred_web_password" % secret)
    audience = _field_audience()
    body = json.dumps({
        "audience": audience,
        "subject": "examples-field-api",
        "purpose": "examples/field-api 本地示例",
        "roles": ["read"],
        "ttl_seconds": 300,
    }).encode("utf-8")
    request = urllib.request.Request(
        _cred_url(secret) + "/api/v1/credentials",
        data=body,
        headers={
            "Authorization": "Bearer " + password,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        raise _error_from_body(err.code, err.read()) from None
    except urllib.error.URLError as err:
        raise FieldApiError(0, "cred_unreachable", str(err.reason)) from None
    token = payload.get("token")
    if not token:
        raise FieldApiError(0, "dev_token_unavailable", "cred 响应里没有 token")
    return token, audience


def _should_auto_mint(base_url: str) -> bool:
    if os.environ.get("WIST_FIELD_NO_DEV_TOKEN", "").lower() in ("1", "true", "yes"):
        return False
    return _is_local_url(base_url)


class FieldClient:
    def __init__(
        self,
        base_url: Optional[str] = None,
        token: Optional[str] = None,
        tenant: Optional[str] = None,
        operator: Optional[str] = None,
        timeout: Optional[float] = None,
        insecure: Optional[bool] = None,
    ):
        self.base_url = (base_url or os.environ.get("WIST_FIELD_URL") or DEFAULT_URL).rstrip("/")
        self.token = token if token is not None else os.environ.get("WIST_FIELD_TOKEN", "")
        self.tenant = tenant if tenant is not None else (os.environ.get("WIST_FIELD_TENANT") or None)
        self.operator = (
            operator if operator is not None else (os.environ.get("WIST_FIELD_OPERATOR") or None)
        )
        if timeout is None:
            timeout = float(os.environ.get("WIST_FIELD_TIMEOUT", "15"))
        self.timeout = timeout
        if insecure is None:
            insecure = os.environ.get("WIST_FIELD_INSECURE", "").lower() not in (
                "",
                "0",
                "false",
                "no",
            )
        self._ssl_context: Optional[ssl.SSLContext] = None
        if self.base_url.startswith("https://"):
            self._ssl_context = ssl.create_default_context()
            if insecure:
                # 只给自签的开发入口用；生产入口应当有可信证书。
                self._ssl_context.check_hostname = False
                self._ssl_context.verify_mode = ssl.CERT_NONE
            else:
                ca_file = _find_local_ca(self.base_url)
                if ca_file:
                    try:
                        self._ssl_context.load_verify_locations(cafile=ca_file)
                    except (OSError, ssl.SSLError):
                        pass

    # ------------------------------------------------------------------ HTTP

    def _headers(self, has_body: bool) -> Dict[str, str]:
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        if self.operator:
            headers["x-field-operator"] = self.operator
        if has_body:
            headers["Content-Type"] = "application/json"
        return headers

    def _url(
        self,
        path: str,
        query: Optional[Dict[str, Any]] = None,
        add_tenant: bool = True,
    ) -> str:
        params: Dict[str, Any] = {}
        for key, value in (query or {}).items():
            if value is None:
                continue
            if isinstance(value, (list, tuple)):
                params[key] = [str(item) for item in value]
            else:
                params[key] = str(value)
        if add_tenant and self.tenant and "tenant" not in params:
            params["tenant"] = self.tenant
        url = self.base_url + path
        if params:
            url = url + "?" + urllib.parse.urlencode(params, doseq=True)
        return url

    def request(
        self,
        method: str,
        path: str,
        query: Optional[Dict[str, Any]] = None,
        body: Optional[Any] = None,
        raw: bool = False,
        add_tenant: bool = True,
    ) -> Any:
        """发一个请求。

        `raw=True` 时返回 `(status, headers, body_bytes)`，用于读证据正文；
        否则按 JSON 解析（空响应返回 None）。
        """
        data = None
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(
            self._url(path, query, add_tenant=add_tenant),
            data=data,
            headers=self._headers(has_body=data is not None),
            method=method,
        )
        try:
            response = urllib.request.urlopen(
                request, timeout=self.timeout, context=self._ssl_context
            )
        except urllib.error.HTTPError as err:
            payload = err.read()
            raise _error_from_body(err.code, payload) from None
        except urllib.error.URLError as err:
            raise FieldApiError(0, "network_error", str(err.reason)) from None
        except ssl.SSLError as err:
            raise FieldApiError(0, "tls_error", str(err)) from None

        with response:
            payload = response.read()
            if raw:
                return response.status, dict(response.headers.items()), payload
            if not payload:
                return None
            try:
                return json.loads(payload.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                return payload.decode("utf-8", "replace")

    # --------------------------------------------------------------- 身份面

    def login(self, token: Optional[str] = None) -> Dict[str, Any]:
        """`POST /api/login`：确认令牌是谁。返回 subject / roles / audience / expires_at。

        **这不是建立会话**：响应里没有 session id / cookie，后续请求仍然各自带
        `Authorization: Bearer`。它只适合做一次“令牌体检”（audience 对不对、过期没）。

        `expires_at` 是 Unix 秒。没有令牌时抛 `ValueError`；令牌无效 / 过期 / 角色不够时
        抛 `FieldApiError`（401 / 403）。
        """
        value = token or self.token
        if not value:
            raise ValueError("login 需要令牌：传参数或设置 WIST_FIELD_TOKEN")
        if not self.token:
            # 方便“只拿参数登录、后续请求复用”的用法。
            self.token = value
        return self.request(
            "POST", "/api/login", body={"token": value}, add_tenant=False
        )

    def session(self) -> Dict[str, Any]:
        """`GET /api/session`：当前令牌的 subject / roles / 可选客户。

        接口名字叫 session，但它**不是登录会话**：没有 cookie / 服务端状态，
        每次请求都由 BFF 独立验一遍 Bearer。
        """
        return self.request("GET", "/api/session")

    def resolve_tenant(self, preferred: Optional[str] = None) -> Optional[str]:
        """按 `/api/session` 选客户，并把结果记到 `self.tenant`。

        - 显式传了客户：校验它在可选集合里；
        - 单客户站点：自动选中唯一一个；
        - 多客户站点且没传：报错（BFF 故意不给默认客户）。
        """
        tenants = self.session().get("tenants") or []
        wanted = preferred or self.tenant
        if wanted:
            if tenants and wanted not in tenants:
                raise FieldApiError(
                    403, "tenant_not_allowed", "客户 %s 不在可选集合 %s 里" % (wanted, tenants)
                )
            self.tenant = wanted
            return wanted
        if len(tenants) == 1:
            self.tenant = tenants[0]
            return self.tenant
        if len(tenants) > 1:
            raise FieldApiError(
                400,
                "tenant_required",
                "多客户站点，请用 --tenant / WIST_FIELD_TENANT 指定一个：%s" % tenants,
            )
        return None

    # --------------------------------------------------------------- 健康面

    def healthz(self) -> Dict[str, Any]:
        """`GET /healthz`：**只有直连 BFF（8080）才有**。

        经栈的 web 入口（443 / `WEB_HOST_PORT`）访问时，这个路径由 nginx / 前端接管，
        返回的是页面而不是 BFF JSON。脚本通过 web 入口时请用 `health()`（`/api/health`）。
        这里对非 JSON 做显式报错，避免上层拿到一段 HTML 后报 `str has no attribute get`。
        """
        payload = self.request("GET", "/healthz", add_tenant=False)
        if not isinstance(payload, dict) or "status" not in payload:
            raise FieldApiError(
                502,
                "healthz_not_bff",
                "GET /healthz 返回的不是 BFF JSON（经 web 入口时由 nginx/SPA 接管）；"
                "请改用 /api/health",
            )
        return payload

    def health(self) -> Dict[str, Any]:
        """`GET /api/health`：各数据源就绪度 + 逐条接口探活。"""
        return self.request("GET", "/api/health")

    # --------------------------------------------------------------- 证据面

    def evidence_capabilities(self) -> Dict[str, Any]:
        """`GET /api/evidence/capabilities`：正文怎么读（签名 URL / BFF 代理）。"""
        return self.request("GET", "/api/evidence/capabilities")

    def evidence_openapi(self) -> Dict[str, Any]:
        """`GET /api/evidence/openapi.json`：证据读接口的 OpenAPI 3.1。"""
        return self.request("GET", "/api/evidence/openapi.json")

    def list_evidence(
        self,
        cmd_id: Optional[str] = None,
        kind: Optional[str] = None,
        subject_id: Optional[str] = None,
        since: Optional[str] = None,
        limit: Optional[int] = None,
        cursor: Optional[str] = None,
    ) -> Dict[str, Any]:
        """`GET /api/evidence`：一页证据索引（时间倒序）。"""
        return self.request(
            "GET",
            "/api/evidence",
            query={
                "cmd_id": cmd_id,
                "kind": kind,
                "subject_id": subject_id,
                "since": since,
                "limit": limit,
                "cursor": cursor,
            },
        )

    def iter_evidence(
        self, page_size: int = 50, max_pages: int = 20, **filters: Any
    ) -> Iterator[Dict[str, Any]]:
        """自动翻页。`filters` 接受 cmd_id / kind / subject_id / since。"""
        cursor: Optional[str] = None
        for _ in range(max_pages):
            page = self.list_evidence(limit=page_size, cursor=cursor, **filters)
            for artifact in page.get("artifacts") or []:
                yield artifact
            cursor = page.get("next_cursor")
            if not cursor:
                return
        raise RuntimeError("证据页数超过 max_pages=%d，请缩小筛选条件" % max_pages)

    def get_evidence(self, key: str) -> Dict[str, Any]:
        """`GET /api/evidence/{cmd_id}`：key 可以是命令 id 或 `art_…`。"""
        return self.request("GET", "/api/evidence/" + _quote(key))

    def presign_evidence(self, key: str) -> Dict[str, Any]:
        """`POST /api/evidence/{cmd_id}:presign`：只有 S3 后端支持，否则 501。"""
        return self.request("POST", "/api/evidence/" + _quote(key) + ":presign")

    def evidence_content(self, key: str) -> bytes:
        """`GET /api/evidence/{cmd_id}/content`：BFF 代理读**解压后**的正文。"""
        _, _, payload = self.request(
            "GET", "/api/evidence/" + _quote(key) + "/content", raw=True
        )
        return payload

    def fetch_url(self, url: str) -> Tuple[Dict[str, str], bytes]:
        """取一个预签名 URL：不带 Authorization（签名在 URL 里），不经过 BFF。"""
        request = urllib.request.Request(url)
        try:
            response = urllib.request.urlopen(
                request, timeout=self.timeout, context=self._ssl_context
            )
        except urllib.error.HTTPError as err:
            raise _error_from_body(err.code, err.read()) from None
        except urllib.error.URLError as err:
            raise FieldApiError(0, "network_error", str(err.reason)) from None
        with response:
            return dict(response.headers.items()), response.read()

    # --------------------------------------------------------------- 指标面

    def metrics(self) -> Dict[str, Any]:
        """`GET /api/metrics`：概览（主机 / agent / 业务单元 / 指标目录）。"""
        return self.request("GET", "/api/metrics")

    def metrics_middleware(self) -> Dict[str, Any]:
        """`GET /api/metrics/middleware`：Kafka / DB / 容器等家族的当前读数。"""
        return self.request("GET", "/api/metrics/middleware")

    def ingest_stats(self, window_seconds: int = 0) -> Dict[str, Any]:
        """`GET /api/ingest/stats`：三条通道累计写进来多少、最后一次是什么时候。

        `window_seconds=0` 只看累计（看板轮询走这条）；>0 才额外给窗口内数量。
        """
        return self.request(
            "GET", "/api/ingest/stats", query={"window_seconds": window_seconds}
        )

    # ----------------------------------------------------------- 接入 / 拓扑

    def integration(self) -> Dict[str, Any]:
        """`GET /api/integration`：数据面写端点与 wparse 环境变量。"""
        return self.request("GET", "/api/integration")

    def atlas(self, path: str, query: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """`GET /api/atlas/{path}`：BFF 代理到 atlas 的只读接口。

        例如 `atlas("hosts", {"limit": 200})` → atlas `/api/hosts`；
        `tenant=` 由 BFF 校验后追加，不要自己拼。
        """
        rest = path.lstrip("/")
        if rest.startswith("api/"):
            rest = rest[4:]
        return self.request("GET", "/api/atlas/" + rest, query=query)


# ---------------------------------------------------------------- 数据面写入


def write_evidence(
    sink_url: str,
    cust_id: str,
    cmd_id: str,
    content: Any,
    subject: Optional[str] = None,
    timeout: float = 15.0,
    insecure: Optional[bool] = None,
) -> Dict[str, Any]:
    """直接向证据服务写端点 `POST /internal/evidence` 写一条（数据面视角）。

    `sink_url` 是证据服务的写地址根（`http://host:18800`），不是 BFF 地址；
    可直接用 `GET /api/integration` 里的 `evidence.write_url` 去掉
    `/internal/evidence` 得到。写端点走内网明文、无认证，不要暴露到公网。
    """
    base = sink_url.rstrip("/")
    url = base if base.endswith("/internal/evidence") else base + "/internal/evidence"
    record: Dict[str, Any] = {"cust_id": cust_id, "cmd_id": cmd_id, "content": content}
    if subject:
        record["subject"] = subject
    request = urllib.request.Request(
        url,
        data=json.dumps(record, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    if insecure is None:
        insecure = os.environ.get("WIST_FIELD_INSECURE", "").lower() not in (
            "",
            "0",
            "false",
            "no",
        )
    context = None
    if url.startswith("https://"):
        context = ssl.create_default_context()
        if insecure:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        raise _error_from_body(err.code, err.read()) from None
    except urllib.error.URLError as err:
        raise FieldApiError(0, "network_error", str(err.reason)) from None


# ------------------------------------------------------------------- 小工具


def _quote(value: str) -> str:
    return urllib.parse.quote(str(value), safe="")


def _error_from_body(status: int, payload: bytes) -> FieldApiError:
    text = payload.decode("utf-8", "replace")
    code = str(status)
    message = text[:300] or ("HTTP %d" % status)
    try:
        envelope = json.loads(text)
        error = envelope.get("error") or {}
        code = error.get("code") or code
        message = error.get("message") or message
    except (ValueError, AttributeError):
        pass
    return FieldApiError(status, code, message, payload)


ERROR_HINTS = {
    400: "参数不对；多客户站点忘了 ?tenant= 会是 tenant_required。",
    401: "令牌缺失 / 过期 / 被撤销；重新登录或换一把 wcr_… 令牌。",
    403: "令牌有效但角色不够（role_required）或客户越界（tenant_not_allowed）。",
    404: "不存在或不可见：跨客户 / 敏感度过高 / 已过期一律 404。",
    501: "这个部署不签发预签名 URL（本地文件存储），改走 /content 代理读。",
    502: "BFF 到上游（证据 / atlas）不可用，先看 /api/health 的 interfaces。",
    503: "本服务还没初始化（没有 cred 材料）或指标域没接入（metrics_not_configured）。",
}


def explain(err: FieldApiError) -> str:
    hint = ERROR_HINTS.get(err.status)
    if err.status == 0:
        hint = (
            "连不上站点入口：确认地址 / 端口（本栈默认 https://127.0.0.1:8088）。"
            "本地自签入口会自动读取 identity/web/public/web-ca.crt.pem；"
            "找不到时才用 --insecure / WIST_FIELD_INSECURE=1。"
        )
    return "%s%s" % (str(err), ("\n提示：" + hint) if hint else "")


def add_common_args(parser: Any) -> None:
    parser.add_argument("--url", help="站点入口地址（默认 WIST_FIELD_URL 或 %s）" % DEFAULT_URL)
    parser.add_argument("--token", help="访问令牌 wcr_…（默认 WIST_FIELD_TOKEN）")
    parser.add_argument("--tenant", help="客户 id（多客户站点必填，默认 WIST_FIELD_TENANT）")
    parser.add_argument(
        "--operator", help="ingress 模式的操作员（默认 WIST_FIELD_OPERATOR）"
    )
    parser.add_argument(
        "--insecure", action="store_true", default=None, help="跳过 https 证书校验（仅开发）"
    )
    parser.add_argument("--timeout", type=float, help="超时秒数（默认 15）")


def client_from_args(args: Any) -> FieldClient:
    client = FieldClient(
        base_url=args.url,
        token=args.token,
        tenant=args.tenant,
        operator=args.operator,
        timeout=args.timeout,
        insecure=args.insecure,
    )
    # 本地栈零参数体验：没有令牌时从可发现的本地 cred 自动领一把短令牌。
    # 只在 localhost 会触发，避免对远程 / 生产入口做隐式凭据签发。
    if not client.token and not client.operator and _should_auto_mint(client.base_url):
        try:
            token, audience = mint_dev_token()
        except FieldApiError as err:
            print("[dev] 未自动签发令牌：%s" % err, file=sys.stderr)
        else:
            client.token = token
            print(
                "[dev] 未提供令牌，已从本地 cred 自动领一把 5 分钟令牌"
                "（audience=%s；WIST_FIELD_NO_DEV_TOKEN=1 可关闭）" % audience,
                file=sys.stderr,
            )
    return client


def require_auth(client: FieldClient) -> bool:
    """没有令牌时输出一条简短、可执行的提示（不打印整页 argparse usage）。"""
    if client.token or client.operator:
        return True
    print(
        "没有访问令牌：设置 WIST_FIELD_TOKEN；本地开发也可以设置 "
        "WIST_CRED_SECRET_FILE / WIST_CRED_SITE 让脚本自动签 5 分钟令牌。",
        file=sys.stderr,
    )
    return False


def fail(err: FieldApiError) -> NoReturn:
    print(explain(err), file=sys.stderr)
    raise SystemExit(2)
