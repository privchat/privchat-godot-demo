# auto_flatbuffers_check.gd — headless 验证通用 FlatBuffers codec(GODOT_FLATBUFFERS_CODEC_SPEC §6)
# 用法: Godot --headless --path privchat-godot-demo -s res://scripts/auto_flatbuffers_check.gd
# 前置: privchat-server(:9001) + privchat-application(:8080) + redis
#
#   [1] 加载 .bfbs,摘要与 protocol/bfbs/SHA256SUMS 一致(§7),root / identifier 正确
#   [2] golden fixture(module-mmorpg 的 move_to.bin)→ 与 Kotlin / Rust 同一结构(§6)
#   [3] 自往返:encode(dict) → decode → 逐字段相等;union 单键、struct、枚举名
#   [4] 转换规则:多余键拒绝(嵌套也拒)、浮点进整数拒绝、ulong 负数拒绝、
#       required 缺失拒绝、坏 identifier / 截断包 / 换了 root 的包拒绝(§3)
#   [5] 跨语言:进场景 → transfer_bytes 发 MMI1 → 服务端(Kotlin)解码受理 → 回 MMA1 → 本端解码
extends SceneTree

const DemoEnv := preload("res://scripts/demo_env.gd")
const DemoMmoSceneService := preload("res://scripts/mmo_scene_service.gd")

const MOBILE_A := "+8613800000001"
const SCENE := "l-10023-7"
const ROOT_INTENT := "privchat.mmorpg.scene.MoveIntentEnvelope"
const ROOT_ACK := "privchat.mmorpg.scene.MoveIntentAck"
var ADMIN_API := DemoEnv.service_api().replace(":9090", ":8080") + "/admin"
const ADMIN_USER := "admin"
const ADMIN_PASSWORD := "admin123"


func _initialize() -> void:
	_run()
	var t := Timer.new()
	t.wait_time = 120.0
	t.one_shot = true
	t.autostart = true
	t.timeout.connect(func() -> void: _fail("watchdog timeout"))
	root.add_child(t)


func _fail(step: String) -> void:
	print("VERIFY_FAILED: %s" % step)
	quit(1)


func _load_bfbs(codec, name: String):
	var bytes := FileAccess.get_file_as_bytes("res://protocol/bfbs/%s.bfbs" % name)
	var r: Dictionary = codec.load_schema(bytes)
	if not r.ok:
		_fail("load %s: %s" % [name, r.error])
		return null
	var sums := FileAccess.get_file_as_string("res://protocol/bfbs/SHA256SUMS")
	if not sums.contains(str(r.schema.get_digest())):
		_fail("%s digest %s not pinned in SHA256SUMS" % [name, r.schema.get_digest()])
		return null
	return r.schema


