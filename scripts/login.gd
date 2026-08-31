# login.gd — privchat-godot-demo 登录场景（对照 privchat-cocos-demo LoginPage）
# 流程：手机号 → 发送短信验证码 → 输入验证码 → 登录（sms-login → authenticate → connect）
extends Control

const DemoEnv := preload("res://scripts/demo_env.gd")

var mobile_edit: LineEdit
var code_edit: LineEdit
var send_code_btn: Button
var login_btn: Button
var status_label: RichTextLabel

var _sending_code := false
var _logging_in := false
# 登录前的临时 client(发验证码等 HTTP 用);登录成功后升级为会话级 client
# 移交给 PrivchatSession,失败则留在本场景复用。
var _prelogin_client: PrivchatClient = null


func _client_for_auth() -> PrivchatClient:
	if _prelogin_client == null:
		_prelogin_client = DemoEnv.make_client()
		add_child(_prelogin_client)
	return _prelogin_client


func _ready() -> void:
	_build_ui()
	# 已有会话（登出后残留等异常路径）直接进菜单。
	if PrivchatSession.has_session():
		get_tree().change_scene_to_file("res://scenes/menu.tscn")
		return
	_set_status("就绪。请确认本地已启动 privchat-server + privchat-application。")


func _build_ui() -> void:
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
	root.custom_minimum_size = Vector2(600, 0)
	center.add_child(root)

	var title := Label.new()
	title.text = "PrivChat Godot Demo — 登录"
	title.add_theme_font_size_override("font_size", 24)
	root.add_child(title)

	root.add_child(_spacer())

	var mobile_row := HBoxContainer.new()
	root.add_child(mobile_row)
	var mobile_label := Label.new()
	mobile_label.text = "手机号"
	mobile_label.custom_minimum_size.x = 80
	mobile_row.add_child(mobile_label)
	mobile_edit = LineEdit.new()
	mobile_edit.placeholder_text = "E.164 格式，例如 +8613800000001"
	mobile_edit.custom_minimum_size.x = 300
	mobile_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mobile_row.add_child(mobile_edit)
	send_code_btn = Button.new()
	send_code_btn.text = "发送验证码"
	send_code_btn.pressed.connect(_on_send_code_pressed)
	mobile_row.add_child(send_code_btn)

	root.add_child(_spacer())

	var code_row := HBoxContainer.new()
	root.add_child(code_row)
	var code_label := Label.new()
	code_label.text = "验证码"
	code_label.custom_minimum_size.x = 80
	code_row.add_child(code_label)
	code_edit = LineEdit.new()
	code_edit.placeholder_text = "输入开发环境生成的验证码"
	code_edit.custom_minimum_size.x = 300
	code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code_row.add_child(code_edit)
	login_btn = Button.new()
	login_btn.text = "登录"
	login_btn.pressed.connect(_on_login_pressed)
	code_row.add_child(login_btn)

	root.add_child(_spacer())

	status_label = RichTextLabel.new()
	status_label.custom_minimum_size = Vector2(600, 200)
	status_label.bbcode_enabled = true
	status_label.scroll_following = true
	root.add_child(status_label)


func _spacer() -> Control:
	var s := Control.new()
	s.custom_minimum_size.y = 12
	return s


func _set_status(text: String) -> void:
	print("[login] ", text)
	if status_label != null:
		status_label.text = text


func _append_status(text: String) -> void:
	print("[login] ", text)
	if status_label != null:
		status_label.text += "\n" + text
		status_label.scroll_to_line(status_label.get_line_count() - 1)


func _on_send_code_pressed() -> void:
	if _sending_code:
		return
	var mobile := mobile_edit.text.strip_edges()
	if mobile.is_empty():
		_set_status("请先输入手机号")
		return
	_sending_code = true
	send_code_btn.disabled = true
	_append_status("发送验证码 → %s ..." % mobile)
	var resp: Dictionary = await _client_for_auth().send_sms_code(mobile)
	_sending_code = false
	send_code_btn.disabled = false
	if resp.ok:
		_append_status("验证码已发送（dev 环境固定验证码见 docs/e2e.md）")
	else:
		_append_status("[color=red]发送验证码失败：%s[/color]" % resp.error)


func _on_login_pressed() -> void:
	if _logging_in:
		return
	var mobile := mobile_edit.text.strip_edges()
	var code := code_edit.text.strip_edges()
	if mobile.is_empty() or code.is_empty():
		_set_status("请输入手机号和验证码")
		return
	_logging_in = true
	login_btn.disabled = true
	_append_status("登录中 ...")
	# 会话级 client 挂在 autoload 下，跨场景存活（对标 DemoChatScene）。
	# 复用登录前的临时 client(里面已有验证码会话),移交给 autoload。
	var client := _client_for_auth()
	_prelogin_client = null
	if client.get_parent() != null:
		client.reparent(PrivchatSession)
	else:
		PrivchatSession.add_child(client)
	client.connection_state_changed.connect(_on_connection_state_changed)
	client.sdk_event.connect(_on_sdk_event)
	var resp: Dictionary = await client.login(mobile, code)
	_logging_in = false
	login_btn.disabled = false
	if not resp.ok:
		client.queue_free()
		_append_status("[color=red]登录失败：%s[/color]" % resp.error)
		return

	_append_status("[color=green]登录成功 user_id=%d[/color]" % resp.user_id)
	_append_status("connection_state: %s" % client.connection_state())
	PrivchatSession.begin(client, resp.user_id, client.logged_in_device_id, mobile)
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


func _on_connection_state_changed(from_state: String, to_state: String) -> void:
	_append_status("连接状态：%s → %s" % [from_state, to_state])


func _on_sdk_event(sequence_id: int, _timestamp_ms: int, kind: String,
		_event: Dictionary) -> void:
	# 登录场景只关注关键事件，其余静默。
	match kind:
		"BootstrapCompleted", "SyncStateChanged", "ConnectionStateChanged", \
		"ForcedLogout", "AccessTokenRefreshNeeded":
			_append_status("event#%d %s" % [sequence_id, kind])
