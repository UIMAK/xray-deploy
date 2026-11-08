#!/usr/bin/env python3
"""把分享链接解析成 Xray 出站对象。

只做纯解析：读取一批链接，输出带 tag/protocol/server/port/outbound 的 JSON。
交互、tag 占用校验和配置事务仍由 Shell 负责。
"""

import base64
import binascii
import ipaddress
import json
import re
import sys


SUPPORTED_TEXT = "Hysteria2/Hy2、VLESS、VMess、Trojan、Shadowsocks、SOCKS"
SCHEME_RE = re.compile(
    r"(hysteria2|hy2|anytls|vless|vmess|trojan-go|trojan|ssr|ss|socks5?|tuic|hysteria|"
    r"shadowtls|naive\+https|https?)://",
    re.IGNORECASE,
)
SEPARATORS = " \t\r\n,;，；"


class ParseError(Exception):
    pass


def fail(message):
    raise ParseError(message)


def has_control(value):
    return any(ord(char) < 0x20 or ord(char) == 0x7F for char in value)


def percent_decode(raw, plus=False):
    out = bytearray()
    index = 0
    while index < len(raw):
        char = raw[index]
        if char == "%":
            hex_digits = raw[index + 1:index + 3]
            if len(hex_digits) != 2 or not re.fullmatch(r"[0-9A-Fa-f]{2}", hex_digits):
                fail("百分号编码无效")
            byte = int(hex_digits, 16)
            if byte == 0:
                fail("编码内容包含 NUL")
            out.append(byte)
            index += 3
        elif char == "+" and plus:
            out.append(0x20)
            index += 1
        else:
            out.extend(char.encode("utf-8"))
            index += 1
    try:
        value = out.decode("utf-8")
    except UnicodeDecodeError:
        fail("编码内容不是有效 UTF-8")
    if has_control(value):
        fail("内容包含控制字符")
    return value


def base64_normalize(raw):
    if not raw or any(char.isspace() for char in raw):
        return None
    value = raw.replace("-", "+").replace("_", "/")
    if not re.fullmatch(r"[A-Za-z0-9+/]*={0,2}", value):
        return None
    value = value.split("=", 1)[0]
    if not value or len(value) % 4 == 1:
        return None
    return value + "=" * ((4 - len(value) % 4) % 4)


def base64_decode(raw):
    padded = base64_normalize(raw)
    if padded is None:
        return None
    try:
        return base64.b64decode(padded, validate=True)
    except (binascii.Error, ValueError):
        return None


def validate_host(host, label="服务器地址"):
    if not host:
        fail(label + "不能为空")
    if any(char.isspace() or char in "/?#@[]" for char in host):
        fail(label + "格式无效")
    if ":" in host:
        if "%" in host:
            fail(label + "不是有效 IPv6")
        try:
            ipaddress.IPv6Address(host)
        except ValueError:
            fail(label + "不是有效 IPv6")
        return
    if re.fullmatch(r"[0-9.]+", host):
        try:
            ipaddress.IPv4Address(host)
        except ValueError:
            fail(label + "不是有效 IPv4")
        return
    if not re.fullmatch(r"[A-Za-z0-9.-]+", host):
        fail(label + "格式无效")
    host = host[:-1] if host.endswith(".") else host
    if not host or len(host) > 253:
        fail(label + "格式无效")
    for part in host.split("."):
        if not part or len(part) > 63:
            fail(label + "格式无效")
        if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?", part):
            fail(label + "格式无效")


def validate_port(raw, label="端口"):
    if not re.fullmatch(r"[0-9]{1,5}", raw or ""):
        fail(label + "必须是十进制整数")
    port = int(raw, 10)
    if port < 1 or port > 65535:
        fail(label + "须在 1-65535")
    return port


def uuid_value(raw):
    if re.fullmatch(r"[0-9A-Fa-f]{32}", raw):
        raw = "%s-%s-%s-%s-%s" % (raw[:8], raw[8:12], raw[12:16], raw[16:20], raw[20:])
    if not re.fullmatch(
        r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        raw,
    ):
        fail("UUID 格式无效")
    return raw.lower()


def validate_path(raw, label="path"):
    if not raw:
        return ""
    if any(char.isspace() for char in raw):
        fail(label + "不能包含空白")
    if has_control(raw):
        fail(label + "包含控制字符")
    return raw if raw.startswith("/") else "/" + raw


def split_url(link):
    if "://" not in link:
        fail("分享链接缺少协议前缀")
    scheme, rest = link.split("://", 1)
    fragment = ""
    raw_query = ""
    path = ""
    if "#" in rest:
        rest, fragment = rest.split("#", 1)
    if "?" in rest:
        rest, raw_query = rest.split("?", 1)
    if "/" in rest:
        authority, path = rest.split("/", 1)
        path = "/" + path
    else:
        authority = rest
    if "@" in authority:
        userinfo, hostport = authority.rsplit("@", 1)
    else:
        userinfo, hostport = "", authority
    if not hostport:
        fail("链接缺少服务器地址")
    return {
        "scheme": scheme.lower(),
        "fragment": fragment,
        "query": raw_query,
        "userinfo": userinfo,
        "hostport": hostport,
        "path": path,
    }


def parse_hostport(value):
    if not value:
        fail("链接缺少服务器地址")
    if value.startswith("["):
        match = re.fullmatch(r"\[([0-9A-Fa-f:.]+)\](?::([0-9]+))?", value)
        if not match:
            fail("IPv6 地址格式无效")
        host = match.group(1)
        port = match.group(2) or ""
    else:
        if ":" in value:
            host, port = value.rsplit(":", 1)
        else:
            host, port = value, ""
        if ":" in host:
            fail("IPv6 地址需用 [] 包裹")
    validate_host(host)
    return host, port


class Query:
    def __init__(self, raw=""):
        self.items = []
        self.keys = []
        seen = set()
        if not raw:
            return
        rest = raw
        while True:
            part, separator, tail = rest.partition("&")
            if not part:
                fail("查询字符串包含空参数")
            key, equals, value = part.partition("=")
            # URI query 里的 '+' 是字面子分隔符, 只有 form 编码才映射成空格;
            # 按 form 解码会把 base64(如 ECH)里的 '+' 改成空格并静默改错凭据。
            key = percent_decode(key).lower()
            if not re.fullmatch(r"[a-z0-9_.-]+", key):
                fail("查询参数名无效")
            if key in seen:
                fail("查询参数重复: " + key)
            seen.add(key)
            self.keys.append(key)
            value = percent_decode(value)
            if value:
                self.items.append((key, value))
            if not separator:
                break
            rest = tail

    @classmethod
    def from_items(cls, items):
        query = cls()
        query.items = list(items)
        query.keys = [key for key, _ in query.items]
        return query

    def get(self, name):
        for key, value in self.items:
            if key == name:
                return value
        return None

    def any(self, names):
        return any(self.get(name) is not None for name in names)


def alias_get(query, label, names):
    found = None
    seen = False
    for name in names:
        value = query.get(name)
        if value is None:
            continue
        if seen and value != found:
            fail(label + "参数冲突")
        found = value
        seen = True
    return found if seen else None


