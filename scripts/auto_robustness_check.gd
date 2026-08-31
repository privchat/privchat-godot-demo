# auto_robustness_check.gd — headless 误用/生命周期健壮性 e2e
# 用法: Godot --headless --path privchat-godot-demo -s res://scripts/auto_robustness_check.gd
# 前置: privchat-server(:9001) + privchat-application(:8080) + redis(:6379)
#
# 本脚本刻意用「错误的方式」调用 SDK,验证它降级为错误返回而不是崩溃/挂死:
#   [1] 未 start() 就调用 → 返回错误,不得崩溃(null instance)
#   [2] 未 join 就 send_command → 明确错误,不得打到 channel 0
#   [3] authenticate 成功后应自动记住 user_id(否则 send_text 用 -1 发信)
#   [4] 请求在途时释放服务节点(切场景)→ 不得出现 freed instance 报错
#   [5] 连接状态抖动 → 重订阅不叠加(单次 in-flight)
#   [6] 超时后迟到的结果不得在 facade 内泄漏累积
extends SceneTree

const DemoEnv := preload("res://scripts/demo_env.gd")

const MOBILE_A := "+8613800000001"
const MOBILE_B := "+8613800000002"

var failures: Array = []


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


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  ok: %s" % label)
	else:
		failures.append(label)
		print("  FAIL: %s" % label)


func _run() -> void:
	await process_frame

	print("== [1/6] 未 start() 就调用 ==")
	var raw := DemoEnv.make_client()
	root.add_child(raw)
	var r1: Dictionary = await raw.connect_im(1000)
	_check(not r1.ok and not str(r1.error).is_empty(), "connect_im before start returns error")
	var r2: Dictionary = await raw.open_conversation(1, 1, 10)
	_check(not r2.ok, "open_conversation before start returns error")
	var r3: Dictionary = await raw.send_text(1, 1, "x")
	_check(not r3.ok, "send_text before start returns error")
	var r4: Dictionary = await raw.rpc_call("x/y", {})
	_check(not r4.ok, "rpc_call before start returns error")
	_check(raw.connection_state() == "", "connection_state before start is empty")
	_check(raw.recent_events().is_empty(), "recent_events before start is empty array")
	raw.queue_free()

	print("== [2/6] 未 join 就 send_command ==")
	var g0 := DemoGameService.new()
	root.add_child(g0)
	g0.setup(raw)
	var c0: Dictionary = await g0.send_command("game/test", {})
	_check(not c0.ok and str(c0.error).contains("join"), "send_command before join is rejected")
	await g0.close()

	print("== [3/6] authenticate 后自动记住身份 ==")
	var a = await _login(MOBILE_A, "user://privchat-rb-a")
	if a == null:
		_fail("login A")
		return
	var client: PrivchatClient = a.client
	_check(client.logged_in_user_id == a.user_id, "authenticate records user_id")
	_check(client.logged_in_device_id == a.device_id, "authenticate records device_id")

	print("== [4/6] 请求在途时释放服务节点 ==")
	var chat := PrivchatChatService.new()
	root.add_child(chat)
	chat.setup(client)
	var b = await _login(MOBILE_B, "user://privchat-rb-b")
	if b == null:
		_fail("login B")
		return
	var ch: Dictionary = await client.get_or_create_direct_channel(b.user_id)
	if not ch.ok:
		_fail("direct channel: %s" % ch.error)
		return
	var _open: Dictionary = await chat.open(ch.channel_id, 1)
	# 发起请求后立刻关闭服务(等价于用户切走场景)。close() 会排空在途请求,
	# 直接 queue_free() 会留下无法恢复的协程状态。
	chat.send_text("bye-%d" % Time.get_ticks_msec())
	await chat.close()
	for i in range(30):
		await process_frame
	_check(not is_instance_valid(chat), "close() frees the service")
	_check(client.inflight_count() == 0, "close() drains in-flight requests")

	print("== [5/6] 连接状态抖动不叠加重订阅 ==")
	var sub := PrivchatSubscription.new()
	root.add_child(sub)
	sub.setup(client)
	var rejoins: Array = []
	sub.resubscribed.connect(func(ok, err): rejoins.append({"ok": ok, "error": err}))
	# 伪造已订阅状态,再连发多次状态迁移。
	sub.channel_id = 999999
	for i in range(5):
		client.connection_state_changed.emit("Connecting", "Authenticated")
	for i in range(60):
		await process_frame
	_check(rejoins.size() <= 1,
			"flapping state issues at most one resubscribe (got %d)" % rejoins.size())
	sub.channel_id = 0
	await sub.close()

	print("== [6b] 二进制 transfer 承载含 NUL 的负载 ==")
	# FlatBuffers 风格负载:内嵌 NUL + 非 UTF-8 字节。字符串版 transfer 会
	# 在 \0 处截断;二进制版必须原样送达(此处无 game 频道,断言重点是
	# 不被本地参数校验拒绝、且返回结构正确)。
	var blob := PackedByteArray([0x00, 0xFF, 0x41, 0x00, 0xFE, 0x42])
	var tb: Dictionary = await client.transfer_bytes(ch.channel_id, "game/room/heartbeat", blob, 3000)
	_check(tb.has("code") and tb.has("data") and typeof(tb.data) == TYPE_PACKED_BYTE_ARRAY,
			"transfer_bytes returns { code, data: PackedByteArray }")
	_check(not str(tb.error).contains("utf-8"),
			"binary body not rejected as invalid utf-8: %s" % str(tb.error))
	var empty_tb: Dictionary = await client.transfer_bytes(ch.channel_id, "game/room/heartbeat", PackedByteArray(), 3000)
	_check(empty_tb.has("code"), "empty binary body accepted")

	print("== [6/6] 超时后迟到结果不泄漏 ==")
	var before: int = client._results.size()
	# 1ms 超时护栏必定先于 native 应答返回,随后结果迟到。
	var late: Dictionary = await client.get_channel_unread_count(ch.channel_id, 1, 1)
	for i in range(30):
		await process_frame
	var after: int = client._results.size()
	_check(after <= before, "late result does not accumulate (before=%d after=%d)" % [before, after])

	if failures.is_empty():
		print("VERIFY_OK")
		quit(0)
	else:
		print("VERIFY_FAILED: %s" % ", ".join(failures))
		quit(1)


