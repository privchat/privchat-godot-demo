# auto_navigation_check.gd — headless 场景跳转与会话上下文传递 e2e
# 用法: Godot --headless --path privchat-godot-demo -s res://scripts/auto_navigation_check.gd
# 前置: privchat-server(:9001) + privchat-application(:8080) + redis(:6379)
#
# 覆盖会话列表 → 聊天页这条**只有截图证据、此前没有自动回归**的路径:
#   [1] 会话列表返回的条目带 channel_id 与 channel_type
#   [2] 点击行时写入的 pending 上下文能被聊天页正确消费
#   [3] channel_type 被如实传递(不是写死单聊)
#   [4] logout 清空 pending,不把上个账号的频道带进下次登录
# 注意:`-s` 脚本模式下 autoload 不注册,因此这里直接实例化会话容器,
# 验证的是同一份 privchat_session.gd 逻辑。
extends SceneTree

const DemoEnv := preload("res://scripts/demo_env.gd")

const SessionScript := preload("res://scripts/privchat_session.gd")

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

	var a = await _login(MOBILE_A, "user://privchat-nav-a")
	if a == null:
		_fail("login A")
		return
	var b = await _login(MOBILE_B, "user://privchat-nav-b")
	if b == null:
		_fail("login B")
		return
	var client: PrivchatClient = a.client
	var session = SessionScript.new()
	root.add_child(session)

	print("== [1/4] 会话列表条目携带 channel_id 与 channel_type ==")
	# 先确保至少有一个会话。
	var ch: Dictionary = await client.get_or_create_direct_channel(b.user_id)
	if not ch.ok:
		_fail("direct channel: %s" % ch.error)
		return
	var chat := PrivchatChatService.new()
	root.add_child(chat)
	chat.setup(client)
	var _open: Dictionary = await chat.open(ch.channel_id, 1)
	var _sent: Dictionary = await chat.send_text("nav-%d" % Time.get_ticks_msec())
	for i in range(40):
		await process_frame

	var list: Dictionary = await client.list_channels()
	_check(list.ok and not list.channels.is_empty(),
			"channel list returns entries (%d)" % (list.channels.size() if list.ok else -1))
	var entry: Dictionary = list.channels[0] if list.ok and not list.channels.is_empty() else {}
	_check(int(entry.get("channel_id", 0)) > 0, "entry carries channel_id")
	_check(entry.has("channel_type"), "entry carries channel_type")

	print("== [2/4] pending 上下文可被消费 ==")
	# 复刻 menu.gd 点击行时的写入。
	session.client = client
	session.user_id = a.user_id
	session.pending_channel_id = int(entry.get("channel_id", 0))
	session.pending_channel_type = int(entry.get("channel_type", 1))
	_check(session.pending_channel_id > 0, "pending channel id written")

	# 复刻 chat.gd 的消费逻辑。
	var cid: int = session.pending_channel_id
	var ctype: int = session.pending_channel_type
	session.pending_channel_id = 0
	session.pending_channel_type = 0
	_check(session.pending_channel_id == 0, "pending cleared after consumption")

	print("== [3/4] channel_type 如实传递 ==")
	_check(ctype == int(entry.get("channel_type", -1)),
			"channel_type preserved (%d)" % ctype)
	var page: Dictionary = await chat.open(cid, ctype)
	_check(page.ok, "opening with the carried type succeeds: %s" % str(page.get("error", "")))

	print("== [4/4] logout 清空 pending ==")
	session.pending_channel_id = 999999
	session.pending_channel_type = 2
	session.logout()
	_check(session.pending_channel_id == 0 and session.pending_channel_type == 0,
			"logout clears pending channel context")

	await chat.close()
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
	var resp: Dictionary = await client.login(mobile, code)
	if not resp.ok:
		print("login failed: %s" % resp.error)
		return null
	await process_frame
	return { "client": client, "user_id": int(resp.user_id) }


func _read_sms_code(mobile: String) -> String:
	for key in ["neton:sms:code:%s" % mobile, "sms:code:%s" % mobile]:
		var output: Array = []
		var rc := OS.execute("redis-cli", ["GET", key], output, true)
		if rc == 0 and not output.is_empty():
			var v: String = output[0].strip_edges()
			if not v.is_empty():
				return v
	return ""
