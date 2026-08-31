# auto_login_check.gd — headless 自动化登录链路验证
# 用法: Godot --headless --path privchat-godot-demo -s res://scripts/auto_login_check.gd
# 前置: privchat-server(:9001) + privchat-application(:8080) + redis(:6379) 均在运行
# 注意: 验证码由 MemberAuthLogic 随机生成并存入 Redis（无短信通道时的 fallback），
#       本脚本直接通过 redis-cli 读取，无需真实短信。
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

	print("== [2/5] send_sms_code ==")
	var send_resp: Dictionary = await client.send_sms_code(MOBILE)
	print("send_sms_code -> ", JSON.stringify(send_resp))
	if not send_resp.ok:
		print("VERIFY_FAILED: send_sms_code")
		quit(1)
		return

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
		return
	print("sms_code = %s" % code)

	print("== [4/5] login 分步：sms-login -> authenticate -> connect -> bootstrap ==")
	var device := PrivchatPlatformAuthClient.default_device_info()
	print("device_id = %s" % device.deviceId)
	var http_resp: Dictionary = await client._ensure_auth().login_with_sms(MOBILE, code, device)
	print("sms-login -> ", JSON.stringify(http_resp))
	if not http_resp.ok:
		print("VERIFY_FAILED: sms-login")
		quit(1)
		return
	var data: Dictionary = http_resp.data
	print("user_id=%d device_id=%s" % [data.user_id, data.device_id])

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
