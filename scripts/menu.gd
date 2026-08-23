# menu.gd — 主菜单（对标 privchat-cocos-demo MenuPage）
extends Control


func _ready() -> void:
	if not PrivchatSession.has_session():
		get_tree().change_scene_to_file("res://scenes/login.tscn")
		return

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_CENTER)
	root.custom_minimum_size = Vector2(360, 0)
	add_child(root)

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

	var logout_btn := Button.new()
	logout_btn.text = "退出登录"
	logout_btn.pressed.connect(_on_logout_pressed)
	root.add_child(logout_btn)

	var state_label := Label.new()
	state_label.text = "连接状态：%s" % PrivchatSession.client.connection_state()
	state_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	root.add_child(state_label)


func _spacer() -> Control:
	var s := Control.new()
	s.custom_minimum_size.y = 16
	return s


func _on_logout_pressed() -> void:
	PrivchatSession.logout()
	get_tree().change_scene_to_file("res://scenes/login.tscn")