def bool_get(query, label, names):
    value = alias_get(query, label, names)
    if value is None:
        return None
    lower = value.lower()
    if lower in ("1", "true", "yes", "on"):
        return True
    if lower in ("0", "false", "no", "off"):
        return False
    fail(label + "只能为 0/1/true/false")


def int_get(query, label, minimum, maximum, names):
    value = alias_get(query, label, names)
    if value is None:
        return None
    if not re.fullmatch(r"[0-9]{1,9}", value):
        fail(label + "必须是十进制整数")
    number = int(value, 10)
    if number < minimum or number > maximum:
        fail("%s须在 %d-%d" % (label, minimum, maximum))
    return number


def check_query(query, allowed):
    allowed = set(allowed)
    # 白名单按参数名校验: ?unknown= 这类空值参数不进入 items, 但同样必须拒绝。
    for key in query.keys:
        if key not in allowed:
            fail("链接包含暂不支持的参数: " + key)


def read_alpn(query):
    value = query.get("alpn")
    if value is None:
        return None
    items = value.split(",")
    for item in items:
        if not item:
            fail("alpn 包含空值")
        if re.search(r"[^A-Za-z0-9._+/:-]", item):
            fail("alpn 格式无效")
    return items


def read_fp(query):
    value = query.get("fp")
    if value is None:
        return None
    value = value.lower()
    allowed = {
        "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq",
        "random", "randomized", "randomizednoalpn", "unsafe",
    }
    if value in allowed:
        return value
    if value.startswith("hello") and re.fullmatch(r"hello[a-z0-9_]+", value):
        return value
    fail("不支持的 uTLS 指纹: " + value)


def read_pins(query):
    value = alias_get(
        query,
        "证书 pin",
        ("pcs", "pinsha256", "pinnedpeercertsha256", "pin-sha256", "pin_sha256"),
    )
    if value is None:
        return None
    parts = []
    for part in value.split(","):
        part = part.replace(":", "")
        if not re.fullmatch(r"[0-9A-Fa-f]{64}", part):
            fail("pinnedPeerCertSha256 必须是 64 位十六进制")
        parts.append(part.lower())
    if not parts:
        fail("pinnedPeerCertSha256 不能为空")
    return ",".join(parts)


def read_vcn(query):
    value = alias_get(query, "verifyPeerCertByName", ("vcn", "verifypeercertbyname"))
    if value is None:
        return None
    parts = []
    for part in value.split(","):
        if not part:
            fail("verifyPeerCertByName 包含空值")
        if re.search(r"[^A-Za-z0-9._*-]", part):
            fail("verifyPeerCertByName 格式无效")
        parts.append(part)
    if not parts:
        fail("verifyPeerCertByName 不能为空")
    return ",".join(parts)


def read_ech(query):
    value = alias_get(query, "ECH", ("ech",))
    if value is None:
        return None
    if "://" in value:
        if any(char.isspace() for char in value):
            fail("ECH 配置格式无效")
        return value
    padded = base64_normalize(value)
    if padded is None:
        fail("ECH 配置不是有效 Base64")
    return padded


def set_sni_value(value):
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    elif "[" in value or "]" in value:
        fail("SNI 格式无效")
    validate_host(value, "SNI")
    return "[" + value + "]" if ":" in value else value


def read_sni(query, server, required):
    value = alias_get(query, "SNI", ("sni", "peer", "servername"))
    if value is not None:
        return set_sni_value(value)
    if required:
        fail("Reality 链接缺少 SNI")
    return set_sni_value(server)


def read_reality(query):
    pbk = alias_get(query, "Reality 公钥 pbk", ("pbk", "publickey", "public-key"))
    if pbk is not None:
        if not re.fullmatch(r"[A-Za-z0-9_-]{43}", pbk):
            fail("Reality 公钥 pbk 格式无效")
        padded = base64_normalize(pbk)
        decoded = base64_decode(pbk)
        if padded is None or decoded is None:
            fail("Reality 公钥 pbk 不是有效 Base64Url")
        if len(decoded) != 32:
            fail("Reality 公钥 pbk 长度不是 32 字节")
    else:
        fail("Reality 链接缺少公钥 pbk")

    sid = alias_get(query, "Reality shortId", ("sid", "shortid", "short-id"))
    if sid is not None:
        if not re.fullmatch(r"[0-9A-Fa-f]{0,16}", sid) or len(sid) % 2 != 0:
            fail("Reality shortId 必须是不超过 16 位的偶数长度十六进制")
    else:
        sid = ""

    spx = alias_get(query, "Reality spiderX", ("spx", "spiderx", "spider-x"))
    if spx is not None:
        if not spx.startswith("/"):
            fail("Reality spiderX 必须以 / 开头")
        if any(char.isspace() for char in spx):
            fail("Reality spiderX 不能包含空白")
    else:
        spx = ""

    pqv = alias_get(query, "Reality mldsa65Verify", ("pqv", "mldsa65verify", "mldsa65-verify"))
    if pqv is not None:
        if len(pqv) != 2603 or not re.fullmatch(r"[A-Za-z0-9_-]+", pqv):
            fail("Reality pqv 必须是 2603 位 Base64Url")
        decoded = base64_decode(pqv)
        if base64_normalize(pqv) is None or decoded is None:
            fail("Reality pqv 不是有效 Base64Url")
        if len(decoded) != 1952:
            fail("Reality pqv 长度不是 1952 字节")
    else:
        pqv = ""

    return {"pbk": pbk, "sid": sid, "spx": spx, "pqv": pqv}


TLS_PARAM_NAMES = (
    "sni", "peer", "servername", "pbk", "publickey", "public-key",
    "sid", "shortid", "short-id", "fp", "alpn", "insecure", "allowinsecure",
    "skip-cert-verify", "pcs", "pinsha256", "pinnedpeercertsha256",
    "pin-sha256", "pin_sha256", "vcn", "verifypeercertbyname", "ech",
    "spx", "spiderx", "spider-x", "pqv", "mldsa65verify", "mldsa65-verify",
)


