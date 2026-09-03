# mmo_scene_service.gd — 业务层示例:MMORPG 场景通道(module-mmorpg 对接)。
#
# 与 game_service.gd 同一原则:addon 只给传输原语(订阅 + transfer),
# "场景 / 角色 / 心跳"全是业务层的事。契约见 privchat-docs 的
# MMO_WORLD_SCENE_SPEC §12(已实装部分):
#
#   HTTP   POST /app/mmo/scene/{scene_ref}/enter      → channel_id + ticket + scene_session_id
#   HTTP   POST /app/mmo/scene/{scene_ref}/leave
#   HTTP   GET  /app/mmo/scene/{scene_ref}/snapshot
#   HTTP   GET  /app/mmo/scene/{scene_ref}/roles/{role_id}/private-snapshot   (重连恢复)
#   Transfer  mmorpg/scene/heartbeat  { protocol_version, scene_session_id, request_id, client_time_ms }
#   Room publish  topic mmorpg.scene.public  { event: scene.role_entered | scene.role_left, role_id, seq, ... }
#
# 服务端的鉴权依据是 scene_session_id:客户端不自报角色与场景。
class_name DemoMmoSceneService
extends Node

const PROTOCOL_VERSION := 1
const TOPIC_PUBLIC := "mmorpg.scene.public"
const ROUTE_HEARTBEAT := "mmorpg/scene/heartbeat"

## 场景公共事件(已去重)。event 是 "scene.role_entered" / "scene.role_left"。
signal presence(event: String, role_id: int, role_name: String, seq: int, raw: Dictionary)
## 重连后自动重订阅的结果。
signal rejoined(ok: bool, error: String)

var client: PrivchatClient = null
var sub: PrivchatSubscription = null
var app_base: String = "http://127.0.0.1:8080/app"
var access_token: String = ""

var role_id: int = 0
var scene_ref: String = ""
var channel_id: int = 0
var scene_session_id: int = 0
var session_epoch: int = 0
var last_public_seq: int = 0

var _next_request: int = 1


func setup(p_client: PrivchatClient, p_access_token: String) -> void:
	client = p_client
	access_token = p_access_token
	sub = PrivchatSubscription.new()
	add_child(sub)
	sub.setup(client)
	sub.message_received.connect(_on_message)
	sub.resubscribed.connect(func(ok, err): rejoined.emit(ok, err))


func close() -> void:
	if sub != null:
		await sub.close()
		sub = null
	queue_free()


# --- 角色 -----------------------------------------------------------------

## 取第一个角色,没有就建一个。角色名全服唯一,所以带上 user_id。
func ensure_role(name_hint: String) -> Dictionary:
	var listed: Dictionary = await _app("GET", "/mmo/roles")
	if not listed.ok:
		return listed
	var roles: Array = listed.data if typeof(listed.data) == TYPE_ARRAY else []
	if not roles.is_empty():
		role_id = int(roles[0].role_id)
		return { "ok": true, "data": roles[0], "error": "" }
	var created: Dictionary = await _app("POST", "/mmo/roles", { "name": name_hint })
	if created.ok:
		role_id = int(created.data.role_id)
	return created


# --- 场景生命周期 -----------------------------------------------------------

## enter 拿到 channel + ticket + scene_session,并立刻订阅 Room。
func enter(p_scene_ref: String, device_id: String) -> Dictionary:
	var resp: Dictionary = await _app("POST", "/mmo/scene/%s/enter" % p_scene_ref,
			{ "role_id": role_id, "device_id": device_id })
	if not resp.ok:
		return resp
	scene_ref = p_scene_ref
	channel_id = int(resp.data.channel_id)
	scene_session_id = int(resp.data.scene_session_id)
	session_epoch = int(resp.data.session_epoch)
	if sub.is_subscribed() and sub.channel_id != channel_id:
		await sub.unsubscribe()
	if not sub.is_subscribed():
		var joined: Dictionary = await sub.subscribe(channel_id, str(resp.data.ticket))
		if not joined.ok:
			return { "ok": false, "data": resp.data, "error": "subscribe: %s" % joined.error, "code": -1 }
	return resp


