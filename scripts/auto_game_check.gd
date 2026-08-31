# auto_game_check.gd — headless GameService e2e(game facade 里程碑验收)
# 用法: Godot --headless --path privchat-godot-demo -s res://scripts/auto_game_check.gd
# 前置: privchat-server(:9001) + privchat-application(:8080) + redis(:6379) 均在运行
#
# 覆盖:
#   [1] 登录 + 挂 GameService
#   [2] 创建 room -> 签 ticket -> join
#   [3] send_command("game/room/heartbeat"):Channel Transfer 穿透
#       client -> privchat wire -> game application -> 原路回包,校验 server_ts;
#       module-game 未挂载时退化为广播回环(WARN 提示,不判失败)
#   [4] 服务端广播 x2 + 事件流:game_event 信号逐条到达且 sid 去重
#   [5] leave 后再广播:不应再收到 game_event(频道过滤护栏)
extends SceneTree

const DemoEnv := preload("res://scripts/demo_env.gd")

const MOBILE_A := "+8613800000001"
# 与网关同实例,统一由 DemoEnv 决定,避免两处各改一半。
var SERVICE_API := DemoEnv.service_api()
const SERVICE_KEY := "your_service_master_key_here"

var game_events: Array = []


func _initialize() -> void:
	_run()
	_watchdog()


func _watchdog() -> void:
	# autostart:_initialize 时刻节点尚未进入运行中的树,直接 start() 会被拒。
	var t := Timer.new()
	t.wait_time = 100.0
	t.one_shot = true
	t.autostart = true
	t.timeout.connect(func() -> void: _fail("watchdog timeout"))
	root.add_child(t)


func _fail(step: String) -> void:
	print("VERIFY_FAILED: %s" % step)
	quit(1)