def build_tls_settings(mode, server, query):
    if mode == "none":
        if query.any(TLS_PARAM_NAMES):
            fail("未启用 TLS/Reality，却包含 TLS 参数")
        return {}, server
    if mode == "tls":
        sni = read_sni(query, server, False)
        alpn = read_alpn(query)
        fp = read_fp(query)
        pins = read_pins(query)
        vcn = read_vcn(query)
        ech = read_ech(query)
        insecure = bool_get(
            query, "insecure",
            ("insecure", "allowinsecure", "skip-cert-verify", "skipcertverify"),
        )
        if insecure is True and not pins and not vcn:
            fail("Xray 已移除 allowInsecure；请改用 pcs(pinnedPeerCertSha256) 或 vcn(verifyPeerCertByName)")
        if query.any(
            ("pbk", "publickey", "public-key", "sid", "shortid", "short-id",
             "spx", "spiderx", "spider-x", "pqv", "mldsa65verify", "mldsa65-verify")
        ):
            fail("非 Reality 链接包含 Reality 参数")
        result = {"serverName": sni}
        if alpn is not None:
            result["alpn"] = alpn
        if fp:
            result["fingerprint"] = fp
        if pins:
            result["pinnedPeerCertSha256"] = pins
        if vcn:
            result["verifyPeerCertByName"] = vcn
        if ech:
            result["echConfigList"] = ech
        return result, sni
    if mode == "reality":
        sni = read_sni(query, server, True)
        reality = read_reality(query)
        fp = read_fp(query)
        if fp in ("unsafe", "hellogolang"):
            fail("Reality 不支持 uTLS 指纹: " + fp)
        insecure = bool_get(
            query, "insecure",
            ("insecure", "allowinsecure", "skip-cert-verify", "skipcertverify"),
        )
        if insecure is True:
            fail("Reality 不能同时启用 insecure")
        if query.any(
            ("alpn", "pcs", "pinsha256", "pinnedpeercertsha256", "pin-sha256",
             "pin_sha256", "vcn", "verifypeercertbyname", "ech")
        ):
            fail("Reality 不支持 alpn/pcs/vcn/ech 参数")
        result = {"serverName": sni, "publicKey": reality["pbk"]}
        if reality["sid"]:
            result["shortId"] = reality["sid"]
        if reality["spx"]:
            result["spiderX"] = reality["spx"]
        if reality["pqv"]:
            result["mldsa65Verify"] = reality["pqv"]
        if fp:
            result["fingerprint"] = fp
        return result, sni
    fail("未知安全类型: " + mode)


def read_transport_kind(query):
    kind = alias_get(query, "传输类型", ("type", "net"))
    kind = (kind or "tcp").lower()
    if kind in ("tcp", "raw"):
        return "raw"
    if kind in ("ws", "websocket"):
        return "ws"
    if kind == "httpupgrade":
        return "httpupgrade"
    if kind in ("xhttp", "splithttp"):
        return "xhttp"
    if kind == "grpc":
        return "grpc"
    if kind in ("http", "h2", "h3", "quic"):
        fail("Xray 已移除 %s 传输，请改用 XHTTP" % kind)
    if kind in ("kcp", "mkcp"):
        fail("KCP 已迁移到 FinalMask，暂不支持从分享链接导入")
    fail("不支持的传输类型: " + kind)


def check_earlydata_header(kind, query):
    value = query.get("earlydataheadername")
    if value is None:
        return
    header = value.lower()
    if kind != "ws":
        fail("earlyDataHeaderName 只适用于 WebSocket 传输")
    if header not in ("", "sec-websocket-protocol"):
        fail("Xray 只使用 Sec-WebSocket-Protocol 作为 WS early data 头")


def build_transport(kind, query):
    host = query.get("host") or ""
    path = query.get("path") or ""
    service = query.get("servicename") or ""
    authority = query.get("authority") or ""
    mode = query.get("mode") or ""
    extra = query.get("extra") or ""
    ed = query.get("ed") or ""

    if kind == "raw":
        if any((host, path, service, authority, extra, ed)):
            fail("RAW 传输不支持 host/path/serviceName/authority/extra/ed")
        if mode and mode.lower() != "auto":
            fail("RAW 传输不支持 mode")
        return "raw", None

    if kind in ("ws", "httpupgrade"):
        if any((service, authority, extra)):
            fail("WebSocket/HTTPUpgrade 传输不支持 serviceName/authority/extra")
        if mode and mode.lower() != "auto":
            fail("WebSocket/HTTPUpgrade 传输不支持 mode")
        path = path or "/"
        path = validate_path(path, "path")
        if ed:
            if not re.fullmatch(r"[0-9]{1,5}", ed) or not 1 <= int(ed, 10) <= 65535:
                fail("ed 须在 1-65535")
            if "?ed=" not in path and "&ed=" not in path:
                path += ("&ed=" if "?" in path else "?ed=") + str(int(ed, 10))
        if host:
            validate_host(host, "Host")
        network = "websocket" if kind == "ws" else "httpupgrade"
        settings = {"path": path}
        if host:
            settings["host"] = host
        return network, settings

    if kind == "xhttp":
        if any((service, authority, ed)):
            fail("XHTTP 传输不支持 serviceName/authority/ed")
        mode = mode or "auto"
        mode = mode.replace("_", "-")
        if mode not in ("auto", "packet-up", "stream-up", "stream-one"):
            fail("XHTTP mode 只支持 auto/packet-up/stream-up/stream-one")
        path = validate_path(path or "/", "path")
        if host:
            validate_host(host, "Host")
        extra_obj = None
        if extra:
            try:
                extra_obj = json.loads(extra)
            except ValueError:
                fail("XHTTP extra 必须是 JSON 对象")
            if not isinstance(extra_obj, dict):
                fail("XHTTP extra 必须是 JSON 对象")
        settings = {"path": path, "mode": mode}
        if host:
            settings["host"] = host
        if extra_obj is not None:
            settings["extra"] = extra_obj
        return "xhttp", settings

    if kind == "grpc":
        if any((host, extra, ed)):
            fail("gRPC 传输不支持 host/extra/ed")
        if path and not service:
            service = path[1:] if path.startswith("/") else path
            path = ""
        if path:
            fail("gRPC 请使用 serviceName")
        mode = mode.lower()
        if mode in ("", "gun"):
            multi = False
        elif mode == "multi":
            multi = True
        else:
            fail("gRPC mode 只支持 gun/multi")
        if authority and any(char.isspace() or char == "/" for char in authority):
            fail("gRPC authority 格式无效")
        settings = {"serviceName": service}
        if multi:
            settings["multiMode"] = True
        if authority:
            settings["authority"] = authority
        return "grpc", settings

    fail("未知传输类型")


def build_stream(security, security_settings, network, transport):
    if security == "reality" and network not in ("raw", "xhttp", "grpc"):
        fail("Reality 只支持 RAW/XHTTP/gRPC 传输")
    result = {"network": network, "security": security}
    if security == "tls":
        result["tlsSettings"] = security_settings
    elif security == "reality":
        result["realitySettings"] = security_settings
    if transport is not None:
        key = {
            "websocket": "wsSettings",
            "httpupgrade": "httpupgradeSettings",
            "xhttp": "xhttpSettings",
            "grpc": "grpcSettings",
        }.get(network)
        if key:
            result[key] = transport
    return result


def tag_from_fragment(fragment, fallback=""):
    if fragment:
        return percent_decode(fragment)
    return fallback


def result(tag, protocol, server, port, outbound):
    return {
        "tag": tag,
        "protocol": protocol,
        "server": server,
        "port": port,
        "outbound": outbound,
    }


def vmess_cipher(value):
    value = (value or "").lower()
    if value in ("", "auto"):
        return "auto"
    if value == "aes-128-gcm":
        return "aes-128-gcm"
    if value in ("chacha20-poly1305", "chacha20-ietf-poly1305"):
        return "chacha20-poly1305"
    fail("VMess 加密只支持 auto/aes-128-gcm/chacha20-poly1305")


