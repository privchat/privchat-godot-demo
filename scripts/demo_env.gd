# demo_env.gd — 共享开发环境的连接参数,所有入口都从这里取。
#
# privchat-sdk 自 `feat(transport): require a pinned server identity` 起,
# 没有 SPKI pin 就**拒绝**建立 tcp:// / quic:// 连接(tcp:// 是 TLS-only,
# 不会退回明文)。于是 pin 与网关地址成了一对绑定的值:换网关就得换 pin,
# 分散写在各脚本里迟早对不上。
extends RefCounted

## IM 网关:共享开发实例,privchat-application(:8080)的鉴权链绑在它上面。
##
## 别想着改指另一个带 TLS 的实例:token 由 8080 经 9001 签发,换实例后
## authenticate 会直接 `10001 Token 验证失败`,两者的签名密钥不通用。
##
## 连不上且报 `tls handshake eof`,说明这个端口上的 server 进程早于 TLS
## 支持启动、还在讲明文,重启它即可,不是这里的 pin 配错了。
const DEFAULT_GATEWAY_HOST := "127.0.0.1"
const DEFAULT_GATEWAY_PORT := 9001
## service admin API,须与网关同实例(房间创建、签票、广播都走它)。
const DEFAULT_SERVICE_API := "http://127.0.0.1:9090"

## 上述网关的服务端证书 pin,base64(sha256(SubjectPublicKeyInfo))。
## 取自 privchat-server/certs/server.crt,即 9001 重启后会用的那张。
##
## 公钥哈希不是机密,可以进仓库。换证书后重新取值:
##   openssl x509 -in <cert> -pubkey -noout \
##     | openssl pkey -pubin -outform der \
##     | openssl dgst -sha256 -binary | openssl base64
##
## pin 绑的是**公钥**而非整张证书,同一密钥换发证书不会让 pin 失效。
## PackedStringArray(...) 不是常量表达式,这里存 Array,取用时再转。
const DEFAULT_SPKI_PINS := [
	"W/B9OyO/XxgkrUAVXNeQYKSZrq3eE0O4pNBJg/UAu1E=",
]


static func gateway_host() -> String:
	var v := OS.get_environment("PRIVCHAT_HOST").strip_edges()
	return v if not v.is_empty() else DEFAULT_GATEWAY_HOST


static func gateway_port() -> int:
	var v := OS.get_environment("PRIVCHAT_PORT").strip_edges()
	return int(v) if v.is_valid_int() else DEFAULT_GATEWAY_PORT


static func service_api() -> String:
	var v := OS.get_environment("PRIVCHAT_SERVICE_API").strip_edges()
	return v if not v.is_empty() else DEFAULT_SERVICE_API


## 服务端换密钥后不必改代码:`PRIVCHAT_SPKI_PIN` 覆盖内置值。
static func spki_pins() -> PackedStringArray:
	var override := OS.get_environment("PRIVCHAT_SPKI_PIN").strip_edges()
	if not override.is_empty():
		return PackedStringArray([override])
	return PackedStringArray(DEFAULT_SPKI_PINS)


## 建一个已配好网关与 pin 的 client。所有入口都应经由此处,免得新增脚本时
## 漏配,又收到一句看着像网络故障的报错。
static func make_client() -> PrivchatClient:
	var client := PrivchatClient.new()
	client.server_host = gateway_host()
	client.server_port = gateway_port()
	client.spki_pins = spki_pins()
	return client