func _login(mobile: String, data_dir: String):
	var client := DemoEnv.make_client()
	client.data_dir = data_dir
	root.add_child(client)
	var send_resp: Dictionary = await client.send_sms_code(mobile)
	if not send_resp.ok:
		print("send_sms_code failed: %s" % send_resp.error)
		return null
	var code := _read_sms_code(mobile)
	if code.is_empty():
		print("no sms code in redis")
		return null
	var device := PrivchatPlatformAuthClient.default_device_info()
	var http_resp: Dictionary = await client._ensure_auth().login_with_sms(mobile, code, device)
	if not http_resp.ok:
		print("sms-login failed: %s" % http_resp.error)
		return null
	if not client.start():
		print("native start failed")
		return null
	var data: Dictionary = http_resp.data
	var auth_resp: Dictionary = await client.authenticate(data.user_id, data.access_token, data.device_id)
	if not auth_resp.ok:
		print("authenticate failed: %s" % auth_resp.error)
		return null
	var conn_resp: Dictionary = await client.connect_im()
	if not conn_resp.ok:
		print("connect failed: %s" % conn_resp.error)
		return null
	var boot_resp: Dictionary = await client.bootstrap_sync()
	if not boot_resp.ok:
		print("bootstrap failed: %s" % boot_resp.error)
		return null
	await process_frame
	return { "client": client, "user_id": int(data.user_id), "device_id": str(data.device_id) }


func _read_sms_code(mobile: String) -> String:
	for key in ["neton:sms:code:%s" % mobile, "sms:code:%s" % mobile]:
		var output: Array = []
		var rc := OS.execute("redis-cli", ["GET", key], output, true)
		if rc == 0 and not output.is_empty():
			var v: String = output[0].strip_edges()
			if not v.is_empty():
				return v
	return ""