def parse_vless(link):
    url = split_url(link)
    if url["scheme"] != "vless":
        fail("不是 VLESS 链接")
    if not url["userinfo"]:
        fail("VLESS 链接缺少 UUID")
    uuid = uuid_value(percent_decode(url["userinfo"]))
    if url["path"] not in ("", "/"):
        fail("VLESS 链接路径无效")
    server, port_raw = parse_hostport(url["hostport"])
    if not port_raw:
        fail("VLESS 链接缺少端口")
    port = validate_port(port_raw)
    query = Query(url["query"])
    check_query(query, (
        "encryption", "flow", "security", "sni", "peer", "servername", "pbk",
        "publickey", "public-key", "sid", "shortid", "short-id", "fp", "type",
        "net", "headertype", "host", "path", "servicename", "mode", "authority",
        "extra", "ed", "earlydataheadername", "alpn", "insecure", "allowinsecure",
        "skip-cert-verify", "pcs", "pinsha256", "pinnedpeercertsha256",
        "pin-sha256", "pin_sha256", "vcn", "verifypeercertbyname", "ech", "spx",
        "spiderx", "spider-x", "pqv", "mldsa65verify", "mldsa65-verify",
        "packetencoding",
    ))
    encryption = query.get("encryption") or "none"
    if any(char.isspace() for char in encryption):
        fail("VLESS encryption 不能包含空白")
    security = query.get("security")
    if security is not None:
        security = security.lower()
        if security in ("", "none"):
            security = "none"
        elif security in ("tls", "reality"):
            pass
        elif security == "xtls":
            fail("Xray 已移除旧 XTLS，请改用 Reality/TLS + xtls-rprx-vision")
        else:
            fail("VLESS security 只支持 none/tls/reality")
    else:
        security = "none"
    flow = query.get("flow") or ""
    if flow:
        if flow not in ("xtls-rprx-vision", "xtls-rprx-vision-udp443"):
            fail("VLESS flow 只支持 xtls-rprx-vision(-udp443)")
        # VLESS 内置加密(encryption 非 none)经 CommonConn 可在 security=none 下跑 vision
        if security not in ("tls", "reality") and not (
            security == "none" and encryption != "none"
        ):
            fail("VLESS flow 需要 TLS 或 Reality")
    kind = read_transport_kind(query)
    check_earlydata_header(kind, query)
    if flow and kind != "raw":
        fail("VLESS flow 只支持 RAW/TCP 传输")
    header = query.get("headertype")
    if header is not None and header.lower() not in ("", "none"):
        fail("VLESS 不支持 headerType 伪装")
    if query.get("packetencoding") is not None:
        fail("Xray 出站没有 packetEncoding 字段；UDP 由核心按 XUDP/Mux 处理")
    security_settings, sni = build_tls_settings(security, server, query)
    network, transport = build_transport(kind, query)
    stream = build_stream(security, security_settings, network, transport)
    settings = {
        "address": server,
        "port": port,
        "id": uuid,
        "encryption": encryption,
    }
    if flow:
        settings["flow"] = flow
    outbound = {"protocol": "vless", "settings": settings, "streamSettings": stream}
    return result(tag_from_fragment(url["fragment"]), "vless", server, port, outbound)


def parse_vmess_url(link):
    url = split_url(link)
    if url["scheme"] != "vmess":
        fail("不是 VMess 链接")
    if not url["userinfo"]:
        fail("VMess 链接缺少 UUID")
    uuid = uuid_value(percent_decode(url["userinfo"]))
    if url["path"] not in ("", "/"):
        fail("VMess 链接路径无效")
    server, port_raw = parse_hostport(url["hostport"])
    if not port_raw:
        fail("VMess 链接缺少端口")
    port = validate_port(port_raw)
    query = Query(url["query"])
    check_query(query, (
        "type", "net", "security", "scy", "encryption", "host", "path", "sni",
        "peer", "servername", "fp", "alpn", "insecure", "allowinsecure",
        "skip-cert-verify", "pcs", "pinsha256", "pinnedpeercertsha256",
        "pin-sha256", "pin_sha256", "vcn", "verifypeercertbyname", "ech", "aid",
        "alterid", "packetencoding", "headertype", "flow", "mode", "servicename",
        "authority", "extra", "ed", "earlydataheadername", "pbk", "publickey",
        "public-key", "sid", "shortid", "short-id", "spx", "spiderx", "spider-x",
        "pqv", "mldsa65verify", "mldsa65-verify",
    ))
    cipher = query.get("scy")
    encryption = query.get("encryption")
    if encryption is not None:
        if cipher is not None:
            fail("VMess scy 与 encryption 重复")
        cipher = encryption
    tls_mode = "none"
    security = query.get("security")
    if security is not None:
        security = security.lower()
        if security in ("", "none"):
            pass
        elif security == "tls":
            tls_mode = "tls"
        elif security == "reality":
            tls_mode = "reality"
        elif security in ("auto", "aes-128-gcm", "chacha20-poly1305", "chacha20-ietf-poly1305"):
            if cipher is not None:
                fail("VMess security 与 scy/encryption 重复")
            cipher = security
        else:
            fail("VMess security 只支持 none/tls/reality 或加密方法")
    cipher = vmess_cipher(cipher)
    int_get(query, "VMess alterId", 0, 0, ("aid", "alterid"))
    if query.get("flow") is not None:
        fail("Xray 不支持 VMess flow")
    if query.get("packetencoding") is not None:
        fail("Xray 出站没有 packetEncoding 字段；UDP 由核心按 XUDP/Mux 处理")
    header = query.get("headertype")
    if header is not None and header.lower() not in ("", "none"):
        fail("VMess 不支持 headerType 伪装")
    kind = read_transport_kind(query)
    check_earlydata_header(kind, query)
    security_settings, sni = build_tls_settings(tls_mode, server, query)
    network, transport = build_transport(kind, query)
    stream = build_stream(tls_mode, security_settings, network, transport)
    outbound = {
        "protocol": "vmess",
        "settings": {"address": server, "port": port, "id": uuid, "security": cipher},
        "streamSettings": stream,
    }
    return result(tag_from_fragment(url["fragment"]), "vmess", server, port, outbound)


def json_value_text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        if isinstance(value, float) and value == 0:
            return "0"
        return str(value)
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def json_field(data, key):
    if key not in data or data[key] is None:
        return ""
    value = json_value_text(data[key])
    if has_control(value):
        fail("VMess JSON 字段 %s 包含控制字符" % key)
    return value


def json_alias(data, label, keys):
    found = ""
    seen = False
    for key in keys:
        if key not in data or data[key] is None:
            continue
        value = json_value_text(data[key])
        if not value:
            continue
        if seen and value != found:
            fail(label + "字段冲突")
        found = value
        seen = True
    if not seen:
        return ""
    if has_control(found):
        fail("VMess JSON 字段 %s 包含控制字符" % label)
    return found


def json_empty(value):
    if value is None or value == "":
        return True
    if isinstance(value, list) and not value:
        return True
    if isinstance(value, dict) and not value:
        return True
    return False


def truthy_flag(value):
    return value is True or value == 1 or value == "1" or value == "true"


