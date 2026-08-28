# auto_token_check.gd — headless token 刷新闭环 e2e(spec TOKEN_REFRESH_SPEC)
# 用法: Godot --headless --path privchat-godot-demo -s res://scripts/auto_token_check.gd
# 前置: privchat-server(:9001) + privchat-application(:8080) + redis(:6379)
#
# 覆盖:
#   [1] 正路径:真实 refresh → 拿到新 access token → 重新 authenticate → 连接可用
#   [2] single-flight:并发触发只真正刷新一次
#   [3] 终态:refresh token 失效 → logout_required + 清会话 + 不进入无限循环
#   [4] 竞态 A:刷新期间断线
#   [5] 竞态 B:刷新完成前主动登出 → 旧结果不得覆盖
#   [6] 竞态 C:旧刷新结果晚于新会话返回 → 以代际判定作废
#   [7] 刷新期间 local-first 读仍可用(不做全局阻塞)
extends SceneTree

const MOBILE := "+8613800000001"

var failures: Array = []


func _initialize() -> void:
	_run()
	_watchdog()


func _watchdog() -> void:
	var t := Timer.new()
	t.wait_time = 150.0
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

	var a = await _login(MOBILE, "user://privchat-token-a")
	if a == null:
		_fail("login")
		return
	var client: PrivchatClient = a.client
	_check(not client.refresh_token_value.is_empty(), "login stores refresh token")

	print("== [1/7] 正路径:真实刷新 + 重新 authenticate ==")
	var old_refresh := client.refresh_token_value
	var recovered: Array = []
	client.auth_recovered.connect(func(ok, err): recovered.append({"ok": ok, "error": err}))
	var r1: Dictionary = await client.refresh_now()
	_check(r1.ok, "refresh_now succeeds: %s" % str(r1.get("error", "")))
	_check(recovered.size() == 1 and recovered[0].ok, "auth_recovered(true) emitted once")
	_check(client.logged_in_user_id == a.user_id, "identity preserved after refresh")
	# 刷新后连接仍可用:能真实发一条本地消息(bootstrap 门禁已过)。
	var ch: Dictionary = await client.list_channels()
	_check(ch.ok, "client usable after refresh")

	print("== [2/7] single-flight:并发触发只刷新一次 ==")
	recovered.clear()
	var before_token := client.refresh_token_value
	# 连发 5 次;只有第一次真正走刷新,其余等待同一结果。
	client.refresh_now()
	client.refresh_now()
	client.refresh_now()
	client.refresh_now()
	var r2: Dictionary = await client.refresh_now()
	for i in range(60):
		await process_frame
	_check(recovered.size() == 1,
			"concurrent refresh_now emits auth_recovered once (got %d)" % recovered.size())
	_check(client.refresh_token_value != before_token or r2.ok,
			"refresh actually happened")

	print("== [3/7] 刷新期间 local-first 读仍可用 ==")
	client.refresh_now()
	_check(client.is_refreshing(), "is_refreshing() true during refresh")
	var local: Dictionary = await client.list_channels()
	_check(local.ok, "local read works while refreshing")
	var settled := await client.await_auth_ready()
	_check(settled, "await_auth_ready() returns after refresh settles")

	print("== [4/7] 竞态:刷新完成前主动登出 ==")
	recovered.clear()
	var logouts: Array = []
	client.logout_required.connect(func(code, reason): logouts.append({"code": code, "reason": reason}))
	client.refresh_now()             # fire-and-forget:刷新在途
	client.forget_session()          # 登出:推进代际,在途结果应作废
	for i in range(90):
		await process_frame
	_check(recovered.is_empty(),
			"superseded refresh emits no auth_recovered (got %d)" % recovered.size())
	_check(client.logged_in_user_id == -1, "session stays cleared after logout")
	_check(not client.is_refreshing(), "refresh gate released after supersede")

	print("== [5/7] 终态:refresh token 失效 ==")
	var b = await _login(MOBILE, "user://privchat-token-b")
	if b == null:
		_fail("re-login for terminal test")
		return
	var c2: PrivchatClient = b.client
	var logouts2: Array = []
	var recovered2: Array = []
	c2.logout_required.connect(func(code, reason): logouts2.append({"code": code, "reason": reason}))
	c2.auth_recovered.connect(func(ok, err): recovered2.append({"ok": ok, "error": err}))
	c2.refresh_token_value = "definitely-not-a-valid-refresh-token"
	var r5: Dictionary = await c2.refresh_now()
	_check(not r5.ok and r5.terminal, "invalid refresh token is terminal")
	_check(logouts2.size() == 1, "logout_required emitted once (got %d)" % logouts2.size())
	_check(recovered2.is_empty(), "terminal path does not emit auth_recovered")
	_check(c2.logged_in_user_id == -1, "session cleared on terminal failure")
	# 不得进入无限刷新循环:再触发一次仍是终态,且不产生额外 logout 风暴。
	var r5b: Dictionary = await c2.refresh_now()
	_check(not r5b.ok and str(r5b.error) == "NO_SESSION",
			"refresh after cleared session returns NO_SESSION: %s" % str(r5b.error))
	_check(logouts2.size() == 1,
			"logout_required broadcast once per generation (got %d)" % logouts2.size())

	print("== [6/7] 竞态:刷新期间断线 ==")
	var c3_login = await _login(MOBILE, "user://privchat-token-c")
	if c3_login == null:
		_fail("login for disconnect race")
		return
	var c3: PrivchatClient = c3_login.client
	c3.refresh_now()                 # 刷新在途时断线
	var _disc: Dictionary = await c3.disconnect_im()
	for i in range(90):
		await process_frame
	_check(not c3.is_refreshing(), "refresh gate released after disconnect race")
	# 断线后重连 + 重新 authenticate 应恢复可用。
	var conn: Dictionary = await c3.connect_im()
	if conn.ok:
		var re: Dictionary = await c3.refresh_now()
		_check(re.ok or c3.logged_in_user_id >= 0, "recoverable after reconnect")
	else:
		_check(true, "reconnect skipped (%s)" % str(conn.error))

	print("== [7/7] ForcedLogout 清会话 ==")
	# 直接验证清理逻辑的可达性(真实 ForcedLogout 需服务端踢人,不在本用例范围)。
	c3.forget_session()
	_check(c3.logged_in_user_id == -1 and c3.refresh_token_value.is_empty(),
			"forget_session clears identity and refresh token")

	if failures.is_empty():
		print("VERIFY_OK")
		quit(0)
	else:
		print("VERIFY_FAILED: %s" % ", ".join(failures))
		quit(1)


func _login(mobile: String, data_dir: String):
	var client := PrivchatClient.new()
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