func leave() -> Dictionary:
	var resp: Dictionary = await _app("POST", "/mmo/scene/%s/leave" % scene_ref, { "role_id": role_id })
	if sub.is_subscribed():
		await sub.unsubscribe()
	if resp.ok:
		scene_session_id = 0
	return resp


func public_snapshot() -> Dictionary:
	return await _app("GET", "/mmo/scene/%s/snapshot" % scene_ref)


## 断线重连的恢复入口:拿回 scene_session_id 与序号基线。
func private_snapshot() -> Dictionary:
	return await _app("GET", "/mmo/scene/%s/roles/%d/private-snapshot" % [scene_ref, role_id])


# --- 心跳 -------------------------------------------------------------------

## 返回 { ok, code, data: { scene_session_id, server_time_ms, public_scene_seq }, error }。
func heartbeat(session_override: int = 0) -> Dictionary:
	return await transfer(ROUTE_HEARTBEAT, {
		"protocol_version": PROTOCOL_VERSION,
		"scene_session_id": session_override if session_override != 0 else scene_session_id,
		"client_time_ms": int(Time.get_unix_time_from_system() * 1000.0),
	})


## 任意 mmorpg/<域>/<动作> transfer;request_id 是字符串幂等键(spec §9.2,≤64 字节)。
func transfer(route: String, payload: Dictionary, timeout_ms: int = 8000) -> Dictionary:
	if sub == null or not sub.is_subscribed():
		return { "ok": false, "code": -1, "data": {}, "error": "not in a scene" }
	var body := payload.duplicate()
	body["request_id"] = "gd-%d-%d" % [role_id, _next_request]
	_next_request += 1
	var resp: Dictionary = await client.transfer(sub.channel_id, route, body, timeout_ms)
	return _parse_transfer(resp)


func _parse_transfer(resp: Dictionary) -> Dictionary:
	var out := { "ok": false, "code": -1, "data": {}, "error": resp.get("error", "") }
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
		out.data = parsed if typeof(parsed) == TYPE_DICTIONARY else { "raw": data }
	return out


# --- 事件 -------------------------------------------------------------------

func _on_message(payload_text: String, _bytes: PackedByteArray, _topic: String,
		_publisher: String, _sid: int, _ts: int) -> void:
	var parsed = JSON.parse_string(payload_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	if str(parsed.get("topic", "")) != TOPIC_PUBLIC:
		return
	var seq := int(parsed.get("seq", 0))
	# seq 回退 = 服务端序列重置(重启/多实例),客户端约定丢弃增量拉 snapshot;
	# 这里只记录基线,由业务决定何时拉。
	last_public_seq = seq
	presence.emit(str(parsed.get("event", "")), int(parsed.get("role_id", 0)),
			str(parsed.get("role_name", "")), seq, parsed)


# --- HTTP -------------------------------------------------------------------

## 应用路由(Bearer 认证)。返回 { ok, code, data, error }:业务错误码原样透出
## (21600-21610),与 transfer 路径同一套数字。
func _app(method: String, path: String, body = null) -> Dictionary:
	var req := HTTPRequest.new()
	add_child(req)
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % access_token,
	])
	var m := HTTPClient.METHOD_GET if method == "GET" else HTTPClient.METHOD_POST
	var payload := "" if body == null else JSON.stringify(body)
	var err: int = req.request(app_base + path, headers, m, payload)
	if err != OK:
		req.queue_free()
		return { "ok": false, "code": -1, "data": null, "error": "http request error %d" % err }
	var resp: Array = await req.request_completed
	req.queue_free()
	var parsed = JSON.parse_string(resp[3].get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return { "ok": false, "code": int(resp[1]), "data": null, "error": "non-JSON response (http %d)" % int(resp[1]) }
	var code := int(parsed.get("code", -1))
	return { "ok": code == 0, "code": code, "data": parsed.get("data"), "error": str(parsed.get("message", "")) }
