# room.gd — 房间订阅场景（对标 privchat-cocos-demo RoomPanel）
# 流程：输入 channelId（业务后台创建的 Room） → Subscribe → 接收广播 → Unsubscribe
# spec ROOM_CHANNEL_SPEC：Room 客户端只能订阅，消息广播由业务服务端触发，
# 因此这里没有发送框（对标 cocos RoomPanel）。订阅需要 ticket 时
# （server 配了 [room_ticket]），由业务后台签发后填入下方 ticket 输入框。
extends Control

const ROOM_CHANNEL_TYPE := 2

var channel_edit: LineEdit
var ticket_edit: LineEdit
var sub_btn: Button
var unsub_btn: Button
var list: RichTextLabel
var status_label: Label

var client: PrivchatClient = null
var subscribed_id: int = -1
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
	back_btn.pressed.connect(_on_back_pressed)
	header.add_child(back_btn)
	var title := Label.new()
	title.text = "  Room 订阅测试"
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)

	var sub_row := HBoxContainer.new()
	root.add_child(sub_row)
	var channel_label := Label.new()
	channel_label.text = "channelId"
	sub_row.add_child(channel_label)
	channel_edit = LineEdit.new()
	channel_edit.placeholder_text = "Room channelId（业务后台创建返回的 snowflake id）"
	channel_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub_row.add_child(channel_edit)
	sub_btn = Button.new()
	sub_btn.text = "Subscribe"
	sub_btn.pressed.connect(_on_subscribe_pressed)
	sub_row.add_child(sub_btn)
	unsub_btn = Button.new()
	unsub_btn.text = "Unsubscribe"
	unsub_btn.disabled = true
	unsub_btn.pressed.connect(_on_unsubscribe_pressed)
	sub_row.add_child(unsub_btn)

	var ticket_row := HBoxContainer.new()
	root.add_child(ticket_row)
	var ticket_label := Label.new()
	ticket_label.text = "ticket"
	ticket_row.add_child(ticket_label)
	ticket_edit = LineEdit.new()
	ticket_edit.placeholder_text = "可选：业务后台签发的 room subscribe ticket"
	ticket_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ticket_row.add_child(ticket_edit)

	list = RichTextLabel.new()
	list.bbcode_enabled = true
	list.scroll_following = true
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.custom_minimum_size.y = 300
	root.add_child(list)

	status_label = Label.new()
	status_label.text = "IDLE — 输入 channelId 后点 Subscribe"
	status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	root.add_child(status_label)


func _append(text: String) -> void:
	print("[room] ", text)
	list.append_text(text + "\n")


func _on_back_pressed() -> void:
	# 对标 RoomPanel dispose：离开页面前退订。
	if subscribed_id >= 0:
		await client.unsubscribe_channel(subscribed_id, ROOM_CHANNEL_TYPE)
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


func _on_subscribe_pressed() -> void:
	var channel_id := int(channel_edit.text.strip_edges())
	if channel_id <= 0:
		status_label.text = "请输入合法的 channelId"
		return
	sub_btn.disabled = true
	status_label.text = "SUBSCRIBING ..."
	var resp: Dictionary = await client.subscribe_channel(channel_id, ROOM_CHANNEL_TYPE,
		ticket_edit.text.strip_edges())
	if not resp.ok:
		sub_btn.disabled = false
		status_label.text = "ERROR — %s" % resp.error
		_append("[color=red]订阅失败：%s[/color]" % resp.error)
		return
	subscribed_id = channel_id
	status_label.text = "SUBSCRIBED — channel_id=%d" % channel_id
	_append("[color=green]已订阅房间 %d[/color]" % channel_id)
	sub_btn.disabled = false
	unsub_btn.disabled = false


func _on_unsubscribe_pressed() -> void:
	if subscribed_id < 0:
		return
	unsub_btn.disabled = true
	status_label.text = "UNSUBSCRIBING ..."
	var resp: Dictionary = await client.unsubscribe_channel(subscribed_id, ROOM_CHANNEL_TYPE)
	if resp.ok:
		_append("[color=gray]已退订房间 %d[/color]" % subscribed_id)
		status_label.text = "IDLE"
		subscribed_id = -1
	else:
		status_label.text = "ERROR — %s" % resp.error
		_append("[color=red]退订失败：%s[/color]" % resp.error)
		unsub_btn.disabled = false


func _on_sdk_event(_sequence_id: int, _timestamp_ms: int, kind: String, seq_event: Dictionary) -> void:
	var event: Dictionary = seq_event.get("event", {})
	match kind:
		"TimelineUpdated":
			# 本地时间线变更（含历史回放落库），按 message_id 取内容渲染。
			var t: Dictionary = event.get("TimelineUpdated", {})
			if subscribed_id < 0 or int(t.get("channel_id", -1)) != subscribed_id:
				return
			var message_id: int = int(t.get("message_id", 0))
			if message_id <= 0 or _rendered_message_ids.has(message_id):
				return
			_rendered_message_ids[message_id] = true
			_render_message(message_id)
		"SubscriptionMessageReceived":
			# 服务端广播（spec ROOM_CHANNEL_SPEC：房间消息由业务服务端触发，
			# 客户端只接收）。payload 是 UTF-8 字节数组。
			var p: Dictionary = event.get("SubscriptionMessageReceived", {})
			if subscribed_id < 0 or int(p.get("channel_id", -1)) != subscribed_id:
				return
			var bytes := PackedByteArray()
			for b in p.get("payload", []):
				bytes.append(int(b))
			var who := str(p.get("publisher", "server"))
			_append("[b]%s[/b]: %s" % [who, bytes.get_string_from_utf8()])


func _render_message(message_id: int) -> void:
	var resp: Dictionary = await client.get_message_by_id(message_id)
	if not resp.ok or typeof(resp.data) != TYPE_DICTIONARY:
		return
	var m: Dictionary = resp.data
	if int(m.get("channel_id", -1)) != subscribed_id:
		return
	var from_uid: int = int(m.get("from_uid", 0))
	var content: String = str(m.get("content", ""))
	var who := "我" if from_uid == PrivchatSession.user_id else "uid=%d" % from_uid
	_append("[b]%s[/b]: %s" % [who, content])
