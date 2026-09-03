# mmo.gd — MMORPG 场景(对接 module-mmorpg,spec MMO_WORLD_SCENE_SPEC §12)。
#
# 梦幻西游式的场景交互:点地图 → 角色沿服务端权威路径走过去;别人的角色按
# 广播的路径参数本地插值。客户端不发坐标帧,只发意图(§4.1)。
extends Control

const MmoSceneService := preload("res://scripts/mmo_scene_service.gd")
const SCENE_REF := "l-10023-7"
const MAP_UNITS := 100                      # 服务端平地 100x100 世界单位
const MAP_PX := 560

# 不按 class_name 定类型:headless / 未经编辑器扫描的运行没有全局类缓存。
var service = null
var map_view: Control
var status_label: Label
var log_view: RichTextLabel

## role_id → { name, movement: Dictionary(MovementStarted 镜像) 或 position: Vector2i }
var roles: Dictionary = {}
## 地图静态数据(MapResponse);null = 未加载。
var map_data = null
## npc_id → NpcDto
var npcs: Dictionary = {}
## 服务端时钟 - 本地时钟(ms),由 snapshot 的 server_time_ms 估计。
var clock_offset_ms: int = 0


func _ready() -> void:
	if not PrivchatSession.has_session():
		get_tree().change_scene_to_file("res://scenes/login.tscn")
		return
	_build_ui()
	_start()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 16
	root.offset_top = 16
	root.set_anchor_and_offset(Side.SIDE_RIGHT, 1.0, -16)
	root.set_anchor_and_offset(Side.SIDE_BOTTOM, 1.0, -16)
	add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	var back_btn := Button.new()
	back_btn.text = "< 返回"
	back_btn.pressed.connect(_on_back_pressed)
	header.add_child(back_btn)
	var title := Label.new()
	title.text = "  场景 %s(点地图移动)" % SCENE_REF
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)

	status_label = Label.new()
	status_label.text = "进入场景中 ..."
	root.add_child(status_label)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	map_view = MapView.new()
	map_view.custom_minimum_size = Vector2(MAP_PX, MAP_PX)
	map_view.owner_scene = self
	body.add_child(map_view)

	log_view = RichTextLabel.new()
	log_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_view.scroll_following = true
	body.add_child(log_view)


func _start() -> void:
	service = MmoSceneService.new()
	add_child(service)
	service.setup(PrivchatSession.client, PrivchatSession.client.access_token)
	service.presence.connect(_on_presence)
	service.movement_started.connect(_on_movement_started)
	service.rejoined.connect(func(ok, err): _log("重连后重订阅:%s %s" % ["ok" if ok else "失败", err]))

	var role: Dictionary = await service.ensure_role("gd-%d" % PrivchatSession.user_id)
	if not role.ok:
		status_label.text = "角色失败:%s" % role.error
		return
	var entered: Dictionary = await service.enter(SCENE_REF, PrivchatSession.device_id)
	if not entered.ok:
		status_label.text = "进入场景失败(%d):%s" % [entered.code, entered.error]
		return
	await _refresh_snapshot()
	status_label.text = "role_id=%d session=%d channel=%d — 点击地图移动" % [service.role_id, service.scene_session_id, service.channel_id]
	_log("已进入 %s" % SCENE_REF)
	_heartbeat_loop()


## snapshot 是恢复语义的兜底(§6):新进、seq 回退、重连后都拉一次。
func _refresh_snapshot() -> void:
	var snap: Dictionary = await service.public_snapshot()
	if not snap.ok:
		_log("[color=red]snapshot 失败:%s[/color]" % snap.error)
		return
	clock_offset_ms = int(snap.data.server_time_ms) - int(Time.get_unix_time_from_system() * 1000.0)
	if map_data == null or int(map_data.map_id) != int(snap.data.map_id):
		var m: Dictionary = await service.fetch_map(int(snap.data.map_id))
		if m.ok:
			map_data = m.data
			_log("地图:%s(%dx%d 格,每格 %d)" % [map_data.name, int(map_data.width_cells), int(map_data.height_cells), int(map_data.cell_size)])
	npcs.clear()
	for n in snap.data.npcs:
		npcs[int(n.npc_id)] = n
	roles.clear()
	for r in snap.data.roles:
		var st: Dictionary = r.state
		var entry := { "name": str(r.role_name), "position": Vector2i(int(st.position.x), int(st.position.y)),
				"entity_version": int(st.entity_version) }
		if st.get("movement") != null:
			entry["movement"] = st.movement
		roles[int(r.role_id)] = entry
	map_view.queue_redraw()


func _heartbeat_loop() -> void:
	while is_inside_tree() and service != null and service.scene_session_id != 0:
		await get_tree().create_timer(10.0).timeout
		if service == null or service.scene_session_id == 0:
			return
		var hb: Dictionary = await service.heartbeat()
		if not hb.ok:
			_log("[color=red]心跳失败(%d):%s[/color]" % [hb.code, hb.error])
			continue
		# 心跳回报的公共序号与本地最后收到的对不上 → 漏收了广播,拉 snapshot 补齐。
		if int(hb.data.get("public_scene_seq", 0)) > service.last_public_seq:
			_log("公共序号落后(%d < %d),拉 snapshot" % [service.last_public_seq, int(hb.data.public_scene_seq)])
			await _refresh_snapshot()


