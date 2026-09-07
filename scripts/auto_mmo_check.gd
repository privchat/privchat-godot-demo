# auto_mmo_check.gd — headless MMORPG 场景 e2e(module-mmorpg 对接验收)
# 用法: Godot --headless --path privchat-godot-demo -s res://scripts/auto_mmo_check.gd
# 前置: privchat-server(:9001) + privchat-application(含 module-mmorpg,:8080) + redis
#
# 覆盖(MMO_WORLD_SCENE_SPEC §12 的闭环):
#   [0] 后台开场景:admin 登录 → POST /admin/mmo/scenes(幂等);玩家进未开的场景 → 21600
#   [1] 双账号登录,各自 ensure 角色
#   [2] A enter 场景 → channel + ticket + scene_session,订阅 Room
#   [3] A 心跳 mmorpg/scene/heartbeat → code 0,回报 public_scene_seq
#   [4] B enter 同一场景 → A 收到 scene.role_entered(B),且落在同一 channel
#   [5] 错误码原样到达:别人的 session → 21607;未知 route → 21610
#   [6] 重连恢复:private-snapshot 拿回同一 scene_session_id;A 重进 → epoch+1,旧 session 心跳 → 21601
#   [7] A move_to → ACK;B 收到 scene.movement_started(A) 的权威路径;越界 21603;
#       目标在障碍另一侧 → 服务端寻路绕行(path_points ≥ 2);NPC 交互:太远 21612 → 走近后 ok;
#       同 request_id 重试 → replayed;旧序号 → 21605;stop 占用序号;snapshot 带位置
#   [8] A 走到可战 NPC → interact options 含 "battle" → 发起战斗(READY,战斗 Room 订阅);
#       战斗中 move → 21613;PRIVATE 定向 transfer 推来 slots_offered(SDK TransferReceived);
#       private snapshot 给 open_slots;提交 ATTACK → ACK 且收到 command_accepted;旧回合重提 → 21402;
#       打到结算:public 收到 phase_changed / initiative_resolved / damage_dealt / battle_settled;
#       重新 enter 场景(epoch+1)→ 退订战斗 Room → 又能移动(MMO_BATTLE_PROTOCOL_SPEC §15.8)
#   [9] B leave → A 收到 scene.role_left;public snapshot 只剩 A
extends SceneTree

const DemoEnv := preload("res://scripts/demo_env.gd")
# 直接 preload 而不靠 class_name 全局缓存:headless -s 不会重扫新脚本。
const DemoMmoSceneService := preload("res://scripts/mmo_scene_service.gd")

const MOBILE_A := "+8613800000001"
const MOBILE_B := "+8613800000002"
const SCENE := "l-10023-7"
## 后台账号(共享开发环境的种子管理员);场景是运营内容,由后台开,玩家进不了没开的场景。
var ADMIN_API := DemoEnv.service_api().replace(":9090", ":8080") + "/admin"
const ADMIN_USER := "admin"
const ADMIN_PASSWORD := "admin123"

var presence_a: Array = []
var moves_b: Array = []
var battle_events: Array = []
var battle_private_events: Array = []


func _initialize() -> void:
	_run()
	_watchdog()


