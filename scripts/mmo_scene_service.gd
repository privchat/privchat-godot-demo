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
# 战斗(MMO_BATTLE_PROTOCOL_SPEC §15,JSON 镜像 battle_*.fbs):
#   HTTP   POST /app/mmo/scene/{scene_ref}/roles/{role_id}/battles {npc_id, device_id} → transition/battle/channel/ticket
#   HTTP   GET  /app/mmo/battle/{battle_id}/roles/{role_id}/private-snapshot            (open_slots 在这里)
#   Transfer  mmorpg/battle/command  BattleCommandEnvelope → BattleCommandAck
#   Transfer  mmorpg/battle/instant  { op: SURRENDER, state_version }
#   Room publish  topic mmorpg.battle.public  BattleEventBatchEnvelope
#
# 服务端的鉴权依据是 scene_session_id:客户端不自报角色与场景。
class_name DemoMmoSceneService
extends Node

## 线格式一律 FlatBuffers(MMO_ARCHITECTURE_SPEC §10.6):route/topic ↔ root 对照见
## module-mmorpg/protocol/README.md;编解码由 privchat-godot 的通用反射 codec 完成,
## .bfbs 按摘要固定在 protocol/bfbs/(GODOT_FLATBUFFERS_CODEC_SPEC §7)。
const NS_SCENE := "privchat.mmorpg.scene."
const NS_BATTLE := "privchat.mmorpg.battle."

const PROTOCOL_VERSION := 1
const TOPIC_PUBLIC := "mmorpg.scene.public"
const ROUTE_HEARTBEAT := "mmorpg/scene/heartbeat"
const ROUTE_MOVE := "mmorpg/scene/move"
const ROUTE_INTERACT := "mmorpg/scene/interact"
const ROUTE_BATTLE_COMMAND := "mmorpg/battle/command"
const ROUTE_BATTLE_INSTANT := "mmorpg/battle/instant"
const TOPIC_BATTLE_PUBLIC := "mmorpg.battle.public"
const ROUTE_BATTLE_EVENT := "mmorpg/battle/event"

## 定点坐标:1 = 1/1000 世界单位,原点左上,+x 右 +y 下;三端一律向零取整。
const FIXED := 1000

## 场景公共事件(已去重)。event 是 "scene.role_entered" / "scene.role_left"。
signal presence(event: String, role_id: int, role_name: String, seq: int, raw: Dictionary)
## 一段权威移动开始(MovementStarted 的 JSON 镜像)。客户端沿同一路径本地插值。
signal movement_started(entity_id: int, movement: Dictionary, seq: int)
## 重连后自动重订阅的结果。
signal rejoined(ok: bool, error: String)
## 战斗 PUBLIC 事件(BattleEventBatchEnvelope 里的一条 BattleEvent;已按 stream_seq 去重)。
## payload 是单键对象:phase_changed / initiative_resolved / damage_dealt / actor_died / battle_settled。
signal battle_event(battle_id: int, event: Dictionary, stream_seq: int)
## 战斗 PRIVATE 事件(服务端定向 transfer,route mmorpg/battle/event;已按 stream_seq 去重)。
## payload:slots_offered(可提交的行动机会)/ command_accepted。
signal battle_private_event(battle_id: int, event: Dictionary, stream_seq: int)

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

## 本角色已发出的最大 movement_seq;Stop 也占用新值(spec §4.1.1)。
var movement_seq: int = 0

var _next_request: int = 1

## 通用 FlatBuffers codec 与各 root 的 schema handle(按 .bfbs 文件名索引)。
var codec = null
var schemas: Dictionary = {}

# --- 战斗状态(§7.2 过渡期双订阅:场景 Room 不退,战斗 Room 另开一条订阅)---
var battle_sub: PrivchatSubscription = null
var battle_id: int = 0
var battle_channel_id: int = 0
var transition_id: int = 0
var battle_public_seq: int = 0
var battle_private_seq: int = 0
## (battle_id, actor_id) 内递增的 action_seq;被拒的提交不占用。
var action_seq: int = 0