def parse_vmess_legacy(link):
    raw = link[len("vmess://"):]
    fragment = ""
    if "#" in raw:
        raw, fragment = raw.split("#", 1)
    if "?" in raw:
        fail("VMess Base64 链接不能包含查询字符串")
    if not raw:
        fail("VMess 链接为空")
    decoded = base64_decode(raw)
    if decoded is None:
        fail("VMess 链接 Base64 无效")
    try:
        text = decoded.decode("utf-8")
        data = json.loads(text)
    except (UnicodeDecodeError, ValueError):
        fail("VMess Base64 内容不是有效 JSON 对象")
    if not isinstance(data, dict):
        fail("VMess Base64 内容不是有效 JSON 对象")

    allowed = {
        "v", "ps", "add", "port", "id", "aid", "scy", "security", "net", "type",
        "host", "path", "tls", "sni", "alpn", "fp", "insecure", "allowinsecure",
        "skip-cert-verify", "packetencoding", "mode", "serviceName", "authority",
        "extra", "ed", "earlydataheadername", "pcs", "vcn", "ech", "pbk",
        "publicKey", "public-key", "sid", "shortId", "short-id", "spx", "spiderX",
        "spider-x", "pqv", "mldsa65Verify", "mldsa65-verify",
    }
    unknown = [key for key, value in data.items() if key not in allowed and not json_empty(value)]
    if unknown:
        fail("VMess JSON 包含暂不支持的字段: " + ",".join(unknown))

    server = json_field(data, "add")
    validate_host(server)
    port_raw = json_field(data, "port")
    if not port_raw:
        fail("VMess JSON 缺少端口 port")
    port = validate_port(port_raw, "VMess 端口")
    uuid = uuid_value(json_field(data, "id"))
    aid = data.get("aid", 0)
    if aid is None:
        aid = 0
    aid_text = json_value_text(aid)
    # 部分生成器把 aid 留空; 空值与缺省同义(AEAD 只要求 alterId 为 0)。
    if aid_text not in ("0", ""):
        fail("VMess 只支持 AEAD，alterId 必须为 0")
    ps = json_field(data, "ps")
    cipher = json_field(data, "scy")
    security_tls = False
    security_reality = False
    tls_mode = "none"
    security = json_field(data, "security")
    if security:
        lower = security.lower()
        if lower == "tls":
            security_tls = True
            tls_mode = "tls"
        elif lower == "reality":
            security_reality = True
            tls_mode = "reality"
        elif lower == "none":
            pass
        elif lower in ("auto", "aes-128-gcm", "chacha20-poly1305", "chacha20-ietf-poly1305"):
            if cipher:
                fail("VMess scy 与 security 重复")
            cipher = security
        else:
            fail("VMess JSON security 无效")
    cipher = vmess_cipher(cipher)

    tls_raw = json_field(data, "tls").lower()
    if tls_raw == "":
        pass
    elif tls_raw == "none":
        if security_tls or security_reality:
            fail("VMess tls 与 security 冲突")
        tls_mode = "none"
    elif tls_raw == "tls":
        if security_reality:
            fail("VMess tls 与 security 冲突")
        tls_mode = "tls"
    elif tls_raw == "true":
        if security_reality:
            fail("VMess tls 与 security 冲突")
        tls_mode = "tls"
    elif tls_raw == "false":
        if security_tls or security_reality:
            fail("VMess tls 与 security 冲突")
        tls_mode = "none"
    elif tls_raw == "reality":
        if security_tls:
            fail("VMess tls 与 security 冲突")
        tls_mode = "reality"
    else:
        fail("VMess JSON 只支持 tls/reality 或明文")

    net = json_field(data, "net").lower() or "tcp"
    service = ""
    mode = ""
    if net in ("tcp", "raw"):
        kind = "raw"
    elif net in ("ws", "websocket"):
        kind = "ws"
    elif net == "httpupgrade":
        kind = "httpupgrade"
    elif net in ("xhttp", "splithttp"):
        kind = "xhttp"
    elif net == "grpc":
        kind = "grpc"
        service = json_field(data, "serviceName")
        mode = json_field(data, "mode")
        path = json_field(data, "path")
        if not service and path:
            service = path[1:] if path.startswith("/") else path
        net_type = json_field(data, "type")
        if not mode:
            mode = net_type
    elif net in ("http", "h2", "h3", "quic"):
        fail("Xray 已移除 %s 传输，请改用 XHTTP" % net)
    elif net in ("kcp", "mkcp"):
        fail("KCP 已迁移到 FinalMask，暂不支持从分享链接导入")
    else:
        fail("VMess JSON 不支持的传输: " + net)

    if kind != "grpc":
        header = json_field(data, "type").lower()
        if header not in ("", "none"):
            fail("VMess 不支持 headerType 伪装")

    items = []
    if tls_mode != "none":
        items.append(("sni", json_field(data, "sni")))
        alpn = json_field(data, "alpn")
        if alpn:
            items.append(("alpn", alpn))
        items.append(("fp", json_field(data, "fp")))
        items.append(("pcs", json_field(data, "pcs")))
        items.append(("vcn", json_field(data, "vcn")))
        items.append(("ech", json_field(data, "ech")))
        if (
            truthy_flag(data.get("insecure"))
            or truthy_flag(data.get("allowinsecure"))
            or truthy_flag(data.get("skip-cert-verify"))
        ):
            items.append(("insecure", "1"))
    else:
        if any(
            json_field(data, key) != ""
            for key in ("sni", "alpn", "fp", "pcs", "vcn", "ech")
        ) or any(
            truthy_flag(data.get(key))
            for key in ("insecure", "allowinsecure", "skip-cert-verify")
        ):
            fail("VMess 未启用 TLS，却包含 TLS 参数")

    for key, names in (
        ("pbk", ("pbk", "publicKey", "public-key")),
        ("sid", ("sid", "shortId", "short-id")),
        ("spx", ("spx", "spiderX", "spider-x")),
        ("pqv", ("pqv", "mldsa65Verify", "mldsa65-verify")),
    ):
        value = json_alias(data, "Reality " + key, names)
        if value:
            items.append((key, value))
    items.append(("host", json_field(data, "host")))
    if kind != "grpc":
        items.append(("path", json_field(data, "path")))
    items.append(("authority", json_field(data, "authority")))
    items.append(("extra", json_field(data, "extra")))
    items.append(("ed", json_field(data, "ed")))
    items.append(("earlydataheadername", json_field(data, "earlydataheadername")))
    if kind != "grpc":
        items.append(("mode", json_field(data, "mode")))
    else:
        items.append(("servicename", service))
        items.append(("mode", mode))
    query = Query.from_items([(key, value) for key, value in items if value])
    if json_field(data, "packetencoding"):
        fail("Xray 出站没有 packetEncoding 字段；UDP 由核心按 XUDP/Mux 处理")
    check_earlydata_header(kind, query)
    security_settings, sni = build_tls_settings(tls_mode, server, query)
    network, transport = build_transport(kind, query)
    stream = build_stream(tls_mode, security_settings, network, transport)
    outbound = {
        "protocol": "vmess",
        "settings": {"address": server, "port": port, "id": uuid, "security": cipher},
        "streamSettings": stream,
    }
    return result(tag_from_fragment(fragment, ps), "vmess", server, port, outbound)


def parse_vmess(link):
    raw = link[len("vmess://"):]
    body = raw.split("#", 1)[0].split("?", 1)[0]
    if "@" in body:
        return parse_vmess_url(link)
    return parse_vmess_legacy(link)