func _run() -> void:
	await process_frame
	await process_frame
	var codec := PrivchatFlatBuffers.new()

	print("== [1/5] load .bfbs + digest pin ==")
	var intent_schema = _load_bfbs(codec, "scene_move_intent")
	var ack_schema = _load_bfbs(codec, "scene_move_ack")
	if intent_schema == null or ack_schema == null:
		return
	if intent_schema.get_root_type() != ROOT_INTENT or intent_schema.get_root_identifier() != "MMI1":
		_fail("intent schema root=%s ident=%s" % [intent_schema.get_root_type(), intent_schema.get_root_identifier()])
		return
	if ack_schema.get_root_identifier() != "MMA1":
		_fail("ack schema ident=%s" % ack_schema.get_root_identifier())
		return
	print("  ok: MMI1 %s / MMA1 %s" % [intent_schema.get_digest().substr(0, 12), ack_schema.get_digest().substr(0, 12)])

	print("== [2/5] golden fixture move_to.bin ==")
	var golden: Dictionary = codec.decode(intent_schema, FileAccess.get_file_as_bytes("res://protocol/bfbs/fixture_move_to.bin"), ROOT_INTENT)
	if not golden.ok:
		_fail("decode golden: %s" % golden.error)
		return
	var g: Dictionary = golden.data
	# 与 protocol/fixtures/scene/v1/valid/intent/move_to.json 一致。
	if int(g.protocol_version) != 1 or int(g.scene_session_id) != 42 or str(g.request_id) != "req-1" \
			or int(g.movement_seq) != 7 or int(g.client_time_ms) != 1700000000000 \
			or not g.has("command") or not g.command.has("move_to") \
			or int(g.command.move_to.target_position.x) != 1500 or int(g.command.move_to.target_position.y) != -2300:
		_fail("golden mismatch: %s" % JSON.stringify(g))
		return
	print("  ok: %s" % JSON.stringify(g))

	print("== [3/5] self round trip ==")
	var intent := {
		"protocol_version": 1, "scene_session_id": 9007199254740993, "request_id": "gd-rt-1", "movement_seq": 3,
		"command": { "cancel_path": { "path_id": 5 } }, "client_time_ms": 1,
	}
	var enc: Dictionary = codec.encode(intent_schema, ROOT_INTENT, intent)
	if not enc.ok or enc.data.is_empty():
		_fail("encode: %s" % enc.error)
		return
	var dec: Dictionary = codec.decode(intent_schema, enc.data, ROOT_INTENT)
	if not dec.ok or dec.data != intent:
		_fail("round trip mismatch: %s vs %s (%s)" % [JSON.stringify(dec.data), JSON.stringify(intent), dec.error])
		return
	print("  ok: %d bytes, 2^53+1 survives (int is 64-bit)" % enc.data.size())

	print("== [4/5] conversion rules ==")
	var cases := [
		["extra key", { "protocol_version": 1, "request_id": "x", "bogus": 1 }],
		["nested extra key", { "protocol_version": 1, "request_id": "x", "command": { "move_to": { "target_position": { "x": 1, "y": 2, "z": 3 } } } }],
		["float into int", { "protocol_version": 1.0, "request_id": "x" }],
		["negative ulong", { "protocol_version": 1, "request_id": "x", "scene_session_id": -1 }],
		["int out of range", { "protocol_version": 1, "request_id": "x", "command": { "move_to": { "target_position": { "x": 2147483648, "y": 0 } } } }],
		["required missing", { "protocol_version": 1 }],
		["two union keys", { "protocol_version": 1, "request_id": "x", "command": { "stop": {}, "move_to": { "target_position": { "x": 1, "y": 2 } } } }],
		["unknown union member", { "protocol_version": 1, "request_id": "x", "command": { "teleport": {} } }],
	]
	for c in cases:
		var r: Dictionary = codec.encode(intent_schema, ROOT_INTENT, c[1])
		if r.ok:
			_fail("encode must reject %s" % c[0])
			return
		print("  ok: %s -> %s" % [c[0], r.error])
	var bad_ident: PackedByteArray = enc.data.duplicate()
	bad_ident[4] = 0x58
	if codec.decode(intent_schema, bad_ident, ROOT_INTENT).ok:
		_fail("bad identifier must be rejected")
		return
	if codec.decode(intent_schema, enc.data.slice(0, 12), ROOT_INTENT).ok:
		_fail("truncated buffer must be rejected")
		return
	if codec.decode(ack_schema, enc.data, ROOT_ACK).ok:
		_fail("intent bytes must not decode as ack")
		return
	print("  ok: bad identifier / truncated / wrong root rejected")

	print("== [5/5] cross-language: MMI1 -> Kotlin -> MMA1 ==")
	var a = await _login(MOBILE_A, "user://privchat-fb-a")
	if a == null:
		_fail("login A")
		return
	var mmo := DemoMmoSceneService.new()
	root.add_child(mmo)
	mmo.setup(a.client, a.access_token)
	var ra: Dictionary = await mmo.ensure_role("godot-a-%d" % a.user_id)
	if not ra.ok:
		_fail("ensure role: %s" % ra.error)
		return
	# 场景是运营内容,由后台开(与 auto_mmo_check 同一前置)。
	var admin_token := await _admin_login()
	if admin_token.is_empty() or not (await _admin_post(admin_token, "/mmo/scenes", { "scene_ref": SCENE })).ok:
		_fail("admin provision scene")
		return
	var ea: Dictionary = await mmo.enter(SCENE, a.device_id)
	if not ea.ok:
		_fail("enter: code=%d %s (open the scene from the admin console first)" % [ea.code, ea.error])
		return
	var wire := codec.encode(intent_schema, ROOT_INTENT, {
		"protocol_version": 1, "scene_session_id": mmo.scene_session_id, "request_id": "gd-fb-%d" % Time.get_ticks_msec(),
		"movement_seq": 1, "command": { "move_to": { "target_position": { "x": 60000, "y": 40000 } } },
		"client_time_ms": int(Time.get_unix_time_from_system() * 1000.0),
	})
	if not wire.ok:
		_fail("encode wire: %s" % wire.error)
		return
	# 落盘一份,作为三端共享的 golden fixture 候选(fixtures/.../godot_move_to.bin)。
	var dump := FileAccess.open("user://godot_move_to.bin", FileAccess.WRITE)
	if dump != null:
		dump.store_buffer(wire.data)
		dump.close()
		print("  wrote %s (%d bytes)" % [ProjectSettings.globalize_path("user://godot_move_to.bin"), wire.data.size()])
	var resp: Dictionary = await a.client.transfer_bytes(mmo.channel_id, DemoMmoSceneService.ROUTE_MOVE, wire.data)
	if not resp.ok:
		_fail("transfer_bytes: %s" % JSON.stringify(resp))
		return
	var ack: Dictionary = codec.decode(ack_schema, resp.data, ROOT_ACK)
	if not ack.ok:
		_fail("decode ack: %s (%d bytes)" % [ack.error, resp.data.size()])
		return
	if int(ack.data.accepted_movement_seq) != 1 or int(ack.data.scene_session_id) != mmo.scene_session_id \
			or bool(ack.data.replayed) or int(ack.data.path_id) <= 0:
		_fail("ack mismatch: %s" % JSON.stringify(ack.data))
		return
	print("  ok: Kotlin accepted seq=1 path_id=%d entity_version=%d" % [int(ack.data.path_id), int(ack.data.entity_version)])
	await mmo.leave()
	await mmo.close()
	print("VERIFY_OK")
	quit(0)


