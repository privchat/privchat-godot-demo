# auto_mmo_check.gd — headless MMORPG 场景 e2e(module-mmorpg 对接验收)
# 用法: Godot --headless --path privchat-godot-demo -s res://scripts/auto_mmo_check.gd
# 前置: privchat-server(:9001) + privchat-application(含 module-mmorpg,:8080) + redis
#
# 覆盖(MMO_WORLD_SCENE_SPEC §12 的闭环):
#   [1] 双账号登录,各自 ensure 角色
#   [2] A enter 场景 → channel + ticket + scene_session,订阅 Room
#   [3] A 心跳 mmorpg/scene/heartbeat → code 0,回报 public_scene_seq
#   [4] B enter 同一场景 → A 收到 scene.role_entered(B),且落在同一 channel
#   [5] 错误码原样到达:别人的 session → 21607;未知 route → 21610
#   [6] 重连恢复:private-snapshot 拿回同一 scene_session_id;A 重进 → epoch+1,旧 session 心跳 → 21601
#   [7] A move_to → ACK;B 收到 scene.movement_started(A) 的权威路径;越界 21603;
#       同 request_id 重试 → replayed;旧序号 → 21605;stop 占用序号;snapshot 带位置
#   [8] B leave → A 收到 scene.role_left;public snapshot 只剩 A
extends SceneTree

const DemoEnv := preload("res://scripts/demo_env.gd")
# 直接 preload 而不靠 class_name 全局缓存:headless -s 不会重扫新脚本。
const DemoMmoSceneService := preload("res://scripts/mmo_scene_service.gd")

const MOBILE_A := "+8613800000001"
const MOBILE_B := "+8613800000002"
const SCENE := "l-10023-7"

