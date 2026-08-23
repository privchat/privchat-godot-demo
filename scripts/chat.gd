# chat.gd — 单聊场景（对标 privchat-cocos-demo 好友选择 + mountChatView）
# 流程：输入对方 uid → get_or_create_direct_channel → sync → 收发消息
# 简化点：好友列表（SdkFriendsSource）以手动输入 peer uid 代替。
extends Control

const CHANNEL_TYPE_DIRECT := 1

var peer_edit: LineEdit
var msg_edit: LineEdit
var send_btn: Button
var open_btn: Button
var list: RichTextLabel
var status_label: Label

var channel_id: int = -1
var client: PrivchatClient = null
var _rendered_message_ids := {}


func _ready() -> void:
	if not PrivchatSession.has_session():
		get_tree().change_scene_to_file("res://scenes/login.tscn")
		return
	client = PrivchatSession.client
	client.sdk_event.connect(_on_sdk_event)
	_build_ui()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.set_anchor_and_offset(Side.SIDE_RIGHT, 1.0, -16)
	root.set_anchor_and_offset(Side.SIDE_BOTTOM, 1.0, -16)
	root.offset_left = 16
	root.offset_top = 16
	add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	var back_btn := Button.new()
	back_btn.text = "< 返回"
	back_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/menu.tscn"))
	header.add_child(back_btn)
	var title := Label.new()
	title.text = "  单聊"
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)

	var open_row := HBoxContainer.new()
	root.add_child(open_row)
	var peer_label := Label.new()
	peer_label.text = "对方 uid"
	open_row.add_child(peer_label)
	peer_edit = LineEdit.new()
	peer_edit.placeholder_text = "对方 user_id，例如 %d" % (PrivchatSession.user_id + 1)
	peer_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_row.add_child(peer_edit)
	open_btn = Button.new()
	open_btn.text = "打开会话"
	open_btn.pressed.connect(_on_open_pressed)
	open_row.add_child(open_btn)

	list = RichTextLabel.new()
	list.bbcode_enabled = true
	list.scroll_following = true
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.custom_minimum_size.y = 300
	root.add_child(list)

	status_label = Label.new()
	status_label.text = "未打开会话"
	status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	root.add_child(status_label)

	var send_row := HBoxContainer.new()
	root.add_child(send_row)
	msg_edit = LineEdit.new()
	msg_edit.placeholder_text = "输入消息，回车发送"
	msg_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	msg_edit.text_submitted.connect(func(_t): _on_send_pressed())
	send_row.add_child(msg_edit)
	send_btn = Button.new()
	send_btn.text = "发送"
	send_btn.pressed.connect(_on_send_pressed)
	send_row.add_child(send_btn)


func _append(text: String) -> void:
	print("[chat] ", text)
	list.append_text(text + "\n")


func _on_open_pressed() -> void:
	var peer := int(peer_edit.text.strip_edges())
	if peer <= 0:
		status_label.text = "请输入对方 user_id"
		return
	open_btn.disabled = true
	status_label.text = "打开会话中 ..."
	# 对标 cocos：进入聊天前拿 channel + 一次性 sync（get_or_create_direct_channel 内部已含 sync）。
	var resp: Dictionary = await client.get_or_create_direct_channel(peer)
	open_btn.disabled = false
	if not resp.ok:
		status_label.text = "打开会话失败：%s" % resp.error
		_append("[color=red]打开会话失败：%s[/color]" % resp.error)
		return
	channel_id = resp.channel_id
	status_label.text = "会话 channel_id=%d（type=direct）" % channel_id
	_append("[color=gray]会话已就绪 channel_id=%d[/color]" % channel_id)


func _on_send_pressed() -> void:
	if channel_id < 0:
		status_label.text = "先打开会话"
		return
	var content := msg_edit.text.strip_edges()
	if content.is_empty():
		return
	msg_edit.clear()
	var resp: Dictionary = await client.send_text(channel_id, CHANNEL_TYPE_DIRECT, content)
	if resp.ok:
		_append("[color=gray]（已入队，等待投递回执事件）[/color]")
	else:
		_append("[color=red]发送失败：%s[/color]" % resp.error)


func _on_sdk_event(_sequence_id: int, _timestamp_ms: int, kind: String, event_json: String) -> void:
	var parsed = JSON.parse_string(event_json)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var event: Dictionary = parsed.get("event", {})
	match kind:
		"TimelineUpdated":
			# Rust SDK 本地优先模型：没有 NewMessage 事件，新消息以
			# TimelineUpdated(channel_id, message_id) 通知，内容用
			# get_message_by_id 从本地时间线取。
			var t: Dictionary = event.get("TimelineUpdated", {})
			if channel_id < 0 or int(t.get("channel_id", -1)) != channel_id:
				return
			var message_id: int = int(t.get("message_id", 0))
			if message_id <= 0 or _rendered_message_ids.has(message_id):
				return
			_rendered_message_ids[message_id] = true
			_render_message(message_id)
		"MessageSendStatusChanged":
			var s: Dictionary = event.get("MessageSendStatusChanged", {})
			_append("[color=gray]投递状态 message_id=%s → %s[/color]" % [
				str(s.get("message_id", "?")), str(s.get("status", "?"))])


func _render_message(message_id: int) -> void:
	var resp: Dictionary = await client.get_message_by_id(message_id)
	if not resp.ok or resp.is_empty() or not resp.has("data"):
		return
	var m: Dictionary = resp.data
	if int(m.get("channel_id", -1)) != channel_id:
		return
	var from_uid: int = int(m.get("from_uid", 0))
	var content: String = str(m.get("content", ""))
	var who := "我" if from_uid == PrivchatSession.user_id else "对方(%d)" % from_uid
	_append("[b]%s[/b]: %s" % [who, content])
