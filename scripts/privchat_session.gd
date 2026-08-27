# privchat_session.gd — autoload 会话容器（对标 DemoChatScene 的会话级状态）
#
# PrivchatClient 在登录成功后创建一次，挂在 autoload 下跨场景存活；
# 退出登录时销毁，下次登录开启全新会话（对齐 cocos-demo teardownSession 语义）。
extends Node

var client: PrivchatClient = null
var user_id: int = -1
var device_id: String = ""
var mobile: String = ""


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
	user_id = -1
	device_id = ""
	mobile = ""
