# auto_comm_check.gd — headless 通信链路 e2e 验证（对标 cocos-demo docs/manual-e2e.md）
# 用法: Godot --headless --path privchat-godot-demo -s res://scripts/auto_comm_check.gd
# 前置: privchat-server(:9001) + privchat-application(:8080) + redis(:6379) 均在运行
#
# 覆盖:
#   [1] 双账号登录（A/B）
#   [2] A 打开与 B 的 direct channel + 发送文本
#   [3] B 收到 TimelineUpdated 事件（get_message_by_id 取内容校验一致）
#   [4] A 收到 MessageSendStatusChanged 回执
#   [5] 房间订阅: 创建 room -> 签 ticket -> subscribe -> 服务端广播 ->
#       收到 SubscriptionMessageReceived -> unsubscribe
#       （spec ROOM_CHANNEL_SPEC：Room 客户端只能订阅，广播由服务端触发）
extends SceneTree

const DemoEnv := preload("res://scripts/demo_env.gd")

const MOBILE_A := "+8613800000001"
const MOBILE_B := "+8613800000002"
# 与网关同实例,统一由 DemoEnv 决定,避免两处各改一半。
var SERVICE_API := DemoEnv.service_api()
const SERVICE_KEY := "your_service_master_key_here"
const ROOM_CHANNEL_TYPE := 2
const DIRECT_CHANNEL_TYPE := 1

var events_a: Array = []
var events_b: Array = []


func _initialize() -> void:
	_run()
	_watchdog()


## 防止任何环节永久挂起（如 authenticate 挂死）—— 超时强制退出。
## 用挂在树上的 Timer 节点而非 create_timer()：SceneTreeTimer 是树外对象，
## 成功路径提前 quit() 时不会被回收，会触发 "ObjectDB instances leaked at
## exit"；树上的节点随场景树析构正常释放。
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

	print("== [1/5] 双账号登录 ==")
	var a = await _login(MOBILE_A, "user://privchat-data-a")
	if a == null:
		_fail("login A")
		return
	var b = await _login(MOBILE_B, "user://privchat-data-b")
	if b == null:
		_fail("login B")
		return
	var client_a: PrivchatClient = a.client
	var client_b: PrivchatClient = b.client
	var uid_a: int = a.user_id
	var uid_b: int = b.user_id
	print("A user_id=%d, B user_id=%d" % [uid_a, uid_b])
	client_a.sdk_event.connect(func(seq, _ts, kind, event): events_a.append({"kind": kind, "seq": seq, "event": event}))
	client_b.sdk_event.connect(func(seq, _ts, kind, event): events_b.append({"kind": kind, "seq": seq, "event": event}))

	print("== [2/5] A 打开与 B 的单聊并发送 ==")
	var ch_resp: Dictionary = await client_a.get_or_create_direct_channel(uid_b)
	print("get_or_create_direct_channel -> ", JSON.stringify(ch_resp))
	if not ch_resp.ok:
		_fail("get_or_create_direct_channel")
		return
	var channel_id: int = ch_resp.channel_id
	var send_text := "hello-from-A-%d" % int(Time.get_unix_time_from_system())
	var send_resp: Dictionary = await client_a.send_text(channel_id, DIRECT_CHANNEL_TYPE, send_text)
	print("send_text -> ", JSON.stringify(send_resp))
	if not send_resp.ok:
		_fail("send_text")
		return

	print("== [3/5] 等待 B 收到 TimelineUpdated ==")
	var received: Dictionary = await _wait_new_message(client_b, events_b, channel_id, send_text, 15)
	if received.is_empty():
		_fail("B did not receive message (events=%s)" % JSON.stringify(events_b))
		return
	print("B received: ", JSON.stringify(received))

	print("== [4/5] 检查 A 的投递回执 (MessageSendStatusChanged) ==")
	var got_status := false
	for e in events_a:
		if e.kind == "MessageSendStatusChanged":
			got_status = true
			print("A status event: %s" % JSON.stringify(e.event))
			break
	if not got_status:
		print("WARN: 未收到 MessageSendStatusChanged（非致命，继续）")

	print("== [5/5] 房间订阅: 创建 room -> ticket -> subscribe -> 广播 -> 接收 -> unsubscribe ==")
	var room_resp: Dictionary = await _service_post("/api/service/room", {"name": "godot-e2e-room"})
	if not room_resp.ok:
		_fail("create room: %s" % room_resp.error)
		return
	var room_id: int = int(room_resp.data.channel_id)
	print("room created: channel_id=%d" % room_id)
	var ticket_resp: Dictionary = await _service_post("/api/service/room-tickets/issue", {
		"channel_id": room_id, "user_id": uid_a, "device_id": a.device_id})
	if not ticket_resp.ok:
		_fail("issue room ticket: %s" % ticket_resp.error)
		return
	var ticket: String = ticket_resp.data.ticket
	var sub_resp: Dictionary = await client_a.subscribe_channel(room_id, ROOM_CHANNEL_TYPE, ticket)
	print("subscribe -> ", JSON.stringify(sub_resp))
	if not sub_resp.ok:
		_fail("subscribe room")
		return
	var room_text := "room-hello-%d" % int(Time.get_unix_time_from_system())
	var pub_resp: Dictionary = await _service_post("/api/service/room/%d/broadcast" % room_id,
		{"content": room_text, "sender_id": uid_a})
	print("room broadcast -> ", JSON.stringify(pub_resp))
	if not pub_resp.ok:
		_fail("room broadcast")
		return
	var room_msg: Dictionary = await _wait_subscription_message(events_a, room_id, room_text, 15)
	if room_msg.is_empty():
		_fail("room message not received (events=%s)" % JSON.stringify(events_a))
		return
	print("room message received: ", JSON.stringify(room_msg))
	var unsub_resp: Dictionary = await client_a.unsubscribe_channel(room_id, ROOM_CHANNEL_TYPE)
	print("unsubscribe -> ", JSON.stringify(unsub_resp))
	if not unsub_resp.ok:
		_fail("unsubscribe room")
		return

	print("VERIFY_OK")
	quit(0)


