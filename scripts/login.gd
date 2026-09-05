# login.gd — privchat-godot-demo 登录场景（对照 privchat-cocos-demo LoginPage）
#
# 部署用哪种注册/登录方式不是客户端说了算:先匿名 GET /config/bootstrap,按
# auth.registerModes 渲染(MEMBER_INVITE_CODE_SPEC §5.0):
#   PHONE_SMS          手机号 → 发送验证码 → 验证码 → 登录(sms-login)
#   USERNAME_PASSWORD  账号 / 密码 → 登录(login-username)或注册(register,注册即登录)
# 两种都开时显示切换;只开一种就只显示那一种。三条路都汇到 authenticate → connect。
extends Control

const DemoEnv := preload("res://scripts/demo_env.gd")

var mobile_edit: LineEdit
var code_edit: LineEdit
var send_code_btn: Button
var login_btn: Button
var status_label: RichTextLabel

var sms_box: VBoxContainer
var password_box: VBoxContainer
var mode_row: HBoxContainer
var username_edit: LineEdit
var password_edit: LineEdit
var nickname_edit: LineEdit
var password_login_btn: Button
var register_btn: Button

## bootstrap 下发的注册方式;拿到前两块表单都不显示。
var register_modes: Array = []
var nickname_required := false

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
	_load_bootstrap()


## 登录方式来自服务端配置:拿不到就明确报错,不假装成手机号模式。
func _load_bootstrap() -> void:
	var resp: Dictionary = await _client_for_auth().fetch_bootstrap()
	if not resp.ok:
		_append_status("[color=red]拉取 /config/bootstrap 失败:%s[/color]" % resp.error)
		return
	register_modes = resp.data.register_modes
	nickname_required = bool(resp.data.nickname_required)
	_apply_modes(str(resp.data.default_register_mode))
	_append_status("登录方式(服务端配置 %s):%s" % [str(resp.data.config_version), ", ".join(register_modes)])


func _apply_modes(preferred: String) -> void:
	var has_sms := register_modes.has(PrivchatPlatformAuthClient.MODE_PHONE_SMS)
	var has_pwd := register_modes.has(PrivchatPlatformAuthClient.MODE_USERNAME_PASSWORD)
	mode_row.visible = has_sms and has_pwd
	nickname_edit.placeholder_text = "昵称(必填)" if nickname_required else "昵称(选填)"
	if has_pwd and (preferred == PrivchatPlatformAuthClient.MODE_USERNAME_PASSWORD or not has_sms):
		_show_mode(PrivchatPlatformAuthClient.MODE_USERNAME_PASSWORD)
	elif has_sms:
		_show_mode(PrivchatPlatformAuthClient.MODE_PHONE_SMS)
	else:
		_append_status("[color=red]服务端没有开放任何已知的登录方式:%s[/color]" % str(register_modes))


func _show_mode(mode: String) -> void:
	sms_box.visible = mode == PrivchatPlatformAuthClient.MODE_PHONE_SMS
	password_box.visible = mode == PrivchatPlatformAuthClient.MODE_USERNAME_PASSWORD


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

	mode_row = HBoxContainer.new()
	mode_row.visible = false
	root.add_child(mode_row)
	var sms_mode_btn := Button.new()
	sms_mode_btn.text = "手机号登录"
	sms_mode_btn.pressed.connect(func(): _show_mode(PrivchatPlatformAuthClient.MODE_PHONE_SMS))
	mode_row.add_child(sms_mode_btn)
	var pwd_mode_btn := Button.new()
	pwd_mode_btn.text = "账号密码登录"
	pwd_mode_btn.pressed.connect(func(): _show_mode(PrivchatPlatformAuthClient.MODE_USERNAME_PASSWORD))
	mode_row.add_child(pwd_mode_btn)

	sms_box = VBoxContainer.new()
	sms_box.visible = false
	root.add_child(sms_box)
	var mobile_row := HBoxContainer.new()
	sms_box.add_child(mobile_row)
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

	sms_box.add_child(_spacer())

	var code_row := HBoxContainer.new()
	sms_box.add_child(code_row)
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

	password_box = VBoxContainer.new()
	password_box.visible = false
	root.add_child(password_box)
	var user_row := HBoxContainer.new()
	password_box.add_child(user_row)
	var user_label := Label.new()
	user_label.text = "账号"
	user_label.custom_minimum_size.x = 80
	user_row.add_child(user_label)
	username_edit = LineEdit.new()
	username_edit.placeholder_text = "3-32 个字符"
	username_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	user_row.add_child(username_edit)
	password_box.add_child(_spacer())
	var pwd_row := HBoxContainer.new()
	password_box.add_child(pwd_row)
	var pwd_label := Label.new()
	pwd_label.text = "密码"
	pwd_label.custom_minimum_size.x = 80
	pwd_row.add_child(pwd_label)
	password_edit = LineEdit.new()
	password_edit.secret = true
	password_edit.placeholder_text = "8-128 个字符"
	password_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pwd_row.add_child(password_edit)
	password_box.add_child(_spacer())
	var nick_row := HBoxContainer.new()
	password_box.add_child(nick_row)
	var nick_label := Label.new()
	nick_label.text = "昵称"
	nick_label.custom_minimum_size.x = 80
	nick_row.add_child(nick_label)
	nickname_edit = LineEdit.new()
	nickname_edit.placeholder_text = "昵称(注册用,选填)"
	nickname_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nick_row.add_child(nickname_edit)
	password_login_btn = Button.new()
	password_login_btn.text = "登录"
	password_login_btn.pressed.connect(func(): _on_password_pressed(false))
	nick_row.add_child(password_login_btn)
	register_btn = Button.new()
	register_btn.text = "注册"
	register_btn.pressed.connect(func(): _on_password_pressed(true))
	nick_row.add_child(register_btn)

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
	await _run_login(mobile, func(client): return await client.login(mobile, code))


func _on_password_pressed(register: bool) -> void:
	if _logging_in:
		return
	var username := username_edit.text.strip_edges()
	var password := password_edit.text
	var nickname := nickname_edit.text.strip_edges()
	if username.is_empty() or password.is_empty():
		_set_status("请输入账号和密码")
		return
	if register and nickname_required and nickname.is_empty():
		_set_status("本服务要求注册时填写昵称")
		return
	if register:
		await _run_login(username, func(client): return await client.register_with_password(username, password, nickname))
	else:
		await _run_login(username, func(client): return await client.login_with_password(username, password))


## 三种方式共用:接管临时 client → 调用具体登录 → 成功进菜单。
func _run_login(account: String, do_login: Callable) -> void:
	_logging_in = true
	login_btn.disabled = true
	password_login_btn.disabled = true
	register_btn.disabled = true
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
	var resp: Dictionary = await do_login.call(client)
	_logging_in = false
	login_btn.disabled = false
	password_login_btn.disabled = false
	register_btn.disabled = false
	if not resp.ok:
		client.queue_free()
		_append_status("[color=red]登录失败：%s[/color]" % resp.error)
		return

	_append_status("[color=green]登录成功 user_id=%d[/color]" % resp.user_id)
	_append_status("connection_state: %s" % client.connection_state())
	PrivchatSession.begin(client, resp.user_id, client.logged_in_device_id, account)
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
