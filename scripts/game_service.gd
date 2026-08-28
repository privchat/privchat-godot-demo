# game_service.gd — 业务层示例:游戏指令通道。
#
# 这是 **demo(业务层)** 的代码,不属于 privchat-godot addon —— addon 只提供
# 传输原语(PrivchatSubscription 订阅 + PrivchatClient.transfer/rpc_call),
# 不认识"游戏"这个概念。本文件演示业务层如何把原语组合成自己的玩法通道:
#
#   - 收:PrivchatSubscription(订阅频道、重连自动重订阅、按 id 去重)
#   - 发:client.transfer(...) 并自注入 request_id 作幂等键
#         —— 幂等键是**业务约定**,不同游戏可以自定,故不放进 SDK
#
# 非实时业务(背包、任务、商城等)更适合直接 HTTP 调 privchat-application
# 的模块路由,不必走这条实时通道。
class_name DemoGameService
extends Node

## 服务端游戏广播(已去重)。payload_text 通常是 JSON 文本,由业务自行解析。
signal game_event(payload_text: String, payload_bytes: PackedByteArray,
		topic: String, publisher: String, server_message_id: int, timestamp: int)
## 重连后自动重订阅的结果;失败(如票据过期)由业务重新签票再 join。
signal rejoined(ok: bool, error: String)

var client: PrivchatClient = null
var sub: PrivchatSubscription = null

var _next_request_id: int = 1


func setup(p_client: PrivchatClient) -> void:
	client = p_client
	sub = PrivchatSubscription.new()
	add_child(sub)
	sub.setup(client)
	sub.message_received.connect(_on_message)
	sub.resubscribed.connect(func(ok, err): rejoined.emit(ok, err))


func close(timeout_ms: int = 5000) -> void:
	if sub != null:
		await sub.close()
		sub = null
	queue_free()


var game_channel_id: int:
	get: return sub.channel_id if sub != null else 0


# --- 频道生命周期 -----------------------------------------------------------

func join(channel_id: int, ticket: String) -> Dictionary:
	return await sub.subscribe(channel_id, ticket)


func leave() -> Dictionary:
	return await sub.unsubscribe()


# --- 指令与 RPC -------------------------------------------------------------

## Channel Transfer 游戏指令。route 为 service/module/action 三段
## (如 "game/room/heartbeat");payload 自动注入 request_id 幂等键。
## 返回 { ok, code, data: Dictionary, error, request_id }。
func send_command(route: String, payload: Dictionary = {},
		timeout_ms: int = 8000) -> Dictionary:
	if sub == null or not sub.is_subscribed():
		return { "ok": false, "code": -1, "data": {}, "error": "not joined", "request_id": 0 }
	var request_id := _next_request_id
	_next_request_id += 1
	var body := payload.duplicate()
	body["request_id"] = request_id
	var resp: Dictionary = await client.transfer(
			sub.channel_id, route, body, timeout_ms)
	return _parse_transfer(resp, request_id)


## 全局 RPC 透传(名字避开 Node 内建 rpc())。返回 { ok, data: Dictionary, error }。
func call_rpc(route: String, body: Dictionary = {}, timeout_ms: int = 8000) -> Dictionary:
	var resp: Dictionary = await client.rpc_call(route, body, timeout_ms)
	return {
		"ok": resp.ok,
		"data": resp.data if typeof(resp.data) == TYPE_DICTIONARY else {},
		"error": resp.get("error", ""),
	}


## transfer 信封:{"request_id","channel_id","code","message","data"}。
## 信封已由 native 层解析成 Dictionary;信封内的 data 是服务端业务载荷
## (协议层面是字节),UTF-8 JSON 时在这里解析成对象。
func _parse_transfer(resp: Dictionary, request_id: int) -> Dictionary:
	var out := { "ok": false, "code": -1, "data": {}, "error": resp.get("error", ""),
			"request_id": request_id }
	if not resp.ok:
		return out
	var envelope = resp.data
	if typeof(envelope) != TYPE_DICTIONARY:
		out.error = "bad transfer envelope: %s" % str(envelope)
		return out
	out.code = int(envelope.get("code", -1))
	out.ok = out.code == 0
	if not out.ok:
		out.error = str(envelope.get("message", "transfer error"))
	var data = envelope.get("data", "")
	if typeof(data) == TYPE_STRING and not String(data).is_empty():
		var parsed = JSON.parse_string(data)
		if typeof(parsed) == TYPE_DICTIONARY:
			out.data = parsed
		else:
			out.data = { "raw": data }
	return out


func _on_message(payload_text: String, payload_bytes: PackedByteArray,
		topic: String, publisher: String, server_message_id: int,
		timestamp: int) -> void:
	game_event.emit(payload_text, payload_bytes, topic, publisher,
			server_message_id, timestamp)
