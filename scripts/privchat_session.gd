# privchat_session.gd — autoload 会话容器（对标 DemoChatScene 的会话级状态）
#
# PrivchatClient 在登录成功后创建一次，挂在 autoload 下跨场景存活；
# 退出登录时销毁，下次登录开启全新会话（对齐 cocos-demo teardownSession 语义）。
extends Node

var client: PrivchatClient = null
var user_id: int = -1
var device_id: String = ""
var mobile: String = ""

## 从会话列表点进聊天时携带的目标频道;chat 场景消费后清零。
## channel_id 为 0 表示直接进入聊天页(需手动输入对方 uid)。
##
## **必须连 channel_type 一起带** —— 会话列表里可能有群聊等其它类型,
## 只带 id 会让聊天页按写死的类型打开错误的频道。
var pending_channel_id: int = 0
var pending_channel_type: int = 0


func _ready() -> void:
	_apply_display_scale()


## HiDPI 自适应。
##
## Godot 把 `window/size/viewport_*` 当**物理像素**开窗:2x 屏上 960 只有
## 480 逻辑点,窗口小一半、内容跟着小。静态配置解决不了 —— 写死 2 倍会在
## 非 Retina 上把窗口撑爆。
##
## 因此运行时按屏幕缩放放大**窗口**即可 —— 内容的放大由
## `stretch/mode="canvas_items"` 负责(它把 960x640 设计视口拉伸到实际窗口)。
## **不要**再设 content_scale_factor,那会与 stretch 叠乘成 4 倍并裁剪内容。
func _apply_display_scale() -> void:
	var win := get_window()
	if win == null:
		return
	var scale := DisplayServer.screen_get_scale(DisplayServer.window_get_current_screen())
	if scale <= 1.0:
		return
	win.size = Vector2i(int(win.size.x * scale), int(win.size.y * scale))
	# 放大后重新居中,否则窗口会偏出屏幕右下。
	var screen := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	win.position = screen.position + (screen.size - win.size) / 2


func begin(c: PrivchatClient, uid: int, did: String, mob: String) -> void:
	client = c
	user_id = uid
	device_id = did
	mobile = mob
	# 登录态不可自愈(ForcedLogout)时统一处理:清会话、回登录页(spec §7.1)。
	if not client.session_expired.is_connected(_on_session_expired):
		client.session_expired.connect(_on_session_expired)


func _on_session_expired(code: int, message: String, _source: String) -> void:
	push_warning("[privchat] session expired (%d): %s" % [code, message])
	logout()
	get_tree().change_scene_to_file("res://scenes/login.tscn")


func has_session() -> bool:
	return client != null and user_id >= 0


func logout() -> void:
	if client != null:
		client.stop()
		client.queue_free()
	client = null
	# 清掉待跳转会话:否则下次登录时可能把上个账号的频道带进去。
	pending_channel_id = 0
	pending_channel_type = 0
	user_id = -1
	device_id = ""
	mobile = ""
