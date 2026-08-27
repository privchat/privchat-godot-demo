# auto_chat_check.gd — headless ChatService e2e(chat facade 里程碑验收)
# 用法: Godot --headless --path privchat-godot-demo -s res://scripts/auto_chat_check.gd
# 前置: privchat-server(:9001) + privchat-application(:8080) + redis(:6379) 均在运行
#
# 覆盖:
#   [1] 双账号登录,B 挂 ChatService
#   [2] A 发 3 条消息;B 的 message_received 信号逐条到达(去重后恰 3 条)
#   [3] B open_conversation:历史含全部 3 条且升序(local-first 渲染真源)
#   [4] B 未读数 >0 -> mark_read 到最后一条 pts -> 未读归零 + unread_changed 信号
#   [5] B channel_list:频道在列,unread_count 已归零
#   [6] Room: join_room -> 服务端广播 x2(含同 id 重放护栏) -> room_message 信号
extends SceneTree

const MOBILE_A := "+8613800000001"
const MOBILE_B := "+8613800000002"
const SERVICE_API := "http://127.0.0.1:9090"
const SERVICE_KEY := "your_service_master_key_here"
const DIRECT_CHANNEL_TYPE := 1

var received_msgs: Array = []
var unread_events: Array = []
var room_msgs: Array = []


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

	print("== [1/6] 双账号登录 + B 挂 ChatService ==")
	var a = await _login(MOBILE_A, "user://privchat-chat-a")
	if a == null:
		_fail("login A")
		return
	var b = await _login(MOBILE_B, "user://privchat-chat-b")
	if b == null:
		_fail("login B")
		return
	var client_a: PrivchatClient = a.client
	var client_b: PrivchatClient = b.client
	print("A user_id=%d, B user_id=%d" % [a.user_id, b.user_id])

	var chat_b := PrivchatChatService.new()
	root.add_child(chat_b)
	chat_b.setup(client_b)
	chat_b.message_received.connect(func(m): received_msgs.append(m))
	chat_b.unread_changed.connect(func(cid, count): unread_events.append({"channel_id": cid, "count": count}))
	chat_b.room_message.connect(func(text, publisher, sid): room_msgs.append({"text": text, "publisher": publisher, "sid": sid}))

	print("== [2/6] A 发 3 条,B 信号逐条到达 ==")
	var ch_resp: Dictionary = await client_a.get_or_create_direct_channel(b.user_id)
	if not ch_resp.ok:
		_fail("get_or_create_direct_channel")
		return
	var channel_id: int = ch_resp.channel_id
	# B 侧先 open 会话,让 ChatService 有了频道上下文才收得到该频道事件。
	var sync_b: Dictionary = await client_b.sync_channel(channel_id, DIRECT_CHANNEL_TYPE)
	if not sync_b.ok:
		_fail("sync_channel(B)")
		return
	var first_page: Dictionary = await chat_b.open(channel_id, DIRECT_CHANNEL_TYPE)
	if not first_page.ok:
		_fail("open_conversation(before): %s" % first_page.error)
		return

	var stamp := int(Time.get_unix_time_from_system())
	var texts: Array[String] = []
	for i in range(3):
		texts.append("chat-e2e-%d-%d" % [stamp, i])
	for t in texts:
		var send_resp: Dictionary = await client_a.send_text(channel_id, DIRECT_CHANNEL_TYPE, t)
		if not send_resp.ok:
			_fail("send_text(%s)" % t)
			return

	var deadline := Time.get_ticks_msec() + 20000
	while received_msgs.size() < 3 and Time.get_ticks_msec() < deadline:
		await process_frame
	if received_msgs.size() != 3:
		_fail("message_received signals: want 3, got %d" % received_msgs.size())
		return
	for i in range(3):
		if str(received_msgs[i].get("content", "")) != texts[i]:
			_fail("message %d content mismatch: %s" % [i, received_msgs[i]])
			return
	print("3 messages received in order via signal")

	print("== [3/6] open_conversation 历史校验 ==")
	var page: Dictionary = await chat_b.open(channel_id, DIRECT_CHANNEL_TYPE)
	if not page.ok:
		_fail("open_conversation: %s" % page.error)
		return
	var contents := []
	for m in page.messages:
		contents.append(str(m.get("content", "")))
	for t in texts:
		if not contents.has(t):
			_fail("history missing %s (got %s)" % [t, contents])
			return
	# 顺序校验:SDK 契约为「显示序 DESC」(最新在前),后发的排在前面。
	if contents.find(texts[2]) > contents.find(texts[0]):
		_fail("history not newest-first: %s" % str(contents))
		return
	print("history ok: %d msgs, has_more_before=%s" % [page.messages.size(), page.has_more_before])

	print("== [4/6] 未读 -> mark_read -> 归零 ==")
	var unread1: Dictionary = await chat_b.unread_count()
	if not unread1.ok or unread1.count <= 0:
		_fail("unread before mark_read should be >0, got %s" % str(unread1))
		return
	print("unread before: %d" % unread1.count)
	var last_pts: int = int(received_msgs[2].get("pts", 0))
	if last_pts <= 0:
		_fail("last message has no pts: %s" % str(received_msgs[2]))
		return
	var mark_resp: Dictionary = await chat_b.mark_read(last_pts)
	if not mark_resp.ok:
		_fail("mark_read: %s" % mark_resp.error)
		return
	var unread2: Dictionary = await chat_b.unread_count()
	if not unread2.ok or unread2.count != 0:
		_fail("unread after mark_read should be 0, got %s" % str(unread2))
		return
	if unread_events.is_empty():
		_fail("no unread_changed signal")
		return
	print("mark_read -> last_read_pts=%d, unread=0, unread_changed x%d" % [mark_resp.last_read_pts, unread_events.size()])

	print("== [5/6] channel_list 含频道且未读归零 ==")
	var list_resp: Dictionary = await chat_b.channel_list()
	if not list_resp.ok:
		_fail("channel_list: %s" % list_resp.error)
		return
	var entry := {}
	for c in list_resp.channels:
		if int(c.get("channel_id", -1)) == channel_id:
			entry = c
			break
	if entry.is_empty():
		_fail("channel %d missing from channel_list" % channel_id)
		return
	if int(entry.get("unread_count", -1)) != 0:
		_fail("channel_list unread_count should be 0, got %s" % str(entry.get("unread_count")))
		return
	print("channel_list ok: unread_count=0, last_msg_timestamp=%s" % str(entry.get("last_msg_timestamp")))

	print("== [6/6] Room: join -> 广播 x2 -> room_message 信号 ==")
	var room_resp: Dictionary = await _service_post("/api/service/room", {"name": "godot-chat-e2e"})
	if not room_resp.ok:
		_fail("create room: %s" % room_resp.error)
		return
	var room_id: int = int(room_resp.data.channel_id)
	var ticket_resp: Dictionary = await _service_post("/api/service/room-tickets/issue", {
		"channel_id": room_id, "user_id": b.user_id, "device_id": b.device_id})
	if not ticket_resp.ok:
		_fail("issue ticket: %s" % ticket_resp.error)
		return
	var join_resp: Dictionary = await chat_b.join_room(room_id, ticket_resp.data.ticket)
	if not join_resp.ok:
		_fail("join_room: %s" % join_resp.error)
		return
	for i in range(2):
		var pub_resp: Dictionary = await _service_post("/api/service/room/%d/broadcast" % room_id,
			{"content": "room-chat-%d-%d" % [stamp, i], "sender_id": a.user_id})
		if not pub_resp.ok:
			_fail("broadcast %d" % i)
			return
	deadline = Time.get_ticks_msec() + 15000
	while room_msgs.size() < 2 and Time.get_ticks_msec() < deadline:
		await process_frame
	if room_msgs.size() != 2:
		_fail("room_message signals: want 2, got %d" % room_msgs.size())
		return
	# 去重护栏:sid 各不相同。
	if room_msgs[0].sid == room_msgs[1].sid:
		_fail("room messages not deduped: %s" % str(room_msgs))
		return
	var leave_resp: Dictionary = await chat_b.leave_room()
	if not leave_resp.ok:
		_fail("leave_room")
		return
	print("room ok: %s" % JSON.stringify(room_msgs))

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