func _watchdog() -> void:
	var t := Timer.new()
	t.wait_time = 240.0
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

	print("== [0/9] 后台开场景 %s ==" % SCENE)
	var admin_token := await _admin_login()
	if admin_token.is_empty():
		_fail("admin login")
		return
	var opened: Dictionary = await _admin_post(admin_token, "/mmo/scenes", { "scene_ref": SCENE })
	if not opened.ok:
		_fail("admin open scene: %s" % opened.error)
		return
	print("scene open: channel_id=%s status=%s" % [str(opened.data.channel_id), str(opened.data.status)])

	print("== [1/9] 双账号登录 + ensure 角色 ==")
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

	# 没开的场景进不去:这是后台开场景这条规则在客户端看到的样子。
	var closed: Dictionary = await mmo_a.enter("l-424242-1", a.device_id)
	if closed.code != 21600:
		_fail("entering an unopened scene must be 21600, got code=%d %s" % [closed.code, closed.error])
		return
	print("  ok: unopened scene -> 21600")

	print("== [2/9] A enter %s ==" % SCENE)
	var ea: Dictionary = await mmo_a.enter(SCENE, a.device_id)
	if not ea.ok:
		_fail("enter A: %s" % ea.error)
		return
	print("A: channel=%d session=%d epoch=%d" % [mmo_a.channel_id, mmo_a.scene_session_id, mmo_a.session_epoch])

	print("== [3/9] A heartbeat ==")
	var hb: Dictionary = await mmo_a.heartbeat()
	if not hb.ok or int(hb.data.get("scene_session_id", 0)) != mmo_a.scene_session_id:
		_fail("heartbeat A: code=%d %s data=%s" % [hb.code, hb.error, JSON.stringify(hb.data)])
		return
	print("heartbeat ok: server_time_ms=%d public_scene_seq=%d" % [int(hb.data.server_time_ms), int(hb.data.public_scene_seq)])

	print("== [4/9] B enter 同一场景 → A 收到 role_entered ==")
	var eb: Dictionary = await mmo_b.enter(SCENE, b.device_id)
	if not eb.ok:
		_fail("enter B: %s" % eb.error)
		return
	if mmo_b.channel_id != mmo_a.channel_id or mmo_a.channel_id <= 0:
		_fail("scene channel differs: A=%d B=%d (idempotent provisioning broken)" % [mmo_a.channel_id, mmo_b.channel_id])
		return
	var ev = await _wait_presence("scene.role_entered", mmo_b.role_id, 15000)
	if ev == null:
		_fail("A never saw role_entered for B: %s" % JSON.stringify(presence_a))
		return
	print("A saw: %s" % JSON.stringify(ev))

	print("== [5/9] 业务错误码原样到达 GDScript ==")
	var stolen: Dictionary = await mmo_a.heartbeat(mmo_b.scene_session_id)
	if stolen.code != 21607:
		_fail("someone else's session must be 21607, got code=%d %s" % [stolen.code, stolen.error])
		return
	var unknown: Dictionary = await mmo_a.transfer("mmorpg/scene/teleport", { "protocol_version": 1 })
	if unknown.code != 21610:
		_fail("unimplemented route must be 21610, got code=%d %s" % [unknown.code, unknown.error])
		return
	print("  ok: 21607 / 21610 survived application -> GDScript")

	print("== [6/9] 重连恢复 + 重进使旧 session 失效 ==")
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

	print("== [7/9] A move_to → B 收到 movement_started;拒绝码;幂等回放;stop ==")
	var target_x := int(DemoMmoSceneService.FIXED * 70)
	var target_y := int(DemoMmoSceneService.FIXED * 40)
	# Room 会给迟到的订阅者回放历史广播:B 订阅时已经收到了以前跑出来的旧移动事件。
	# 只认这次 move_to 之后、序号匹配的那条。
	moves_b.clear()
	var mv: Dictionary = await mmo_a.move_to(target_x, target_y)
	if not mv.ok or int(mv.data.get("accepted_movement_seq", 0)) != 1 or bool(mv.data.get("replayed", true)):
		_fail("move_to: code=%d %s data=%s" % [mv.code, mv.error, JSON.stringify(mv.data)])
		return
	var started = await _wait_move(mmo_a.role_id, int(mv.data.accepted_movement_seq), 15000)
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
	var stale_seq: Dictionary = await mmo_a.transfer_fb(DemoMmoSceneService.ROUTE_MOVE,
		"scene_move_intent", DemoMmoSceneService.NS_SCENE + "MoveIntentEnvelope", {
			"protocol_version": 1, "scene_session_id": mmo_a.scene_session_id, "movement_seq": 1,
			"command": { "move_to": { "target_position": { "x": 1000, "y": 1000 } } }, "client_time_ms": 1,
		}, "scene_move_ack", DemoMmoSceneService.NS_SCENE + "MoveIntentAck")
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

	# 寻路:种子地图「长安城郊」在 x 65..100、y 55..62.5 有一堵墙,从出生点 (50,50)
	# 到 (90,66) 的直线必穿墙,服务端必须绕行。
	var detour: Dictionary = await mmo_a.move_to(90 * DemoMmoSceneService.FIXED, 66 * DemoMmoSceneService.FIXED)
	if not detour.ok:
		_fail("detour move: code=%d %s" % [detour.code, detour.error])
		return
	var snap3: Dictionary = await mmo_a.public_snapshot()
	var me3 = null
	for r in snap3.data.roles:
		if int(r.role_id) == mmo_a.role_id:
			me3 = r
	var det_pts: Array = me3.state.movement.path_points if me3 != null and me3.state.get("movement") != null else []
	if det_pts.size() < 2:
		_fail("path around the obstacle must have >= 2 points, got %s" % JSON.stringify(det_pts))
		return
	var blocked: Dictionary = await mmo_a.move_to(80 * DemoMmoSceneService.FIXED, 58 * DemoMmoSceneService.FIXED)
	if blocked.code != 21603:
		_fail("target inside an obstacle must be 21603, got code=%d" % blocked.code)
		return
	mmo_a.movement_seq -= 1
	# NPC:从当前位置直接交互太远 → 21612;走到旁边(等到达)再交互 → 对话。
	var npc_id := int(snap3.data.npcs[0].npc_id)
	var npc_pos: Dictionary = snap3.data.npcs[0].position
	var far: Dictionary = await mmo_a.interact(npc_id)
	if far.code != 21612:
		_fail("interact from far away must be 21612, got code=%d %s" % [far.code, far.error])
		return
	var walk: Dictionary = await mmo_a.move_to(int(npc_pos.x) + 1500, int(npc_pos.y))
	if not walk.ok:
		_fail("walk to npc: code=%d %s" % [walk.code, walk.error])
		return
	# 等服务端权威位置走到:按快照里的路径参数算到达时刻,再稍等一点。
	var arrive_deadline := Time.get_ticks_msec() + 40000
	var near := false
	while Time.get_ticks_msec() < arrive_deadline:
		var probe: Dictionary = await mmo_a.interact(npc_id)
		if probe.ok:
			print("NPC %s:%s" % [probe.data.name, probe.data.dialog])
			near = true
			break
		if probe.code != 21612:
			_fail("interact: code=%d %s" % [probe.code, probe.error])
			return
		var t := Timer.new()
		t.wait_time = 1.0
		t.one_shot = true
		t.autostart = true
		root.add_child(t)
		await t.timeout
		t.queue_free()
	if not near:
		_fail("never got within interact range of npc %d" % npc_id)
		return
	print("  ok: detour (%d points) / 21603 in obstacle / 21612 then dialog" % det_pts.size())

	print("== [8/9] 战斗:走到可战 NPC → 发起 → 提交指令 → 结算 → 回场景 ==")
	mmo_a.battle_event.connect(func(_bid, e, seq): battle_events.append({ "seq": seq, "event": e }))
	mmo_a.battle_private_event.connect(func(_bid, e, seq): battle_private_events.append({ "seq": seq, "event": e }))
	var monster = null
	for n in snap3.data.npcs:
		if str(n.kind) == "monster":
			monster = n
	if monster == null:
		_fail("seed map has no monster npc: %s" % JSON.stringify(snap3.data.npcs))
		return
	var walk2: Dictionary = await mmo_a.move_to(int(monster.position.x) - 1500, int(monster.position.y))
	if not walk2.ok:
		_fail("walk to monster: code=%d %s" % [walk2.code, walk2.error])
		return
	var options: Array = []
	var walk_deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < walk_deadline:
		var probe2: Dictionary = await mmo_a.interact(int(monster.npc_id))
		if probe2.ok:
			options = probe2.data.get("options", [])
			break
		if probe2.code != 21612:
			_fail("interact monster: code=%d %s" % [probe2.code, probe2.error])
			return
		await _sleep(1.0)
	if not options.has("battle"):
		_fail("monster npc must offer 'battle', got %s" % JSON.stringify(options))
		return
	var entry: Dictionary = await mmo_a.start_battle(int(monster.npc_id), a.device_id)
	if not entry.ok or str(entry.data.status) != "READY":
		_fail("start battle: code=%d %s data=%s" % [entry.code, entry.error, JSON.stringify(entry.data)])
		return
	print("battle %d on channel %d (transition %d)" % [mmo_a.battle_id, mmo_a.battle_channel_id, mmo_a.transition_id])
	var locked: Dictionary = await mmo_a.move_to(1000, 1000)
	if locked.code != 21613:
		_fail("moving while in battle must be 21613, got code=%d %s" % [locked.code, locked.error])
		return
	mmo_a.movement_seq -= 1
	var resumed: Dictionary = await mmo_a.resume_battle(mmo_a.transition_id)
	if not resumed.ok or int(resumed.data.battle_id) != mmo_a.battle_id:
		_fail("resume via transition: code=%d %s" % [resumed.code, resumed.error])
		return
	# PRIVATE 事件:服务端定向 transfer → SDK TransferReceived → PrivchatSubscription.transfer_received。
	# 第一批 slots_offered 在订阅战斗 Room 之前就发出;server 对未订阅的会话投递失败,outbox 在
	# 下一次 tick 补投,所以这里要等。
	var offered = await _wait_private_event("slots_offered", 15000)
	if offered == null:
		_fail("never received slots_offered over directed transfer: %s" % JSON.stringify(battle_private_events))
		return
	var offered_slots: Array = offered.event.payload.slots_offered.slots
	if offered_slots.size() != 1 or not offered_slots[0].allowed_commands.has("ATTACK"):
		_fail("slots_offered must carry one PRIMARY slot allowing ATTACK: %s" % JSON.stringify(offered_slots))
		return
	var bs: Dictionary = await mmo_a.battle_private_snapshot()
	if not bs.ok or str(bs.data.phase) != "COMMAND" or bs.data.open_slots.size() != 1:
		_fail("battle private snapshot: code=%d %s data=%s" % [bs.code, bs.error, JSON.stringify(bs.data)])
		return
	var slot0: Dictionary = bs.data.open_slots[0]
	if not slot0.allowed_commands.has("ATTACK") or int(bs.data.private_actor_states[0].exact_hp) <= 0:
		_fail("slot must allow ATTACK with exact hp: %s" % JSON.stringify(bs.data))
		return
	var pub: Dictionary = await mmo_a.battle_public_snapshot()
	if not pub.ok or pub.data.open_slots.size() != 0 or pub.data.private_actor_states.size() != 0:
		_fail("public snapshot must not leak slots / exact resources: %s" % JSON.stringify(pub.data))
		return
	var first_ack: Dictionary = await mmo_a.submit_command(bs.data, slot0, { "attack": { "selected_target_id": int(bs.data.private_actor_states[0].selectable_target_ids[0]) } })
	if not first_ack.ok or int(first_ack.data.accepted_action_seq) != 1:
		_fail("submit attack: code=%d %s data=%s" % [first_ack.code, first_ack.error, JSON.stringify(first_ack.data)])
		return
	if int(offered_slots[0].command_slot_id) != int(slot0.command_slot_id):
		_fail("pushed slot %s != snapshot slot %s" % [str(offered_slots[0].command_slot_id), str(slot0.command_slot_id)])
		return
	var accepted = await _wait_private_event("command_accepted", 15000)
	if accepted == null or int(accepted.event.payload.command_accepted.accepted_action_seq) != 1:
		_fail("never received command_accepted for seq 1: %s" % JSON.stringify(battle_private_events))
		return
	# 单人单 slot:提交即结算,回合已翻页;拿旧快照再提 → 21402。
	var stale_round: Dictionary = await mmo_a.submit_command(bs.data, slot0, { "defend": {} })
	if stale_round.code != 21402:
		_fail("stale round must be 21402, got code=%d %s" % [stale_round.code, stale_round.error])
		return
	var rounds := 1
	var final_phase := ""
	while rounds < 30:
		var cur: Dictionary = await mmo_a.battle_private_snapshot()
		if not cur.ok:
			if cur.code == 21400:
				final_phase = "CLOSED"
				break
			_fail("battle snapshot: code=%d %s" % [cur.code, cur.error])
			return
		final_phase = str(cur.data.phase)
		if final_phase != "COMMAND":
			break
		var slot: Dictionary = cur.data.open_slots[0]
		var targets: Array = cur.data.private_actor_states[0].selectable_target_ids
		var ack: Dictionary = await mmo_a.submit_command(cur.data, slot, { "attack": { "selected_target_id": int(targets[0]) } })
		if not ack.ok:
			_fail("round %d submit: code=%d %s" % [int(cur.data.round), ack.code, ack.error])
			return
		rounds += 1
	if final_phase != "SETTLE" and final_phase != "CLOSED":
		_fail("battle did not settle after %d rounds (phase=%s)" % [rounds, final_phase])
		return
	var settled = await _wait_battle_event("battle_settled", 15000)
	if settled == null:
		_fail("never saw battle_settled: %s" % JSON.stringify(battle_events))
		return
	var kinds := {}
	for be in battle_events:
		for k in be.event.payload.keys():
			kinds[k] = true
	for want in ["phase_changed", "initiative_resolved", "damage_dealt", "battle_settled"]:
		if not kinds.has(want):
			_fail("missing public battle event %s, saw %s" % [want, JSON.stringify(kinds.keys())])
			return
	print("battle settled after %d rounds: winner_side=%d events=%s" % [rounds, int(settled.event.payload.battle_settled.winner_side), JSON.stringify(kinds.keys())])
	# 退出战斗的正路:先重新 enter 场景(epoch+1),再退订战斗 Room;之后又能移动。
	var epoch_before := mmo_a.session_epoch
	var back: Dictionary = await mmo_a.enter(SCENE, a.device_id)
	if not back.ok or mmo_a.session_epoch != epoch_before + 1:
		_fail("re-enter after battle: code=%d %s epoch %d -> %d" % [back.code, back.error, epoch_before, mmo_a.session_epoch])
		return
	await mmo_a.leave_battle()
	var free: Dictionary = await mmo_a.move_to(50 * DemoMmoSceneService.FIXED, 50 * DemoMmoSceneService.FIXED)
	if not free.ok:
		_fail("move after battle: code=%d %s" % [free.code, free.error])
		return
	print("  ok: 21613 in battle / transition resume / slots via directed transfer + snapshot / command_accepted / 21402 / settled / back in scene")

	print("== [9/9] B leave → A 收到 role_left;snapshot 只剩 A ==")
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


