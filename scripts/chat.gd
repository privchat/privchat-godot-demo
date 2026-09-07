# chat.gd — 单聊场景(chat facade 版)
# 流程:输入对方 uid → ChatService.open(local-first 历史) → 收发消息
#      → 上滑加载更早 → 自动已读(会话打开期间收到即读)
extends Control

const CHANNEL_TYPE_DIRECT := 1

var peer_edit: LineEdit
var msg_edit: LineEdit
var send_btn: Button
var open_btn: Button
var older_btn: Button
var list: RichTextLabel
var status_label: Label

var channel_id: int = -1
var channel_type: int = 1
var client: PrivchatClient = null
var chat: PrivchatChatService = null
var _rendered_message_ids := {}
var _earliest_server_message_id: int = 0
var _has_more_before := false


func _ready() -> void:
	if not PrivchatSession.has_session():
		get_tree().change_scene_to_file("res://scenes/login.tscn")
		return
	client = PrivchatSession.client
	chat = PrivchatChatService.new()
	add_child(chat)
	chat.setup(client)
	chat.message_received.connect(_on_message_received)
	chat.send_status_changed.connect(_on_send_status)
	chat.unread_changed.connect(_on_unread_changed)
	_build_ui()
	# 从会话列表点进来时直接打开该频道,不必再手输对方 uid。
	if PrivchatSession.pending_channel_id > 0:
		var cid: int = PrivchatSession.pending_channel_id
		var ctype: int = PrivchatSession.pending_channel_type
		PrivchatSession.pending_channel_id = 0
		PrivchatSession.pending_channel_type = 0
		_open_channel(cid, ctype if ctype > 0 else CHANNEL_TYPE_DIRECT)


## 切场景前先 close():排空在途请求并断信号,避免协程状态泄漏。
func _on_back() -> void:
	if chat != null:
		await chat.close()
		chat = null
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


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
	back_btn.pressed.connect(_on_back)
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

	older_btn = Button.new()
	older_btn.text = "↑ 加载更早"
	older_btn.disabled = true
	older_btn.pressed.connect(_on_load_older_pressed)
	root.add_child(older_btn)

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
	var resp: Dictionary = await client.get_or_create_direct_channel(peer)
	if not resp.ok:
		open_btn.disabled = false
		status_label.text = "打开会话失败：%s" % resp.error
		return
	await _open_channel(resp.channel_id, CHANNEL_TYPE_DIRECT)


## 打开指定频道并渲染历史。手输 uid 与会话列表两条入口共用。
## channel_type 由调用方给定 —— 会话列表里可能是群聊,不能写死单聊。
func _open_channel(cid: int, ctype: int) -> void:
	channel_id = cid
	channel_type = ctype
	status_label.text = "打开会话中 ..."

	# local-first 历史:本地为渲染真源,空会话自动补一次最新窗口。
	var page: Dictionary = await chat.open(channel_id, channel_type)
	open_btn.disabled = false
	if not page.ok:
		status_label.text = "拉历史失败：%s" % page.error
		return
	list.clear()
	_rendered_message_ids.clear()
	# SDK 返回显示序 DESC(最新在前);倒序渲染成聊天窗惯例的旧→新。
	var msgs: Array = page.messages.duplicate()
	msgs.reverse()
	for m in msgs:
		_render_stored(m)
	_track_paging(page)
	status_label.text = "会话 channel_id=%d,历史 %d 条" % [channel_id, msgs.size()]
	_mark_read_latest(msgs)


func _on_load_older_pressed() -> void:
	if not _has_more_before or _earliest_server_message_id <= 0:
		return
	older_btn.disabled = true
	var page: Dictionary = await chat.load_older(_earliest_server_message_id)
	if page.ok:
		var msgs: Array = page.messages.duplicate()
		msgs.reverse()
		# 插到顶部:重建文本(demo 简化;正式 UI 用 ItemList/ScrollContainer)。
		var old_text := list.get_parsed_text()
		list.clear()
		for m in msgs:
			_render_stored(m)
		list.append_text(old_text)
		_track_paging(page)
	older_btn.disabled = not _has_more_before


func _track_paging(page: Dictionary) -> void:
	_has_more_before = bool(page.has_more_before)
	for m in page.messages:
		var sid := int(m.get("server_message_id", 0))
		if sid > 0 and (_earliest_server_message_id == 0 or sid < _earliest_server_message_id):
			_earliest_server_message_id = sid
	older_btn.disabled = not _has_more_before


func _mark_read_latest(msgs: Array) -> void:
	var max_pts := 0
	for m in msgs:
		max_pts = max(max_pts, int(m.get("pts", 0)))
	if max_pts > 0:
		await chat.mark_read(max_pts)


func _on_send_pressed() -> void:
	if channel_id < 0:
		status_label.text = "先打开会话"
		return
	var content := msg_edit.text.strip_edges()
	if content.is_empty():
		return
	msg_edit.clear()
	var resp: Dictionary = await chat.send_text(content)
	if not resp.ok:
		_append("[color=red]发送失败：%s[/color]" % resp.error)
		return
	# 就地把自己的消息画出来。message_received(reason=local_create)也会送来同一条,
	# 但它要等下一轮事件轮询,而投递回执走的是另一条更快的信号 —— 只靠信号的话
	# 会先看到「投递状态」再看到自己说的话。_render_stored 按 message_id 去重,
	# 两条路径重合时不会画两次。
	_render_stored({
		"message_id": int(resp.get("message_id", 0)),
		"from_uid": PrivchatSession.user_id,
		"content": content,
	})


func _on_message_received(m: Dictionary) -> void:
	_render_stored(m)
	# 会话开着就即时已读。
	var pts := int(m.get("pts", 0))
	if pts > 0:
		chat.mark_read(pts)


func _on_send_status(message_id: int, status: int, _server_message_id: int) -> void:
	_append("[color=gray]投递状态 message_id=%d → %d[/color]" % [message_id, status])


func _on_unread_changed(_cid: int, count: int) -> void:
	if channel_id > 0:
		status_label.text = "会话 channel_id=%d,未读 %d" % [channel_id, count]


func _render_stored(m: Dictionary) -> void:
	var message_id := int(m.get("message_id", 0))
	if message_id > 0 and _rendered_message_ids.has(message_id):
		return
	if message_id > 0:
		_rendered_message_ids[message_id] = true
	var from_uid: int = int(m.get("from_uid", 0))
	var content: String = str(m.get("content", ""))
	var who := "我" if from_uid == PrivchatSession.user_id else "对方(%d)" % from_uid
	_append("[b]%s[/b]: %s" % [who, content])