func setup(p_client: PrivchatClient, p_access_token: String) -> void:
	client = p_client
	access_token = p_access_token
	sub = PrivchatSubscription.new()
	add_child(sub)
	sub.setup(client)
	sub.message_received.connect(_on_message)
	sub.resubscribed.connect(func(ok, err): rejoined.emit(ok, err))
	_load_schemas()


## 加载并按摘要固定 .bfbs;摘要不符即拒绝,不允许"差不多的协议"跑起来。
func _load_schemas() -> void:
	codec = PrivchatFlatBuffers.new()
	var sums := FileAccess.get_file_as_string("res://protocol/bfbs/SHA256SUMS")
	for name in ["scene_heartbeat_request", "scene_heartbeat_ack", "scene_move_intent", "scene_move_ack",
			"scene_interact_request", "scene_interact_ack", "scene_event",
			"battle_command", "battle_command_ack", "battle_instant_request", "battle_instant_ack", "battle_event"]:
		var r: Dictionary = codec.load_schema(FileAccess.get_file_as_bytes("res://protocol/bfbs/%s.bfbs" % name))
		if not r.ok:
			push_error("load %s.bfbs: %s" % [name, r.error])
			continue
		if not sums.contains(str(r.schema.get_digest())):
			push_error("%s.bfbs digest %s is not pinned" % [name, r.schema.get_digest()])
			continue
		schemas[name] = r.schema


func _encode(schema_name: String, root: String, value: Dictionary) -> PackedByteArray:
	var r: Dictionary = codec.encode(schemas[schema_name], root, value)
	if not r.ok:
		push_error("encode %s: %s" % [root, r.error])
		return PackedByteArray()
	return r.data


func _decode(schema_name: String, root: String, bytes: PackedByteArray) -> Dictionary:
	return codec.decode(schemas[schema_name], bytes, root)


func close() -> void:
	await leave_battle()
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
	# 64 位 id 以字符串传输(超过 2^53 的 JSON 数字在 GDScript 里会丢精度)。
	channel_id = int(str(resp.data.channel_id))
	scene_session_id = int(resp.data.scene_session_id)
	session_epoch = int(resp.data.session_epoch)
	movement_seq = 0   # 序号作用域是 scene_session(spec §9.2)
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


# --- 移动 -------------------------------------------------------------------

## 点击寻路:发意图,不发坐标帧。返回 { ok, code, data: MoveIntentAck, error }。
## 拒绝(21603 越界 / 21605 序号迟到 / 21606 幂等冲突)走外层 code,data 为空。
func move_to(x: int, y: int) -> Dictionary:
	movement_seq += 1
	return await _move({ "move_to": { "target_position": { "x": x, "y": y } } })


## 就地停下。同样占用新的 movement_seq。
func stop() -> Dictionary:
	movement_seq += 1
	return await _move({ "stop": {} })


func _move(command: Dictionary) -> Dictionary:
	var resp := await transfer_fb(ROUTE_MOVE, "scene_move_intent", NS_SCENE + "MoveIntentEnvelope", {
		"protocol_version": PROTOCOL_VERSION,
		"scene_session_id": scene_session_id,
		"movement_seq": movement_seq,
		"command": command,
		"client_time_ms": int(Time.get_unix_time_from_system() * 1000.0),
	}, "scene_move_ack", NS_SCENE + "MoveIntentAck")
	return resp


