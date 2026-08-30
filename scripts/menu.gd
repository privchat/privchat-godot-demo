# menu.gd — 主菜单（对标 privchat-cocos-demo MenuPage）
extends Control


func _ready() -> void:
	if not PrivchatSession.has_session():
		get_tree().change_scene_to_file("res://scenes/login.tscn")
		return

	var page := MarginContainer.new()
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.add_theme_constant_override("margin_left", 24)
	page.add_theme_constant_override("margin_top", 24)
	page.add_theme_constant_override("margin_right", 24)
	page.add_theme_constant_override("margin_bottom", 24)
	add_child(page)

	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(center)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(520, 0)
	center.add_child(root)

	var title := Label.new()
	title.text = "PrivChat Godot Demo"
	title.add_theme_font_size_override("font_size", 24)
	root.add_child(title)

	var greeting := Label.new()
	greeting.text = "已登录：%s（user_id=%d）" % [PrivchatSession.mobile, PrivchatSession.user_id]
	root.add_child(greeting)

	root.add_child(_spacer())

	var chat_btn := Button.new()
	chat_btn.text = "单聊（Direct Chat）"
	chat_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/chat.tscn"))
	root.add_child(chat_btn)

	var room_btn := Button.new()
	room_btn.text = "房间订阅（Room）"
	room_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/room.tscn"))
	root.add_child(room_btn)

	root.add_child(_spacer())

	# --- 会话列表(top 优先、时间降序;带未读角标)---
	var list_title := Label.new()
	root.add_child(list_title)
	var conv_list := VBoxContainer.new()
	root.add_child(conv_list)
	_load_conversations(list_title, conv_list)

	root.add_child(_spacer())

	var logout_btn := Button.new()
	logout_btn.text = "退出登录"
	logout_btn.pressed.connect(_on_logout_pressed)
	root.add_child(logout_btn)

	var state_label := Label.new()
	state_label.text = "连接状态：%s" % PrivchatSession.client.connection_state()
	state_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	root.add_child(state_label)


func _load_conversations(title: Label, container: VBoxContainer) -> void:
	var client: PrivchatClient = PrivchatSession.client
	var total: Dictionary = await client.get_total_unread_count()
	var list_resp: Dictionary = await client.list_channels(20)
	if not list_resp.ok:
		title.text = "会话列表加载失败：%s" % list_resp.error
		return
	title.text = "会话（总未读 %d）" % (total.count if total.ok else 0)
	for c in list_resp.channels:
		var cid := int(c.get("channel_id", 0))
		var name := str(c.get("channel_name", ""))
		if name.is_empty():
			var peer = c.get("peer_user_id")
			name = ("与 %s 的会话" % str(peer)) if peer != null else "频道 %d" % cid
		var unread := int(c.get("unread_count", 0))
		var badge := ("  [未读 %d]" % unread) if unread > 0 else ""
		var preview := str(c.get("last_msg_content", ""))
		if preview.length() > 18:
			preview = preview.substr(0, 18) + "…"
		var row := Button.new()
		row.text = "%s%s  %s" % [name, badge, preview]
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		# 带上频道再跳转 —— 否则点了会话列表还要手动输入对方 uid。
		row.pressed.connect(func():
			PrivchatSession.pending_channel_id = cid
			get_tree().change_scene_to_file("res://scenes/chat.tscn"))
		container.add_child(row)
	if list_resp.channels.is_empty():
		var empty := Label.new()
		empty.text = "（暂无会话）"
		empty.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		container.add_child(empty)


func _spacer() -> Control:
	var s := Control.new()
	s.custom_minimum_size.y = 16
	return s


func _on_logout_pressed() -> void:
	PrivchatSession.logout()
	get_tree().change_scene_to_file("res://scenes/login.tscn")
