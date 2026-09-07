# 协议二进制 schema(.bfbs)

来自 `privchat-application-module-mmorpg/protocol/scripts/generate.sh`(flatc 24.3.25),
按 GODOT_FLATBUFFERS_CODEC_SPEC §7 以资源形式打包,`SHA256SUMS` 是固定摘要:
`PrivchatFlatBuffers.load_schema()` 返回的 `digest` 与之不符即拒绝使用该协议。

`fixture_move_to.bin` 是 module-mmorpg 的 golden fixture(`fixtures/scene/v1/valid/intent/move_to.bin`),
三端(Rust / Kotlin / Godot)对同一份字节必须解出同一结构。