## 按服务端的路径参数推算 t 时刻(服务端时钟,Unix ms)的位置:从起点沿点列逐段
## 匀速走,走完停在最后一点。与服务端同一套整数算法、向零取整,两端算出同一个点。
static func position_on_path(movement: Dictionary, server_now_ms: int) -> Vector2i:
	var start: Dictionary = movement.get("authoritative_start_position", {})
	var from := Vector2i(int(start.get("x", 0)), int(start.get("y", 0)))
	var points: Array = movement.get("path_points", [])
	var speed := int(movement.get("speed", 0))
	if points.is_empty() or speed <= 0:
		return from
	var elapsed: int = maxi(server_now_ms - int(movement.get("start_time_ms", 0)), 0)
	@warning_ignore("integer_division")
	var travelled: int = speed * elapsed / 1000
	for pt in points:
		var to := Vector2i(int(pt.get("x", from.x)), int(pt.get("y", from.y)))
		var dx := to.x - from.x
		var dy := to.y - from.y
		var seg := _isqrt(dx * dx + dy * dy)
		if travelled < seg:
			@warning_ignore("integer_division")
			return Vector2i(from.x + dx * travelled / seg, from.y + dy * travelled / seg)
		travelled -= seg
		from = to
	return from


static func _isqrt(n: int) -> int:
	if n <= 0:
		return 0
	var x := n
	@warning_ignore("integer_division")
	var y := (x + 1) / 2
	while y < x:
		x = y
		@warning_ignore("integer_division")
		y = (x + n / x) / 2
	return x


# --- NPC 交互 ---------------------------------------------------------------

## 与 NPC 交互。在不在交互距离内由服务端按权威位置判:不在 → 21612;不存在 → 21611。
## 返回 { ok, code, data: { npc_id, name, kind, dialog, options }, error }。
func interact(npc_id: int) -> Dictionary:
	return await transfer_fb(ROUTE_INTERACT, "scene_interact_request", NS_SCENE + "InteractRequest", {
		"protocol_version": PROTOCOL_VERSION,
		"scene_session_id": scene_session_id,
		"npc_id": npc_id,
	}, "scene_interact_ack", NS_SCENE + "InteractAck")


## 地图静态数据(格子、阻挡、出生点),进场景后按 snapshot 的 map_id 拉一次。
func fetch_map(map_id: int) -> Dictionary:
	return await _app("GET", "/mmo/maps/%d" % map_id)


# --- 战斗 -------------------------------------------------------------------

## 从场景发起 PvE 战斗(NPC 的 interact options 含 "battle")。成功后订阅战斗 Room;
## 场景 Room 保持订阅(§7.2)。返回 { ok, code, data: BattleEntryResponse, error }。
func start_battle(npc_id: int, device_id: String) -> Dictionary:
	var resp: Dictionary = await _app("POST", "/mmo/scene/%s/roles/%d/battles" % [scene_ref, role_id],
			{ "npc_id": npc_id, "device_id": device_id })
	if not resp.ok:
		return resp
	return await _join_battle(resp)


## 断线后凭 transition_id 续接(§15.1)。
func resume_battle(p_transition_id: int) -> Dictionary:
	var resp: Dictionary = await _app("GET", "/mmo/battles/transitions/%d" % p_transition_id)
	if not resp.ok:
		return resp
	if str(resp.data.status) != "READY":
		return { "ok": false, "code": -1, "data": resp.data, "error": "transition %s" % str(resp.data.status) }
	return await _join_battle(resp)


func _join_battle(resp: Dictionary) -> Dictionary:
	transition_id = int(resp.data.transition_id)
	battle_id = int(resp.data.battle_id)
	battle_channel_id = int(str(resp.data.channel_id))
	battle_public_seq = 0
	battle_private_seq = 0
	action_seq = 0
	if battle_sub == null:
		battle_sub = PrivchatSubscription.new()
		add_child(battle_sub)
		battle_sub.setup(client)
		battle_sub.message_received.connect(_on_battle_message)
		battle_sub.transfer_received.connect(_on_battle_transfer)
	if battle_sub.is_subscribed():
		await battle_sub.unsubscribe()
	var joined: Dictionary = await battle_sub.subscribe(battle_channel_id, str(resp.data.ticket))
	if not joined.ok:
		return { "ok": false, "data": resp.data, "error": "subscribe battle: %s" % joined.error, "code": -1 }
	return resp