## 点击地图:像素 → 定点世界坐标。点在 NPC 上 → 交互;否则发移动意图。
func request_move(px: Vector2) -> void:
	if service == null or service.scene_session_id == 0:
		return
	@warning_ignore("integer_division")
	var x := int(px.x) * MAP_UNITS * MmoSceneService.FIXED / MAP_PX
	@warning_ignore("integer_division")
	var y := int(px.y) * MAP_UNITS * MmoSceneService.FIXED / MAP_PX
	for nid in npcs:
		var n: Dictionary = npcs[nid]
		var npx: Vector2 = world_to_px(Vector2i(int(n.position.x), int(n.position.y)), map_view.size)
		if npx.distance_to(px) <= 12.0:
			var r: Dictionary = await service.interact(int(nid))
			if r.ok:
				_log("[color=yellow]%s:%s[/color]" % [r.data.name, r.data.dialog])
			elif r.code == 21612:
				_log("离 %s 太远,先走过去" % str(n.name))
			else:
				_log("[color=red]交互失败(%d):%s[/color]" % [r.code, r.error])
			return
	var ack: Dictionary = await service.move_to(x, y)
	if not ack.ok:
		_log("[color=red]移动被拒(%d):%s[/color]" % [ack.code, ack.error])
		if ack.code == 21605 or ack.code == 21603:
			service.movement_seq -= 1
		return
	_log("移动受理 seq=%d path_id=%d" % [int(ack.data.accepted_movement_seq), int(ack.data.path_id)])


func _on_movement_started(entity_id: int, movement: Dictionary, _seq: int) -> void:
	var entry: Dictionary = roles.get(entity_id, { "name": "#%d" % entity_id, "entity_version": 0 })
	# 位置类状态按 entity_version 覆盖(spec §3.2):Room 回放的历史事件、乱序迟到的
	# 旧事件版本号都更小,直接丢弃,不判缺、不请求补发。
	if int(movement.get("entity_version", 0)) <= int(entry.get("entity_version", 0)):
		return
	entry["entity_version"] = int(movement.get("entity_version", 0))
	entry["movement"] = movement
	entry.erase("position")
	roles[entity_id] = entry
	map_view.queue_redraw()


func _on_presence(event: String, role_id: int, role_name: String, _seq: int, _raw: Dictionary) -> void:
	if event == "scene.role_entered":
		_log("%s 进入场景" % role_name)
		# 进入事件不带位置;拉一次 snapshot 拿到出生点与在途路径。
		await _refresh_snapshot()
	elif event == "scene.role_left":
		_log("%s 离开场景" % role_name)
		roles.erase(role_id)
		map_view.queue_redraw()


## 当前服务端时刻下每个角色的位置(与服务端同一套整数算法)。
func current_position(entry: Dictionary) -> Vector2i:
	if entry.has("movement"):
		var now_ms := int(Time.get_unix_time_from_system() * 1000.0) + clock_offset_ms
		return MmoSceneService.position_on_path(entry.movement, now_ms)
	return entry.get("position", Vector2i.ZERO)


## 定点世界坐标 → 地图视图像素。
func world_to_px(p: Vector2i, view_size: Vector2) -> Vector2:
	return Vector2(p.x, p.y) * view_size.x / float(MAP_UNITS * MmoSceneService.FIXED)


func is_my_role(rid: int) -> bool:
	return service != null and rid == service.role_id


func _process(_delta: float) -> void:
	if map_view != null:
		map_view.queue_redraw()


func _log(line: String) -> void:
	log_view.append_text(line + "\n")


func _on_back_pressed() -> void:
	if service != null:
		await service.leave()
		await service.close()
		service = null
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


# --- 地图视图 ---------------------------------------------------------------

class MapView extends Control:
	var owner_scene = null

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.13, 0.17, 0.13))
		var step := size.x / 10.0
		for i in range(11):
			draw_line(Vector2(i * step, 0), Vector2(i * step, size.y), Color(0.2, 0.25, 0.2))
			draw_line(Vector2(0, i * step), Vector2(size.x, i * step), Color(0.2, 0.25, 0.2))
		if owner_scene == null:
			return
		# 阻挡格
		var md = owner_scene.map_data
		if md != null:
			var cell_px: float = size.x / float(int(md.width_cells))
			var rows: Array = md.rows
			for y in range(rows.size()):
				var row: String = rows[y]
				for x in range(row.length()):
					if row[x] == "#":
						draw_rect(Rect2(x * cell_px, y * cell_px, cell_px, cell_px), Color(0.35, 0.3, 0.25))
		# NPC
		for nid in owner_scene.npcs:
			var n: Dictionary = owner_scene.npcs[nid]
			var npx: Vector2 = owner_scene.world_to_px(Vector2i(int(n.position.x), int(n.position.y)), size)
			draw_circle(npx, 8.0, Color(0.3, 0.9, 0.4))
			draw_string(ThemeDB.fallback_font, npx + Vector2(-24, -12), str(n.name), HORIZONTAL_ALIGNMENT_CENTER, 48, 11)
		for rid in owner_scene.roles:
			var entry: Dictionary = owner_scene.roles[rid]
			var p: Vector2i = owner_scene.current_position(entry)
			var px: Vector2 = owner_scene.world_to_px(p, size)
			var mine: bool = owner_scene.is_my_role(rid)
			if entry.has("movement"):
				var pts: Array = entry.movement.get("path_points", [])
				if not pts.is_empty():
					var t: Vector2 = owner_scene.world_to_px(Vector2i(int(pts[0].x), int(pts[0].y)), size)
					draw_line(px, t, Color(0.5, 0.5, 0.5, 0.6), 1.0)
			draw_circle(px, 9.0, Color(0.95, 0.75, 0.2) if mine else Color(0.4, 0.7, 1.0))
			draw_string(ThemeDB.fallback_font, px + Vector2(-20, -14), str(entry.get("name", "")), HORIZONTAL_ALIGNMENT_CENTER, 40, 12)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			if owner_scene != null:
				owner_scene.request_move(event.position)