def parse_trojan(link):
    url = split_url(link)
    if url["scheme"] != "trojan":
        fail("不是 Trojan 链接")
    if not url["userinfo"]:
        fail("Trojan 链接缺少密码")
    password = percent_decode(url["userinfo"])
    if not password:
        fail("Trojan 密码不能为空")
    if url["path"] not in ("", "/"):
        fail("Trojan 链接路径无效")
    server, port_raw = parse_hostport(url["hostport"])
    if not port_raw:
        fail("Trojan 链接缺少端口")
    port = validate_port(port_raw)
    query = Query(url["query"])
    check_query(query, (
        "security", "sni", "peer", "servername", "alpn", "fp", "type", "net",
        "host", "path", "servicename", "mode", "authority", "extra", "ed",
        "headertype", "insecure", "allowinsecure", "skip-cert-verify", "pcs",
        "pinsha256", "pinnedpeercertsha256", "pin-sha256", "pin_sha256", "vcn",
        "verifypeercertbyname", "ech", "flow", "packetencoding",
        "earlydataheadername", "pbk", "publickey", "public-key", "sid", "shortid",
        "short-id", "spx", "spiderx", "spider-x", "pqv", "mldsa65verify",
        "mldsa65-verify",
    ))
    security = query.get("security")
    if security is not None:
        security = security.lower()
        if security in ("", "tls"):
            security = "tls"
        elif security == "none":
            pass
        elif security == "xtls":
            fail("Xray 已移除旧 XTLS")
        elif security == "reality":
            pass
        else:
            fail("Trojan security 只支持 reality/tls/none")
    else:
        security = "tls"
    if query.get("flow") is not None:
        fail("Xray 已移除 Trojan flow")
    if query.get("packetencoding") is not None:
        fail("Xray 出站没有 packetEncoding 字段；UDP 由核心按 XUDP/Mux 处理")
    header = query.get("headertype")
    if header is not None and header.lower() not in ("", "none"):
        fail("Trojan 不支持 headerType 伪装")
    kind = read_transport_kind(query)
    check_earlydata_header(kind, query)
    security_settings, sni = build_tls_settings(security, server, query)
    network, transport = build_transport(kind, query)
    stream = build_stream(security, security_settings, network, transport)
    outbound = {
        "protocol": "trojan",
        "settings": {"address": server, "port": port, "password": password},
        "streamSettings": stream,
    }
    return result(tag_from_fragment(url["fragment"]), "trojan", server, port, outbound)


def ss2022_valid(method, password):
    need = {
        "2022-blake3-aes-128-gcm": 16,
        "2022-blake3-aes-256-gcm": 32,
        "2022-blake3-chacha20-poly1305": 32,
    }.get(method)
    if need is None:
        return True
    if password.count(":") > 1:
        return False
    for part in password.split(":"):
        if not part:
            return False
        decoded = base64_decode(part)
        if decoded is None or len(decoded) != need:
            return False
    return True


def parse_ss(link):
    raw = link[len("ss://"):]
    if "#" in raw:
        raw, fragment = raw.split("#", 1)
    else:
        fragment = ""
    if "?" in raw:
        raw, query_raw = raw.split("?", 1)
    else:
        query_raw = ""
    if not raw:
        fail("Shadowsocks 链接为空")
    # SIP002 允许端口后跟可选路径 "/": ss://userinfo@host:port[/][?plugin][#tag]
    if raw.endswith("/"):
        raw = raw[:-1]
    if query_raw:
        query = Query(query_raw)
        if query.get("plugin") is not None or query.get("plugin-opts") is not None:
            fail("Xray Shadowsocks 出站不支持 SIP003 插件")
        check_query(query, ())
    if "@" in raw:
        userinfo, endpoint = raw.rsplit("@", 1)
        userinfo = percent_decode(userinfo)
        if ":" in userinfo:
            method_password = userinfo
        else:
            decoded = base64_decode(userinfo)
            if decoded is None:
                fail("Shadowsocks 凭据 Base64 无效")
            try:
                method_password = decoded.decode("utf-8")
            except UnicodeDecodeError:
                fail("Shadowsocks 凭据 Base64 无效")
    else:
        decoded = base64_decode(raw)
        if decoded is None:
            fail("Shadowsocks 整串 Base64 无效")
        try:
            method_password = decoded.decode("utf-8")
        except UnicodeDecodeError:
            fail("Shadowsocks 整串 Base64 无效")
        if "@" not in method_password:
            fail("Shadowsocks Base64 内容缺少服务器地址")
        method_password, endpoint = method_password.rsplit("@", 1)
    if ":" not in method_password:
        fail("Shadowsocks 链接缺少加密方法或密码")
    method, password = method_password.split(":", 1)
    method = method.lower()
    aliases = {
        "aead_aes_128_gcm": "aes-128-gcm",
        "aead_aes_256_gcm": "aes-256-gcm",
        "aead_chacha20_poly1305": "chacha20-poly1305",
        "chacha20-ietf-poly1305": "chacha20-poly1305",
        "aead_xchacha20_poly1305": "xchacha20-poly1305",
        "xchacha20-ietf-poly1305": "xchacha20-poly1305",
    }
    method = aliases.get(method, method)
    if method not in (
        "aes-128-gcm", "aes-256-gcm", "chacha20-poly1305", "xchacha20-poly1305",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
        "2022-blake3-chacha20-poly1305",
    ):
        fail("Shadowsocks 加密方法不在 Xray 支持范围内: " + method)
    if not password:
        fail("Shadowsocks 密码不能为空")
    if not ss2022_valid(method, password):
        fail("Shadowsocks 2022 密钥长度或 Base64 与服务端算法不匹配")
    server, port_raw = parse_hostport(endpoint)
    if not port_raw:
        fail("Shadowsocks 链接缺少端口")
    port = validate_port(port_raw)
    outbound = {
        "protocol": "shadowsocks",
        "settings": {
            "address": server,
            "port": port,
            "method": method,
            "password": password,
        },
    }
    return result(tag_from_fragment(fragment), "shadowsocks", server, port, outbound)