## 退订战斗 Room。退出战斗的正路是:BattleSettled 后**先**重新 enter 场景(epoch+1),再调这个。
func leave_battle() -> void:
	if battle_sub != null and battle_sub.is_subscribed():
		await battle_sub.unsubscribe()
	battle_id = 0
	battle_channel_id = 0


func in_battle() -> bool:
	return battle_id != 0 and battle_sub != null and battle_sub.is_subscribed()


## 自己视角的战斗快照:open_slots / submitted_commands / private_actor_states 只在这里。
func battle_private_snapshot() -> Dictionary:
	return await _app("GET", "/mmo/battle/%d/roles/%d/private-snapshot" % [battle_id, role_id])


func battle_public_snapshot() -> Dictionary:
	return await _app("GET", "/mmo/battle/%d/snapshot" % battle_id)


## 提交一条回合指令。slot 来自 private snapshot 的 open_slots;payload 是 CommandPayload 的单键对象,
## 如 { "attack": { "selected_target_id": 9 } } / { "defend": {} } / { "escape": {} } / { "wait": {} }。
## 返回 { ok, code, data: BattleCommandAck, error };拒绝码 21401-21416 原样透出。
func submit_command(snapshot: Dictionary, slot: Dictionary, payload: Dictionary) -> Dictionary:
	action_seq += 1
	var resp := await transfer_fb(ROUTE_BATTLE_COMMAND, "battle_command", NS_BATTLE + "BattleCommandEnvelope", {
		"protocol_version": PROTOCOL_VERSION,
		"battle_id": battle_id,
		"role_id": role_id,
		"actor_id": int(slot.actor_id),
		"command_slot_id": int(slot.command_slot_id),
		"round": int(snapshot.round),
		"phase": str(snapshot.phase),
		"phase_version": int(snapshot.phase_version),
		"action_seq": action_seq,
		"payload": payload,
	}, "battle_command_ack", NS_BATTLE + "BattleCommandAck", battle_channel_id)
	if not resp.ok:
		action_seq -= 1
	return resp


## 认输(即时权威操作,带 state_version 乐观锁 → 21409)。
func surrender(state_version: int) -> Dictionary:
	return await transfer_fb(ROUTE_BATTLE_INSTANT, "battle_instant_request", NS_BATTLE + "BattleInstantRequest", {
		"protocol_version": PROTOCOL_VERSION,
		"battle_id": battle_id,
		"role_id": role_id,
		"state_version": state_version,
		"op": "SURRENDER",
	}, "battle_instant_ack", NS_BATTLE + "BattleInstantAck", battle_channel_id)


func _on_battle_message(_payload_text: String, bytes: PackedByteArray, _topic: String,
		_publisher: String, _sid: int, _ts: int) -> void:
	var dec := _decode("battle_event", NS_BATTLE + "BattleEventBatchEnvelope", bytes)
	if not dec.ok or str(dec.data.get("visibility", "")) != "PUBLIC":
		return
	var bid := int(dec.data.get("battle_id", 0))
	if bid != battle_id:
		return
	for e in dec.data.get("events", []):
		var seq := int(e.get("stream_seq", 0))
		# Room 会回放历史广播;按 stream_seq 去重,漏号则由业务拉 snapshot。
		if seq <= battle_public_seq:
			continue
		battle_public_seq = seq
		battle_event.emit(bid, e, seq)


## PRIVATE 事件走定向 transfer 而不是 Room 广播:指令在 RESOLVE 前不得泄漏给别人(spec §6.2)。
func _on_battle_transfer(route: String, _payload_text: String, bytes: PackedByteArray, _request_id: String) -> void:
	if route != ROUTE_BATTLE_EVENT:
		return
	var dec := _decode("battle_event", NS_BATTLE + "BattleEventBatchEnvelope", bytes)
	if not dec.ok or int(dec.data.get("battle_id", 0)) != battle_id:
		return
	if str(dec.data.get("visibility", "")) != "PRIVATE" or int(dec.data.get("recipient_role_id", 0)) != role_id:
		return
	for e in dec.data.get("events", []):
		var seq := int(e.get("stream_seq", 0))
		if seq <= battle_private_seq:
			continue
		battle_private_seq = seq
		battle_private_event.emit(battle_id, e, seq)