func _login(mobile: String, data_dir: String):
	var client := DemoEnv.make_client()
	client.data_dir = data_dir
	root.add_child(client)
	var send_resp: Dictionary = await client.send_sms_code(mobile)
	if not send_resp.ok:
		print("send_sms_code(%s) failed: %s" % [mobile, send_resp.error])
		return null
	var code := ""
	for key in ["neton:sms:code:%s" % mobile, "sms:code:%s" % mobile]:
		var output: Array = []
		if OS.execute("redis-cli", ["GET", key], output, true) == 0 and not output.is_empty():
			code = output[0].strip_edges()
			if not code.is_empty():
				break
	if code.is_empty():
		return null
	var device := PrivchatPlatformAuthClient.default_device_info()
	var http_resp: Dictionary = await client._ensure_auth().login_with_sms(mobile, code, device)
	if not http_resp.ok or not client.start():
		return null
	var data: Dictionary = http_resp.data
	if not (await client.authenticate(data.user_id, data.access_token, data.device_id)).ok:
		return null
	if not (await client.connect_im()).ok or not (await client.bootstrap_sync()).ok:
		return null
	client.logged_in_user_id = data.user_id
	client.logged_in_device_id = data.device_id
	await process_frame
	return { "client": client, "user_id": data.user_id, "device_id": data.device_id, "access_token": data.access_token }


func _admin_login() -> String:
	var req := HTTPRequest.new()
	root.add_child(req)
	var err: int = req.request(ADMIN_API + "/system/auth/login", ["Content-Type: application/json"],
			HTTPClient.METHOD_POST, JSON.stringify({ "username": ADMIN_USER, "password": ADMIN_PASSWORD }))
	if err != OK:
		req.queue_free()
		return ""
	var resp: Array = await req.request_completed
	req.queue_free()
	var parsed = JSON.parse_string(resp[3].get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or int(parsed.get("code", -1)) != 0:
		print("admin login failed: %s" % str(parsed))
		return ""
	return str(parsed.data.get("accessToken", ""))


func _admin_post(token: String, path: String, body: Dictionary) -> Dictionary:
	var req := HTTPRequest.new()
	root.add_child(req)
	var err: int = req.request(ADMIN_API + path,
			["Content-Type: application/json", "Authorization: Bearer %s" % token],
			HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		req.queue_free()
		return { "ok": false, "error": "http request error %d" % err }
	var resp: Array = await req.request_completed
	req.queue_free()
	var parsed = JSON.parse_string(resp[3].get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or int(parsed.get("code", -1)) != 0:
		return { "ok": false, "error": str(parsed) }
	return { "ok": true, "data": parsed.data }