def parse_socks(link):
    raw = link.split("://", 1)[1]
    if "#" in raw:
        raw, fragment = raw.split("#", 1)
    else:
        fragment = ""
    if "?" in raw:
        raw, query_raw = raw.split("?", 1)
    else:
        query_raw = ""
    if not raw:
        fail("SOCKS 链接为空")
    if query_raw:
        query = Query(query_raw)
        check_query(query, ())
    if "@" not in raw and ":" not in raw:
        decoded = base64_decode(raw)
        if decoded is None:
            fail("SOCKS 整串 Base64 无效")
        try:
            raw = decoded.decode("utf-8")
        except UnicodeDecodeError:
            fail("SOCKS 整串 Base64 无效")
        if "@" not in raw:
            fail("SOCKS 整串 Base64 缺少用户信息")
    # 不复用 split_url: Base64 认证串可能含字面 "/", 按第一个 "/" 切 path 会误判;
    # 与 parse_ss 同口径, 用 rsplit("@", 1) 分离 userinfo 与 hostport。
    if "@" in raw:
        userinfo, hostport = raw.rsplit("@", 1)
    else:
        userinfo, hostport = "", raw
    if not hostport:
        fail("链接缺少服务器地址")
    if hostport.endswith("/"):
        hostport = hostport[:-1]
    if "/" in hostport:
        fail("SOCKS 链接不能包含路径")
    server, port_raw = parse_hostport(hostport)
    if not port_raw:
        fail("SOCKS 链接缺少端口")
    port = validate_port(port_raw)
    username = ""
    password = ""
    b64_auth = False
    if userinfo:
        if ":" in userinfo:
            raw_username, raw_password = userinfo.split(":", 1)
            username = percent_decode(raw_username)
            password = percent_decode(raw_password)
        else:
            # 无原始冒号沿用旧实现顺序: 先整体 percent 解码再判断, 兼容 %3D
            # 编码的 Base64 填充与 %3A 编码的 user:pass 分隔符; 解码后仍无
            # 冒号才按 Base64 认证串处理
            decoded_userinfo = percent_decode(userinfo)
            if ":" in decoded_userinfo:
                username, password = decoded_userinfo.split(":", 1)
            else:
                b64_auth = True
                decoded = base64_decode(decoded_userinfo)
                if decoded is None:
                    fail("SOCKS 认证 Base64 无效")
                try:
                    auth = decoded.decode("utf-8")
                except UnicodeDecodeError:
                    fail("SOCKS 认证 Base64 无效")
                if ":" not in auth:
                    fail("SOCKS 认证缺少密码")
                username, password = auth.split(":", 1)
        if bool(username) != bool(password):
            fail("SOCKS 用户名和密码不能只填一个")
        # 字面 / 只允许出现在 Base64 认证串; 普通认证串须用 %2F 编码,
        # 保持旧实现按第一个 / 切 path 的拒绝行为。
        if not b64_auth and "/" in userinfo:
            fail("SOCKS 链接不能包含路径")
    settings = {"address": server, "port": port}
    if username:
        settings["user"] = username
        settings["pass"] = password
    outbound = {"protocol": "socks", "settings": settings}
    return result(tag_from_fragment(fragment), "socks", server, port, outbound)


def mport_normalize(raw):
    if not raw:
        fail("mport 不能为空")
    out = []
    for item in raw.split(","):
        item = item.replace(" ", "")
        if not item:
            fail("mport 包含空范围")
        if "-" in item:
            match = re.fullmatch(r"([0-9]{1,5})-([0-9]{1,5})", item)
            if not match:
                fail("mport 范围格式无效")
            first, last = match.group(1), match.group(2)
        elif ":" in item:
            match = re.fullmatch(r"([0-9]{1,5}):([0-9]{1,5})", item)
            if not match:
                fail("mport 范围格式无效")
            first, last = match.group(1), match.group(2)
        else:
            if not re.fullmatch(r"[0-9]{1,5}", item):
                fail("mport 端口必须是十进制整数")
            first = last = item
        first, last = int(first, 10), int(last, 10)
        if not (1 <= first <= 65535 and 1 <= last <= 65535):
            fail("mport 端口须在 1-65535")
        if first > last:
            first, last = last, first
        out.append(str(first) if first == last else "%d-%d" % (first, last))
    if not out:
        fail("mport 不能为空")
    return ",".join(out)


def brutal_rate_valid(value, required=False):
    if not value:
        return not required
    match = re.fullmatch(
        r"[ \t]*([0-9]+(?:[.][0-9]*)?|[.][0-9]+)[ \t]*([a-z]*)[ \t]*",
        value.lower(),
    )
    if not match:
        return False
    rate = float(match.group(1))
    multiplier = {
        "": 1, "b": 1, "bps": 1,
        "k": 1024, "kb": 1024, "kbps": 1024,
        "m": 1048576, "mb": 1048576, "mbps": 1048576,
        "g": 1073741824, "gb": 1073741824, "gbps": 1073741824,
        "t": 1099511627776, "tb": 1099511627776, "tbps": 1099511627776,
    }.get(match.group(2))
    if multiplier is None:
        return False
    bps = int(rate * multiplier) // 8
    return bps >= 65536 or (rate == 0 and not required)


def bandwidth_value(value, label):
    raw = value.lower().strip()
    match = re.fullmatch(r"([0-9]+(?:[.][0-9]*)?|[.][0-9]+)[ \t]*([a-z]*)", raw)
    if not match:
        fail(label + "格式无效，应为 100、0.5 或 100 mbps")
    number = match.group(1)
    unit = match.group(2) or "mbps"
    if unit not in ("b", "bps", "k", "kb", "kbps", "m", "mb", "mbps", "g", "gb", "gbps", "t", "tb", "tbps"):
        fail(label + "单位无效")
    if not brutal_rate_valid(number + " " + unit, False):
        fail(label + "非零时至少 512 kbps (0.5 mbps)")
    if float(number) == 0:
        return ""
    return number + " " + unit


def obfs_size_canon(raw):
    raw = raw.replace(" ", "")
    if not raw:
        return ""
    if re.fullmatch(r"[0-9]+-[0-9]+", raw):
        first, last = raw.split("-", 1)
    elif re.fullmatch(r"[0-9]+", raw):
        first = last = raw
    else:
        fail("Gecko packetSize 规范化失败")
    if len(first) > 10 or len(last) > 10:
        fail("Gecko packetSize 规范化失败")
    first, last = int(first, 10), int(last, 10)
    if first > last:
        first, last = last, first
    return str(first) if first == last else "%d-%d" % (first, last)