var presence_a: Array = []
var moves_b: Array = []


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

	print("== [1/8] 双账号登录 + ensure 角色 ==")
	var a = await _login(MOBILE_A, "user://privchat-mmo-a")
	if a == null:
		_fail("login A")
		return
	var b = await _login(MOBILE_B, "user://privchat-mmo-b")
	if b == null:
		_fail("login B")
		return
	var mmo_a := DemoMmoSceneService.new()
	root.add_child(mmo_a)
	mmo_a.setup(a.client, a.access_token)
	var mmo_b := DemoMmoSceneService.new()
	root.add_child(mmo_b)
	mmo_b.setup(b.client, b.access_token)
	mmo_a.presence.connect(func(event, rid, rname, seq, _raw):
		presence_a.append({ "event": event, "role_id": rid, "role_name": rname, "seq": seq }))
	mmo_b.movement_started.connect(func(eid, movement, seq):
		moves_b.append({ "entity_id": eid, "movement": movement, "seq": seq }))

	var ra: Dictionary = await mmo_a.ensure_role("godot-a-%d" % a.user_id)
	if not ra.ok:
		_fail("ensure role A: %s" % ra.error)
		return
	var rb: Dictionary = await mmo_b.ensure_role("godot-b-%d" % b.user_id)
	if not rb.ok:
		_fail("ensure role B: %s" % rb.error)
		return
	print("roles: A=%d B=%d" % [mmo_a.role_id, mmo_b.role_id])

	print("== [2/8] A enter %s ==" % SCENE)
	var ea: Dictionary = await mmo_a.enter(SCENE, a.device_id)
	if not ea.ok:
		_fail("enter A: %s" % ea.error)
		return
	print("A: channel=%d session=%d epoch=%d" % [mmo_a.channel_id, mmo_a.scene_session_id, mmo_a.session_epoch])

	print("== [3/8] A heartbeat ==")
	var hb: Dictionary = await mmo_a.heartbeat()
	if not hb.ok or int(hb.data.get("scene_session_id", 0)) != mmo_a.scene_session_id:
		_fail("heartbeat A: code=%d %s data=%s" % [hb.code, hb.error, JSON.stringify(hb.data)])
		return
	print("heartbeat ok: server_time_ms=%d public_scene_seq=%d" % [int(hb.data.server_time_ms), int(hb.data.public_scene_seq)])

	print("== [4/8] B enter 同一场景 → A 收到 role_entered ==")
	var eb: Dictionary = await mmo_b.enter(SCENE, b.device_id)
	if not eb.ok:
		_fail("enter B: %s" % eb.error)
		return
	if mmo_b.channel_id != mmo_a.channel_id:
		_fail("scene channel differs: A=%d B=%d (idempotent provisioning broken)" % [mmo_a.channel_id, mmo_b.channel_id])
		return
	var ev = await _wait_presence("scene.role_entered", mmo_b.role_id, 15000)
	if ev == null:
		_fail("A never saw role_entered for B: %s" % JSON.stringify(presence_a))
		return
	print("A saw: %s" % JSON.stringify(ev))

	print("== [5/8] 业务错误码原样到达 GDScript ==")
	var stolen: Dictionary = await mmo_a.heartbeat(mmo_b.scene_session_id)
	if stolen.code != 21607:
		_fail("someone else's session must be 21607, got code=%d %s" % [stolen.code, stolen.error])
		return
	var unknown: Dictionary = await mmo_a.transfer("mmorpg/scene/teleport", { "protocol_version": 1 })
	if unknown.code != 21610:
		_fail("unimplemented route must be 21610, got code=%d %s" % [unknown.code, unknown.error])
		return
	print("  ok: 21607 / 21610 survived application -> GDScript")

	print("== [6/8] 重连恢复 + 重进使旧 session 失效 ==")
	var snap: Dictionary = await mmo_a.private_snapshot()
	if not snap.ok or int(snap.data.scene_session_id) != mmo_a.scene_session_id:
		_fail("private snapshot mismatch: %s" % JSON.stringify(snap))
		return
	var old_session := mmo_a.scene_session_id
	var old_epoch := mmo_a.session_epoch
	var re: Dictionary = await mmo_a.enter(SCENE, a.device_id)
	if not re.ok:
		_fail("re-enter A: %s" % re.error)
		return
	if mmo_a.session_epoch != old_epoch + 1:
		_fail("re-enter must bump epoch: %d -> %d" % [old_epoch, mmo_a.session_epoch])
		return
	var stale: Dictionary = await mmo_a.heartbeat(old_session)
	if stale.code != 21601:
		_fail("stale session must be 21601, got code=%d %s" % [stale.code, stale.error])
		return
	var fresh: Dictionary = await mmo_a.heartbeat()
	if not fresh.ok:
		_fail("fresh session heartbeat: code=%d %s" % [fresh.code, fresh.error])
		return
	print("  ok: session %d -> %d (epoch %d -> %d), stale session rejected" % [old_session, mmo_a.scene_session_id, old_epoch, mmo_a.session_epoch])

	print("== [7/8] A move_to → B 收到 movement_started;拒绝码;幂等回放;stop ==")
	var target_x := int(DemoMmoSceneService.FIXED * 70)
	var target_y := int(DemoMmoSceneService.FIXED * 40)
	var mv: Dictionary = await mmo_a.move_to(target_x, target_y)
	if not mv.ok or int(mv.data.get("accepted_movement_seq", 0)) != 1 or bool(mv.data.get("replayed", true)):
		_fail("move_to: code=%d %s data=%s" % [mv.code, mv.error, JSON.stringify(mv.data)])
		return
	var started = await _wait_move(mmo_a.role_id, 15000)
	if started == null:
		_fail("B never saw movement_started for A: %s" % JSON.stringify(moves_b))
		return
	var m: Dictionary = started.movement
	var pts: Array = m.get("path_points", [])
	if pts.is_empty() or int(pts[0].x) != target_x or int(pts[0].y) != target_y or int(m.get("speed", 0)) <= 0:
		_fail("movement_started path mismatch: %s" % JSON.stringify(m))
		return
	# 权威起点是服务端出生点(50,50),不是客户端自报的。
	var sp: Dictionary = m.get("authoritative_start_position", {})
	if int(sp.get("x", -1)) != 50 * DemoMmoSceneService.FIXED or int(sp.get("y", -1)) != 50 * DemoMmoSceneService.FIXED:
		_fail("authoritative start must be the spawn point, got %s" % JSON.stringify(sp))
		return
	print("B saw A moving: start=(%d,%d) -> (%d,%d) speed=%d path_id=%d" % [sp.x, sp.y, pts[0].x, pts[0].y, int(m.speed), int(m.path_id)])
	var oob: Dictionary = await mmo_a.move_to(-1, 0)
	if oob.code != 21603:
		_fail("out-of-map target must be 21603, got code=%d %s" % [oob.code, oob.error])
		return
	# 被拒的意图不占序号:客户端回退计数,下一条合法意图仍能被受理。
	mmo_a.movement_seq -= 1
	var stale_seq: Dictionary = await mmo_a.transfer(DemoMmoSceneService.ROUTE_MOVE, {
		"protocol_version": 1, "scene_session_id": mmo_a.scene_session_id, "movement_seq": 1,
		"command": { "move_to": { "target_position": { "x": 1000, "y": 1000 } } } })
	if stale_seq.code != 21605:
		_fail("stale movement_seq must be 21605, got code=%d %s" % [stale_seq.code, stale_seq.error])
		return
	var st: Dictionary = await mmo_a.stop()
	if not st.ok or int(st.data.get("accepted_movement_seq", 0)) != 2:
		_fail("stop must take seq 2: code=%d %s data=%s" % [st.code, st.error, JSON.stringify(st.data)])
		return
	var snap2: Dictionary = await mmo_a.public_snapshot()
	var me = null
	for r in snap2.data.roles:
		if int(r.role_id) == mmo_a.role_id:
			me = r
	if me == null or int(me.state.movement_seq) != 2 or me.state.get("movement") != null:
		_fail("snapshot must show A stopped at seq 2: %s" % JSON.stringify(me))
		return
	var px := int(me.state.position.x)
	if px <= 50 * DemoMmoSceneService.FIXED or px >= target_x:
		_fail("stopped position should be strictly between spawn and target, got x=%d" % px)
		return
	print("  ok: 21603 / 21605 / stop@seq2, stopped at (%d,%d)" % [px, int(me.state.position.y)])

	print("== [8/8] B leave → A 收到 role_left;snapshot 只剩 A ==")
	var lb: Dictionary = await mmo_b.leave()
	if not lb.ok:
		_fail("leave B: %s" % lb.error)
		return
	var left = await _wait_presence("scene.role_left", mmo_b.role_id, 15000)
	if left == null:
		_fail("A never saw role_left for B: %s" % JSON.stringify(presence_a))
		return
	var ps: Dictionary = await mmo_a.public_snapshot()
	if not ps.ok:
		_fail("public snapshot: %s" % ps.error)
		return
	var ids: Array = []
	for r in ps.data.roles:
		ids.append(int(r.role_id))
	if ids != [mmo_a.role_id]:
		_fail("snapshot roles want [%d], got %s" % [mmo_a.role_id, JSON.stringify(ids)])
		return
	print("snapshot ok: roles=%s public_scene_seq=%d" % [JSON.stringify(ids), int(ps.data.public_scene_seq)])

	await mmo_a.leave()
	await mmo_a.close()
	await mmo_b.close()
	print("VERIFY_OK")
	quit(0)


func _wait_move(entity_id: int, timeout_ms: int):
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		for e in moves_b:
			if e.entity_id == entity_id:
				return e
		await process_frame
	return null


func _wait_presence(event: String, rid: int, timeout_ms: int):
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		for e in presence_a:
			if e.event == event and e.role_id == rid:
				return e
		await process_frame
	return null


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