## 登录一个账号：send_sms_code -> redis 读码 -> login(sms-login + authenticate + connect)
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


## 调服务端管理 API（X-Service-Key），返回 {ok, data} / {ok:false, error}。
## 对标业务后台（privchat-application）创建房间 / 签 ticket 的职责。
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


## 在事件缓冲里等待指定 Room 的 SubscriptionMessageReceived（服务端广播），
## payload 是 UTF-8 字节数组，转成字符串后与 content 比对。超时返回 {}。
func _wait_subscription_message(events: Array, channel_id: int, content: String, timeout_secs: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_secs * 1000
	var seen := {}
	while Time.get_ticks_msec() < deadline:
		await process_frame
		for e in events:
			if e.kind != "SubscriptionMessageReceived":
				continue
			if seen.has(e.seq):
				continue
			seen[e.seq] = true
			var s: Dictionary = e.event.get("event", {}).get("SubscriptionMessageReceived", {})
			if int(s.get("channel_id", -1)) != channel_id:
				continue
			var bytes := PackedByteArray()
			for b in s.get("payload", []):
				bytes.append(int(b))
			s["payload_text"] = bytes.get_string_from_utf8()
			if s.payload_text == content:
				return s
	return {}


## 在事件缓冲里等待指定 channel 的 TimelineUpdated，再用 get_message_by_id
## 从本地时间线取内容校验。超时返回 {}。
## Rust SDK 本地优先模型：没有 NewMessage 事件，新消息统一以
## TimelineUpdated(channel_id, message_id, reason) 通知。
func _wait_new_message(client: PrivchatClient, events: Array, channel_id: int, content: String, timeout_secs: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_secs * 1000
	var seen := {}
	while Time.get_ticks_msec() < deadline:
		await process_frame
		for e in events:
			if e.kind != "TimelineUpdated":
				continue
			if seen.has(e.seq):
				continue
			seen[e.seq] = true
			var t: Dictionary = e.event.get("event", {}).get("TimelineUpdated", {})
			if int(t.get("channel_id", -1)) != channel_id:
				continue
			var message_id: int = int(t.get("message_id", 0))
			if message_id <= 0:
				continue
			var resp: Dictionary = await client.get_message_by_id(message_id)
			if not resp.ok or typeof(resp.data) != TYPE_DICTIONARY:
				continue
			var m: Dictionary = resp.data
			if str(m.get("content", "")) == content:
				return m
	return {}