func _run() -> void:
	await process_frame
	await process_frame

	print("== [1/5] 登录 + 挂 GameService ==")
	var a = await _login(MOBILE_A, "user://privchat-game-a")
	if a == null:
		_fail("login")
		return
	var client: PrivchatClient = a.client
	print("user_id=%d" % a.user_id)
	var game := DemoGameService.new()
	root.add_child(game)
	game.setup(client)
	game.game_event.connect(func(text, _bytes, _topic, publisher, sid, _ts):
		game_events.append({"text": text, "publisher": publisher, "sid": sid}))

	print("== [2/5] 创建 room -> ticket -> join ==")
	var room_resp: Dictionary = await _service_post("/api/service/room", {"name": "godot-game-e2e"})
	if not room_resp.ok:
		_fail("create room: %s" % room_resp.error)
		return
	var room_id: int = int(room_resp.data.channel_id)
	var ticket_resp: Dictionary = await _service_post("/api/service/room-tickets/issue", {
		"channel_id": room_id, "user_id": a.user_id, "device_id": a.device_id})
	if not ticket_resp.ok:
		_fail("issue ticket: %s" % ticket_resp.error)
		return
	var join_resp: Dictionary = await game.join(room_id, ticket_resp.data.ticket)
	if not join_resp.ok:
		_fail("join: %s" % join_resp.error)
		return
	print("joined room channel_id=%d" % room_id)

	print("== [3/5] send_command: game/room/heartbeat(链路穿透) ==")
	var hb: Dictionary = await game.send_command("game/room/heartbeat", {})
	if hb.ok and int(hb.data.get("server_ts", 0)) > 0:
		print("heartbeat ok: server_ts=%d request_id=%d" % [int(hb.data.server_ts), hb.request_id])
	else:
		# module-game 未挂载到共享 privchat-application 时的退化路径:
		# transfer 链路本身(发出→回包)仍被验证,只是业务侧无 handler。
		print("WARN: heartbeat 未通(%s)— module-game 可能未挂载,继续广播回环验证" % str(hb.error))

	# 业务错误码的最后一跳:application 返回的整数必须原样到达 GDScript。
	# 前面几跳(wire → TransferReply → C ABI JSON/out_code)有 Rust 单测,
	# 这一跳只有跑通真实链路才能证明 —— 它经过 native 的 JSON 解析与
	# _parse_transfer,任何一处把非零码折叠成通用失败都会在此暴露。
	# 两条路径都能取到一个**非零业务码**:
	#   module-game 已挂载  → 未知路由,GameTransferHandler 返 21901
	#   module-game 未挂载  → 频道未绑定,application dispatcher 返 21501
	# 两者都不是核心 IM 码,SDK 与桥接层都不认识它们的语义。
	var probe: Dictionary = await game.send_command("game/room/no-such-route", {})
	var want := 21901 if hb.ok else 21501
	if probe.code == want:
		print("  ok: business code %d survived application -> GDScript" % want)
	else:
		_fail("business code passthrough: want %d, got code=%d error=%s"
				% [want, probe.code, str(probe.error)])
		return

	print("== [4/5] 广播 x2 -> game_event 信号 + 去重 ==")
	var stamp := int(Time.get_unix_time_from_system())
	for i in range(2):
		var pub_resp: Dictionary = await _service_post("/api/service/room/%d/broadcast" % room_id,
			{"content": JSON.stringify({"op": "game-e2e", "n": i, "stamp": stamp}), "sender_id": a.user_id})
		if not pub_resp.ok:
			_fail("broadcast %d" % i)
			return
	var deadline := Time.get_ticks_msec() + 15000
	while game_events.size() < 2 and Time.get_ticks_msec() < deadline:
		await process_frame
	if game_events.size() != 2:
		_fail("game_event signals: want 2, got %d (%s)" % [game_events.size(), JSON.stringify(game_events)])
		return
	if game_events[0].sid == game_events[1].sid:
		_fail("game events not deduped: %s" % JSON.stringify(game_events))
		return
	var parsed0 = JSON.parse_string(game_events[0].text)
	if typeof(parsed0) != TYPE_DICTIONARY or str(parsed0.get("op", "")) != "game-e2e":
		_fail("game event payload mismatch: %s" % game_events[0].text)
		return
	print("game events ok: %s" % JSON.stringify(game_events))

	print("== [5/5] leave 后广播不再送达 ==")
	var leave_resp: Dictionary = await game.leave()
	if not leave_resp.ok:
		_fail("leave")
		return
	var count_before := game_events.size()
	var pub2: Dictionary = await _service_post("/api/service/room/%d/broadcast" % room_id,
		{"content": "after-leave", "sender_id": a.user_id})
	if not pub2.ok:
		_fail("broadcast after leave")
		return
	# 等 2 秒确认没有新事件。
	deadline = Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		await process_frame
	if game_events.size() != count_before:
		_fail("received game_event after leave: %s" % JSON.stringify(game_events))
		return
	print("no events after leave — channel filter ok")

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
	var code := _read_sms_code(mobile)
	if code.is_empty():
		print("no sms code in redis for %s" % mobile)
		return null
	var device := PrivchatPlatformAuthClient.default_device_info()
	var http_resp: Dictionary = await client._ensure_auth().login_with_sms(mobile, code, device)
	if not http_resp.ok:
		print("sms-login(%s) failed: %s" % [mobile, http_resp.error])
		return null
	if not client.start():
		print("native start failed for %s" % mobile)
		return null
	var data: Dictionary = http_resp.data
	var auth_resp: Dictionary = await client.authenticate(data.user_id, data.access_token, data.device_id)
	if not auth_resp.ok:
		print("authenticate(%s) failed: %s" % [mobile, auth_resp.error])
		return null
	var conn_resp: Dictionary = await client.connect_im()
	if not conn_resp.ok:
		print("connect(%s) failed: %s" % [mobile, conn_resp.error])
		return null
	var boot_resp: Dictionary = await client.bootstrap_sync()
	if not boot_resp.ok:
		print("bootstrap(%s) failed: %s" % [mobile, boot_resp.error])
		return null
	client.logged_in_user_id = data.user_id
	client.logged_in_device_id = data.device_id
	await process_frame
	await process_frame
	return { "client": client, "user_id": data.user_id, "device_id": data.device_id }


func _read_sms_code(mobile: String) -> String:
	for key in ["neton:sms:code:%s" % mobile, "sms:code:%s" % mobile]:
		var output: Array = []
		var rc := OS.execute("redis-cli", ["GET", key], output, true)
		if rc == 0 and not output.is_empty():
			var v: String = output[0].strip_edges()
			if not v.is_empty():
				return v
	return ""


func _service_post(path: String, body: Dictionary) -> Dictionary:
	var req := HTTPRequest.new()
	root.add_child(req)
	var err: int = req.request(SERVICE_API + path,
		["Content-Type: application/json", "X-Service-Key: %s" % SERVICE_KEY],
		HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		req.queue_free()
		return {"ok": false, "error": "http request error %d" % err}
	var resp: Array = await req.request_completed
	req.queue_free()
	var parsed = JSON.parse_string(resp[3].get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or int(parsed.get("code", -1)) != 0:
		return {"ok": false, "error": str(parsed)}
	return {"ok": true, "data": parsed.data}
