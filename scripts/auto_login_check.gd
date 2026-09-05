# auto_login_check.gd — headless 自动化登录链路验证
# 用法: Godot --headless --path privchat-godot-demo -s res://scripts/auto_login_check.gd
# 前置: privchat-server(:9001) + privchat-application(:8080) + redis(:6379) 均在运行
#
# 登录方式先从 GET /config/bootstrap 拉(privchat.conf [auth] register_modes):
#   USERNAME_PASSWORD → 注册新账号 → 账号密码登录 → 错误密码必须被拒
#   PHONE_SMS         → 发验证码 → 从 Redis 读码(无短信通道时的 fallback)→ sms-login
# 之后同路:authenticate → connect → bootstrap_sync。
extends SceneTree

const DemoEnv := preload("res://scripts/demo_env.gd")

# 服务端要求 E.164 格式（MemberAuthLogic 不自动 prepend 区号）。
const MOBILE := "+8613800000001"
const RAW_MOBILE := "13800000001"

func _initialize() -> void:
	_run()


func _run() -> void:
	# 等主循环开始处理，确保节点树就绪（-s 模式下 _initialize 早于首帧）。
	await process_frame
	await process_frame

	print("== [1/5] 创建 PrivchatClient ==")
	var client := DemoEnv.make_client()
	root.add_child(client)

	print("== [1b/5] GET /config/bootstrap:登录方式由服务端配置决定 ==")
	var boot: Dictionary = await client.fetch_bootstrap()
	if not boot.ok:
		print("VERIFY_FAILED: fetch_bootstrap: %s" % boot.error)
		quit(1)
		return
	var modes: Array = boot.data.register_modes
	print("register_modes=%s default=%s config_version=%s" % [JSON.stringify(modes), boot.data.default_register_mode, boot.data.config_version])
	var device := PrivchatPlatformAuthClient.default_device_info()
	print("device_id = %s" % device.deviceId)
	var http_resp: Dictionary
	if modes.has(PrivchatPlatformAuthClient.MODE_USERNAME_PASSWORD):
		# 账号密码模式:注册一个新账号(注册即签发 token),再用同一账号密码登录一次,
		# 两条路都得通。
		var username := "gd%d" % (Time.get_unix_time_from_system() as int % 100000000)
		var password := "Godot-e2e-%d" % randi()
		print("== [2/5] register(USERNAME_PASSWORD) %s ==" % username)
		var reg: Dictionary = await client._ensure_auth().register_with_username(username, password, device)
		print("register -> ", JSON.stringify(reg).substr(0, 160))
		if not reg.ok:
			print("VERIFY_FAILED: register")
			quit(1)
			return
		print("== [3/5] login-username ==")
		http_resp = await client._ensure_auth().login_with_username(username, password, device)
		print("login-username -> ", JSON.stringify(http_resp).substr(0, 160))
		if not http_resp.ok or int(http_resp.data.user_id) != int(reg.data.user_id):
			print("VERIFY_FAILED: login-username (user_id %s vs %s)" % [str(http_resp.data.get("user_id")), str(reg.data.user_id)])
			quit(1)
			return
		var wrong: Dictionary = await client._ensure_auth().login_with_username(username, password + "x", device)
		if wrong.ok:
			print("VERIFY_FAILED: wrong password must be rejected")
			quit(1)
			return
		print("  ok: wrong password rejected: %s" % wrong.error)
	elif modes.has(PrivchatPlatformAuthClient.MODE_PHONE_SMS):
		http_resp = await _sms_login(client, device)
		if http_resp.is_empty():
			return
	else:
		print("VERIFY_FAILED: no supported register mode in %s" % JSON.stringify(modes))
		quit(1)
		return
	var data: Dictionary = http_resp.data
	print("user_id=%d device_id=%s" % [data.user_id, data.device_id])
	await _finish(client, data)


## 手机号模式:发验证码 → 从 Redis 读码 → sms-login。失败时自行 quit 并返回 {}。
func _sms_login(client: PrivchatClient, device: Dictionary) -> Dictionary:
	print("== [2/5] send_sms_code ==")
	var send_resp: Dictionary = await client.send_sms_code(MOBILE)
	print("send_sms_code -> ", JSON.stringify(send_resp))
	if not send_resp.ok:
		print("VERIFY_FAILED: send_sms_code")
		quit(1)
		return {}

	print("== [3/5] 从 Redis 读取验证码（开发环境无短信通道） ==")
	# Neton 框架 redis wrapper 自动加 "neton:" 前缀：neton:sms:code:<mobile>
	var code := ""
	for key in ["neton:sms:code:%s" % MOBILE, "neton:sms:code:%s" % RAW_MOBILE,
			"sms:code:%s" % MOBILE]:
		var output: Array = []
		var rc := OS.execute("redis-cli", ["GET", key], output, true)
		if rc == 0 and not output.is_empty():
			var v: String = output[0].strip_edges()
			if not v.is_empty():
				code = v
				print("验证码来自 key %s" % key)
				break
	if code.is_empty():
		print("VERIFY_FAILED: 无法从 Redis 读取验证码")
		quit(1)
		return {}
	print("sms_code = %s" % code)

	print("== [3/5] sms-login ==")
	var http_resp: Dictionary = await client._ensure_auth().login_with_sms(MOBILE, code, device)
	print("sms-login -> ", JSON.stringify(http_resp))
	if not http_resp.ok:
		print("VERIFY_FAILED: sms-login")
		quit(1)
		return {}
	return http_resp


## 拿到 token 之后三种方式同路:authenticate -> connect -> bootstrap。
func _finish(client: PrivchatClient, data: Dictionary) -> void:
	print("== [4/5] authenticate -> connect -> bootstrap ==")
	if not client.start():
		print("VERIFY_FAILED: native start")
		quit(1)
		return
	print("native initialized")

	var auth_resp: Dictionary = await client.authenticate(data.user_id, data.access_token, data.device_id)
	print("authenticate -> ", JSON.stringify(auth_resp))
	if not auth_resp.ok:
		print("VERIFY_FAILED: authenticate")
		quit(1)
		return

	var conn_resp: Dictionary = await client.connect_im()
	print("connect -> ", JSON.stringify(conn_resp))
	if not conn_resp.ok:
		print("VERIFY_FAILED: connect")
		quit(1)
		return

	# bootstrap 是本地优先门禁：不完成它，后续发消息等本地操作全部被
	# SDK 拒绝（invalid state: run_bootstrap_sync required），登录不算成功。
	var boot_resp: Dictionary = await client.bootstrap_sync()
	print("bootstrap -> ", JSON.stringify(boot_resp))
	if not boot_resp.ok:
		print("VERIFY_FAILED: bootstrap_sync")
		quit(1)
		return
	client.logged_in_user_id = data.user_id
	client.logged_in_device_id = data.device_id
	var login_resp := { "ok": true, "user_id": data.user_id }

	print("== [5/5] 等待事件并检查连接状态 ==")
	await process_frame
	await process_frame
	var state: String = client.connection_state()
	print("connection_state = %s" % state)
	var snapshot: Dictionary = client.session_snapshot()
	print("session_snapshot = %s" % JSON.stringify(snapshot))
	var events: Array = client.recent_events(20)
	print("recent_events count = %d" % events.size())
	for e in events:
		print("  event: %s" % JSON.stringify(e).substr(0, 200))

	if state == "Authenticated" or state == "Connected":
		print("VERIFY_OK")
		quit(0)
	else:
		print("VERIFY_FAILED: unexpected connection_state=%s" % state)
		quit(1)
