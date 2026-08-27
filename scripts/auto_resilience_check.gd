# auto_resilience_check.gd — headless 会话韧性 e2e(spec GODOT_SDK_SPEC §7.1)
# 用法: Godot --headless --path privchat-godot-demo -s res://scripts/auto_resilience_check.gd
# 前置: privchat-server(:9001) + privchat-application(:8080) + redis(:6379) 均在运行
#
# 覆盖:
#   [1] 双账号登录;A 挂 ChatService 并 join room
#   [2] 断连 A:local-first 离线读(open_conversation/list_channels/unread)仍可用
#   [3] 离线 queue-first 发送:A 断连时 send_text 入队成功
#   [4] 重连 A(connect+authenticate):ChatService 自动重订阅 room
#       (room_rejoined 信号),离线入队的消息投递到 B
#   [5] 重连后服务端广播:A 的 room_message 信号可达(重订阅真实生效)
extends SceneTree

const MOBILE_A := "+8613800000001"
const MOBILE_B := "+8613800000002"
const SERVICE_API := "http://127.0.0.1:9090"
const SERVICE_KEY := "your_service_master_key_here"
const DIRECT_CHANNEL_TYPE := 1

var room_msgs: Array = []
var rejoin_events: Array = []
var received_b: Array = []


func _initialize() -> void:
	_run()
	_watchdog()


func _watchdog() -> void:
	var t := Timer.new()
	t.wait_time = 120.0
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

	print("== [1/5] 双账号登录;A 挂 ChatService + join room ==")
	var a = await _login(MOBILE_A, "user://privchat-res-a")
	if a == null:
		_fail("login A")
		return
	var b = await _login(MOBILE_B, "user://privchat-res-b")
	if b == null:
		_fail("login B")
		return
	var client_a: PrivchatClient = a.client
	var client_b: PrivchatClient = b.client
	print("A user_id=%d, B user_id=%d" % [a.user_id, b.user_id])

	var chat_a := PrivchatChatService.new()
	root.add_child(chat_a)
	chat_a.setup(client_a)
	chat_a.room_message.connect(func(text, _pub, sid): room_msgs.append({"text": text, "sid": sid}))
	chat_a.room_rejoined.connect(func(ok, err): rejoin_events.append({"ok": ok, "error": err}))

	var chat_b := PrivchatChatService.new()
	root.add_child(chat_b)
	chat_b.setup(client_b)
	chat_b.message_received.connect(func(m): received_b.append(m))

	var ch_resp: Dictionary = await client_a.get_or_create_direct_channel(b.user_id)
	if not ch_resp.ok:
		_fail("get_or_create_direct_channel")
		return
	var channel_id: int = ch_resp.channel_id
	var sync_b: Dictionary = await client_b.sync_channel(channel_id, DIRECT_CHANNEL_TYPE)
	if not sync_b.ok:
		_fail("sync_channel(B)")
		return
	var _open_b: Dictionary = await chat_b.open(channel_id, DIRECT_CHANNEL_TYPE)
	var _open_a: Dictionary = await chat_a.open(channel_id, DIRECT_CHANNEL_TYPE)

	var room_resp: Dictionary = await _service_post("/api/service/room", {"name": "godot-resilience"})
	if not room_resp.ok:
		_fail("create room: %s" % room_resp.error)
		return
	var room_id: int = int(room_resp.data.channel_id)
	var ticket_resp: Dictionary = await _service_post("/api/service/room-tickets/issue", {
		"channel_id": room_id, "user_id": a.user_id, "device_id": a.device_id})
	if not ticket_resp.ok:
		_fail("issue ticket: %s" % ticket_resp.error)
		return
	var join_resp: Dictionary = await chat_a.join_room(room_id, ticket_resp.data.ticket)
	if not join_resp.ok:
		_fail("join_room: %s" % join_resp.error)
		return
	print("room joined: %d" % room_id)

	print("== [2/5] 断连 A;local-first 离线读 ==")
	var disc: Dictionary = await client_a.disconnect_im()
	if not disc.ok:
		_fail("disconnect: %s" % disc.error)
		return
	var page: Dictionary = await client_a.open_conversation(channel_id, DIRECT_CHANNEL_TYPE, 10)
	if not page.ok:
		_fail("offline open_conversation: %s" % page.error)
		return
	var chans: Dictionary = await client_a.list_channels()
	if not chans.ok:
		_fail("offline list_channels: %s" % chans.error)
		return
	var unread: Dictionary = await client_a.get_total_unread_count()
	if not unread.ok:
		_fail("offline unread: %s" % unread.error)
		return
	print("offline reads ok: %d history, %d channels, unread=%d" % [
		page.messages.size(), chans.channels.size(), unread.count])

	print("== [3/5] 离线 queue-first 发送 ==")
	var stamp := int(Time.get_unix_time_from_system())
	var text := "offline-queued-%d" % stamp
	var send_resp: Dictionary = await client_a.send_text(channel_id, DIRECT_CHANNEL_TYPE, text)
	if not send_resp.ok:
		_fail("offline send_text should enqueue, got: %s" % send_resp.error)
		return
	print("offline send enqueued (local message_id=%d)" % int(send_resp.get("message_id", 0)))

	print("== [4/5] 重连;自动重订阅 + 离线消息投递 ==")
	var conn: Dictionary = await client_a.connect_im()
	if not conn.ok:
		_fail("reconnect: %s" % conn.error)
		return
	var auth: Dictionary = await client_a.authenticate(a.user_id, a.access_token, a.device_id)
	if not auth.ok:
		_fail("re-authenticate: %s" % auth.error)
		return
	# 等 room_rejoined(ChatService 收到 → Authenticated 迁移后自动重订阅)。
	var deadline := Time.get_ticks_msec() + 20000
	while rejoin_events.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if rejoin_events.is_empty():
		_fail("no room_rejoined signal after reconnect")
		return
	if not rejoin_events[0].ok:
		_fail("auto resubscribe failed: %s" % rejoin_events[0].error)
		return
	print("auto resubscribed: %s" % JSON.stringify(rejoin_events[0]))
	# 离线入队的消息应在重连后投递到 B。
	deadline = Time.get_ticks_msec() + 20000
	var delivered := false
	while not delivered and Time.get_ticks_msec() < deadline:
		await process_frame
		for m in received_b:
			if str(m.get("content", "")) == text:
				delivered = true
				break
	if not delivered:
		_fail("offline-queued message not delivered to B after reconnect")
		return
	print("offline-queued message delivered to B")

	print("== [5/5] 重连后广播可达 ==")
	var room_text := "resilience-hello-%d" % stamp
	var pub_resp: Dictionary = await _service_post("/api/service/room/%d/broadcast" % room_id,
		{"content": room_text, "sender_id": a.user_id})
	if not pub_resp.ok:
		_fail("broadcast after reconnect")
		return
	deadline = Time.get_ticks_msec() + 15000
	var got := false
	while not got and Time.get_ticks_msec() < deadline:
		await process_frame
		for m in room_msgs:
			if m.text == room_text:
				got = true
				break
	if not got:
		_fail("broadcast not received after resubscribe (msgs=%s)" % JSON.stringify(room_msgs))
		return
	print("broadcast received after resubscribe")

	var _leave: Dictionary = await chat_a.leave_room()
	print("VERIFY_OK")
	quit(0)


func _login(mobile: String, data_dir: String):
	var client := PrivchatClient.new()
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
	return { "client": client, "user_id": data.user_id, "device_id": data.device_id,
			"access_token": data.access_token }


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