def parse_hysteria2(link):
    url = split_url(link)
    if url["scheme"] not in ("hysteria2", "hy2"):
        fail("不是 Hysteria2 链接")
    if not url["userinfo"]:
        fail("Hysteria2 链接缺少密码")
    password = percent_decode(url["userinfo"])
    if not password:
        fail("Hysteria2 密码不能为空")
    if url["path"] not in ("", "/"):
        fail("Hysteria2 链接路径无效")
    server, port_raw = parse_hostport(url["hostport"])
    port = validate_port(port_raw) if port_raw else 443
    query = Query(url["query"])
    check_query(query, (
        "sni", "peer", "servername", "insecure", "allowinsecure", "skip-cert-verify",
        "obfs", "obfs-password", "obfs_password", "obfspassword", "minpacketsize",
        "maxpacketsize", "mport", "alpn", "up", "down", "upmbps", "downmbps",
        "pinsha256", "pcs", "pinnedpeercertsha256", "pin-sha256", "pin_sha256",
        "vcn", "verifypeercertbyname", "ech", "udpidletimeout", "fp", "congestion",
    ))
    if query.get("fp") is not None:
        fail("Hysteria2 是 QUIC 传输，不支持 fp/uTLS 指纹")
    security_settings, sni = build_tls_settings("tls", server, query)

    masks = []
    obfs = query.get("obfs")
    if obfs is not None:
        obfs = obfs.lower()
        if obfs not in ("salamander", "gecko"):
            fail("Hysteria2 混淆只支持 salamander/gecko")
        obfs_password = alias_get(
            query, "Hysteria2 混淆密码",
            ("obfs-password", "obfs_password", "obfspassword"),
        )
        if obfs_password is None:
            fail("Hysteria2 启用混淆时必须提供 obfs-password")
        if not obfs_password:
            fail("Hysteria2 混淆密码不能为空")
        low = int_get(query, "Gecko 最小包长", 1, 2048, ("minpacketsize",))
        high = int_get(query, "Gecko 最大包长", 1, 2048, ("maxpacketsize",))
        size = ""
        if obfs == "salamander":
            if low is not None or high is not None:
                fail("minPacketSize/maxPacketSize 只适用于 Gecko")
        else:
            low = 512 if low is None else low
            high = 1200 if high is None else high
            if low > high:
                fail("Gecko 最小包长不能大于最大包长")
            size = obfs_size_canon("%d-%d" % (low, high))
        settings = {"password": obfs_password}
        if size:
            settings["packetSize"] = size
        masks.append({"type": "salamander", "settings": settings})
    else:
        if query.any(("obfs-password", "obfs_password", "obfspassword", "minpacketsize", "maxpacketsize")):
            fail("Hysteria2 链接包含混淆参数，但没有 obfs 类型")

    mport = query.get("mport")
    if mport is not None:
        masks.insert(0, {
            "type": "udphop",
            "settings": {"mode": "perconnremote", "remotePorts": mport_normalize(mport)},
        })

    up = alias_get(query, "上行带宽", ("up", "upmbps"))
    down = alias_get(query, "下行带宽", ("down", "downmbps"))
    # 拥塞控制由本工具导出的链接携带(hy2://...&congestion=...), 必须能原样导入。
    congestion = query.get("congestion")
    if congestion is not None:
        congestion = congestion.lower()
        if congestion not in ("reno", "bbr", "brutal", "force-brutal"):
            fail("Hysteria2 congestion 只支持 reno/bbr/brutal/force-brutal")
    quic = None
    # 显式 congestion 优先保留: up=0&down=0 时也要带上拥塞控制语义。
    if congestion is not None:
        quic = {"congestion": congestion}
    if up is not None and down is not None:
        up_value = bandwidth_value(up, "Hysteria2 up")
        down_value = bandwidth_value(down, "Hysteria2 down")
        if up_value or down_value:
            if quic is None:
                quic = {"congestion": "brutal"}
            # brutal 系才有上下行限速; bbr/reno 下带宽字段没有意义。
            if quic["congestion"] in ("brutal", "force-brutal"):
                if up_value:
                    quic["brutalUp"] = up_value
                if down_value:
                    quic["brutalDown"] = down_value
    elif up is not None or down is not None:
        fail("Hysteria2 的 up/down 必须同时提供")

    udp_idle = int_get(query, "Hysteria2 udpIdleTimeout", 0, 600, ("udpidletimeout",))
    if udp_idle == 1:
        fail("Hysteria2 udpIdleTimeout 只能为 0(默认) 或 2-600")
    if udp_idle == 0:
        udp_idle = None

    finalmask = None
    if masks or quic is not None:
        finalmask = {}
        if masks:
            finalmask["udp"] = masks
        if quic is not None:
            finalmask["quicParams"] = quic

    hysteria_settings = {"version": 2, "auth": password}
    if udp_idle is not None:
        hysteria_settings["udpIdleTimeout"] = udp_idle
    stream = {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": security_settings,
        "hysteriaSettings": hysteria_settings,
    }
    if finalmask is not None:
        stream["finalmask"] = finalmask
    outbound = {
        "protocol": "hysteria",
        "settings": {"version": 2, "address": server, "port": port},
        "streamSettings": stream,
    }
    return result(tag_from_fragment(url["fragment"]), "hysteria2", server, port, outbound)


def parse_link(link):
    if not link:
        fail("分享链接不能为空")
    if has_control(link):
        fail("分享链接不能包含换行或控制字符")
    if "://" not in link:
        fail("无法识别分享链接协议")
    scheme = link.split("://", 1)[0].lower()
    link = scheme + "://" + link.split("://", 1)[1]
    if scheme in ("hysteria2", "hy2"):
        return parse_hysteria2(link)
    if scheme == "vless":
        return parse_vless(link)
    if scheme == "vmess":
        return parse_vmess(link)
    if scheme == "trojan":
        return parse_trojan(link)
    if scheme == "ss":
        return parse_ss(link)
    if scheme in ("socks", "socks5"):
        return parse_socks(link)
    if scheme in (
        "anytls", "tuic", "hysteria", "shadowtls", "naive+https", "ssr",
        "trojan-go", "http", "https",
    ):
        fail("暂不支持 %s:// 链接；当前支持 %s" % (scheme, SUPPORTED_TEXT))
    fail("无法识别分享链接协议；当前支持 " + SUPPORTED_TEXT)


def append_link(links, value):
    value = value.strip(SEPARATORS)
    if value:
        links.append(value)


def split_line_links(line):
    links = []
    rest = line
    current = ""
    while rest:
        match = SCHEME_RE.search(rest)
        if match:
            scheme = match.group(0)
            before = rest[:match.start()]
            if current:
                append_link(links, current + before)
            elif before:
                append_link(links, before)
            current = scheme
            rest = rest[match.end():]
        else:
            current += rest
            rest = ""
    append_link(links, current)
    return links


def collect_links(text):
    links = []
    text = text.lstrip("\ufeff")
    depth = 0
    while True:
        compact = "".join(text.split())
        if not compact:
            fail("分享链接不能为空")
        if "://" in compact:
            break
        # 允许 v2rayN 的整段 Base64，最多嵌套三层。
        if depth >= 3:
            fail("Base64 分享链接嵌套层数过多")
        decoded = base64_decode(compact)
        if decoded is None:
            fail("Base64 内容无法解码")
        try:
            text = decoded.decode("utf-8")
        except UnicodeDecodeError:
            fail("Base64 内容不是分享链接")
        if "://" not in text:
            fail("Base64 内容不是分享链接")
        depth += 1
    text = text.replace("\r\n", "\n").replace("\r", "\n").replace("，", "\n").replace("；", "\n")
    for line in text.split("\n"):
        if line:
            links.extend(split_line_links(line))
    if not links:
        fail("分享链接不能为空")
    return links


def parse_batch(text):
    links = collect_links(text)
    parsed = []
    skipped = []
    for index, link in enumerate(links, 1):
        try:
            parsed.append(parse_link(link))
        except ParseError as error:
            if len(links) == 1:
                fail("第 %d 条: %s" % (index, error))
            skipped.append({"index": index, "error": str(error)})
    if not parsed:
        fail("没有可导入的有效链接")
    return {"links": parsed, "skipped": skipped}


def main(argv):
    # 支持 --batch <link...> 或从 stdin 读取；--batch 仅用于和其他脚本保持同一调用约定。
    args = list(argv[1:])
    if args and args[0] == "--batch":
        args = args[1:]
    if args:
        text = "\n".join(args)
    else:
        text = sys.stdin.read()
    try:
        payload = parse_batch(text)
    except ParseError as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        return 1
    except Exception as error:  # pragma: no cover - 防御未预期输入
        print(json.dumps({"error": "解析器内部错误: %s" % error}, ensure_ascii=False))
        return 1
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