# --- 心跳 -------------------------------------------------------------------

## 返回 { ok, code, data: { scene_session_id, server_time_ms, public_scene_seq }, error }。
func heartbeat(session_override: int = 0) -> Dictionary:
	return await transfer_fb(ROUTE_HEARTBEAT, "scene_heartbeat_request", NS_SCENE + "HeartbeatRequest", {
		"protocol_version": PROTOCOL_VERSION,
		"scene_session_id": session_override if session_override != 0 else scene_session_id,
		"client_time_ms": int(Time.get_unix_time_from_system() * 1000.0),
	}, "scene_heartbeat_ack", NS_SCENE + "HeartbeatAck")


## FlatBuffers transfer:编码 → transfer_bytes → 按应答 root 解码。
## 返回 { ok, code, data: Dictionary, error };拒绝走外层 code、data 为空。
func transfer_fb(route: String, req_schema: String, req_root: String, payload: Dictionary,
		ack_schema: String, ack_root: String, channel: int = 0, timeout_ms: int = 8000) -> Dictionary:
	var target_channel := channel if channel != 0 else (sub.channel_id if sub != null and sub.is_subscribed() else 0)
	if target_channel == 0:
		return { "ok": false, "code": -1, "data": {}, "error": "not subscribed" }
	var body := payload.duplicate()
	body["request_id"] = "gd-%d-%d" % [role_id, _next_request]
	_next_request += 1
	var bytes := _encode(req_schema, req_root, body)
	if bytes.is_empty():
		return { "ok": false, "code": -1, "data": {}, "error": "encode failed" }
	var resp: Dictionary = await client.transfer_bytes(target_channel, route, bytes, timeout_ms)
	var out := { "ok": resp.ok, "code": int(resp.get("code", -1)), "data": {}, "error": str(resp.get("error", "")) }
	if resp.ok and not resp.data.is_empty():
		var dec := _decode(ack_schema, ack_root, resp.data)
		if not dec.ok:
			return { "ok": false, "code": -1, "data": {}, "error": "decode %s: %s" % [ack_root, dec.error] }
		out.data = dec.data
	return out


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

func _on_message(_payload_text: String, bytes: PackedByteArray, _topic: String,
		_publisher: String, _sid: int, _ts: int) -> void:
	var dec := _decode("scene_event", NS_SCENE + "SceneEventBatchEnvelope", bytes)
	if not dec.ok:
		return   # 不是 MSE1(或坏包):场景 Room 上只应有 MSE1
	var batch: Dictionary = dec.data
	if str(batch.get("visibility", "")) != "PUBLIC":
		return
	for e in batch.get("events", []):
		var seq := int(e.get("stream_seq", 0))
		# seq 回退 = 服务端序列重置(重启/多实例),客户端约定丢弃增量拉 snapshot;
		# 这里只记录基线,由业务决定何时拉。
		last_public_seq = seq
		var payload: Dictionary = e.get("payload", {})
		if payload.has("movement_started"):
			var m: Dictionary = payload.movement_started
			movement_started.emit(int(m.get("entity_id", 0)), m, seq)
		elif payload.has("role_presence"):
			var p: Dictionary = payload.role_presence
			var event := "scene.role_entered" if bool(p.get("entered", false)) else "scene.role_left"
			presence.emit(event, int(p.get("role_id", 0)), str(p.get("role_name", "")), seq, p)


# --- HTTP -------------------------------------------------------------------

## 应用路由(Bearer 认证)。返回 { ok, code, data, error }:业务错误码原样透出
## (21400-21416 / 21600-21613),与 transfer 路径同一套数字。
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