func _admin_login() -> String:
	var req := HTTPRequest.new()
	root.add_child(req)
	var err: int = req.request(ADMIN_API + "/system/auth/login", ["Content-Type: application/json"],
			HTTPClient.METHOD_POST, JSON.stringify({ "username": ADMIN_USER, "password": ADMIN_PASSWORD }))
	if err != OK:
		req.queue_free()
		return ""
	var resp: Array = await req.request_completed
	req.queue_free()
	var parsed = JSON.parse_string(resp[3].get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or int(parsed.get("code", -1)) != 0:
		print("admin login failed: %s" % str(parsed))
		return ""
	return str(parsed.data.get("accessToken", ""))


func _admin_post(token: String, path: String, body: Dictionary) -> Dictionary:
	var req := HTTPRequest.new()
	root.add_child(req)
	var err: int = req.request(ADMIN_API + path,
			["Content-Type: application/json", "Authorization: Bearer %s" % token],
			HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		req.queue_free()
		return { "ok": false, "error": "http request error %d" % err }
	var resp: Array = await req.request_completed
	req.queue_free()
	var parsed = JSON.parse_string(resp[3].get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or int(parsed.get("code", -1)) != 0:
		return { "ok": false, "error": str(parsed) }
	return { "ok": true, "data": parsed.data }


func _wait_private_event(payload_key: String, timeout_ms: int):
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		for e in battle_private_events:
			if e.event.payload.has(payload_key):
				return e
		await process_frame
	return null


func _wait_battle_event(payload_key: String, timeout_ms: int):
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		for e in battle_events:
			if e.event.payload.has(payload_key):
				return e
		await process_frame
	return null


func _sleep(seconds: float) -> void:
	var t := Timer.new()
	t.wait_time = seconds
	t.one_shot = true
	t.autostart = true
	root.add_child(t)
	await t.timeout
	t.queue_free()


func _wait_move(entity_id: int, movement_seq: int, timeout_ms: int):
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		for e in moves_b:
			if e.entity_id == entity_id and int(e.movement.get("movement_seq", -1)) == movement_seq:
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
