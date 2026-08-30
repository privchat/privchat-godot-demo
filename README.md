# privchat-godot-demo

`privchat-godot` addon 的演示工程,同时充当它的**回归测试套件** ——
addon 的每次改动都靠这里的 headless e2e 验证。

`addons/privchat` 是指向 `../privchat-godot/addons/privchat` 的相对软链接;
链接丢失时用 `ln -sfn ../../privchat-godot/addons/privchat addons/privchat` 恢复。

## 前置

需要三个服务在跑(**共用的开发服务,不要随意启停**):

| 服务 | 端口 |
|---|---|
| privchat-server | 9001(TCP)· 9090(service admin API) |
| privchat-application | 8080 |
| redis | 6379 |

登录用 `+8613800000001` / `+8613800000002`,验证码由脚本从 redis 读取
(开发环境无短信通道)。

## 运行

```bash
GODOT=~/projects/Menghuan/.staging-godot/tools/Godot.app/Contents/MacOS/Godot
DEMO=~/projects/Menghuan/privchat-godot-demo
```

图形界面:

```bash
$GODOT --path $DEMO
```

编辑器:

```bash
$GODOT -e --path $DEMO
```

单条 e2e:

```bash
$GODOT --headless --path $DEMO -s res://scripts/auto_chat_check.gd
```

全部 8 条:

```bash
for s in auto_login_check auto_comm_check auto_chat_check auto_game_check \
         auto_resilience_check auto_robustness_check auto_token_check \
         auto_navigation_check; do
  echo -n "$s => "
  $GODOT --headless --path $DEMO -s res://scripts/$s.gd 2>&1 \
    | grep -E 'VERIFY_OK|VERIFY_FAILED'
done
```

每条脚本以 `VERIFY_OK` / `VERIFY_FAILED` 收尾;退出时**不应**出现
`ObjectDB instances leaked`(出现即表示有节点或协程未正确释放)。

## e2e 覆盖

| 脚本 | 覆盖 |
|---|---|
| `auto_login_check` | 短信登录 → authenticate → connect → bootstrap 门禁 |
| `auto_comm_check` | 双账号单聊收发、投递回执、Room 订阅与广播 |
| `auto_chat_check` | 历史、上滑翻页、已读推进、未读数、会话列表 |
| `auto_game_check` | 频道订阅 + transfer 指令 + 事件去重 |
| `auto_resilience_check` | 断连 → 离线本地读 → 离线入队 → 重连 → 自动重订阅 → 投递 |
| `auto_robustness_check` | 误用与生命周期:未 start 调用、close 排空、状态抖动、超时不泄漏、二进制 transfer |
| `auto_token_check` | 真实刷新、single-flight、终态不循环、两个竞态、刷新期本地读 |
| `auto_navigation_check` | 会话列表 → 聊天页:`channel_id`/`channel_type` 传递、消费后清零、logout 清理 |

## 版本

| 组件 | 版本 |
|---|---|
| Godot 运行时 | 4.5.stable |
| 工程 `config/features` | 4.5 |
| godot-cpp | 分支 4.5 @ `60b5a41`(上游 4.x 最新,**没有** 4.6/4.7) |
| addon `compatibility_minimum` | 4.3(刻意保留,让 4.3/4.4 项目也能用该 addon) |

## HiDPI

Godot 把 `window/size/viewport_*` 当**物理像素**开窗:在 2x 屏上 960 只有
480 逻辑点,窗口小一半、内容跟着小。工程用两处配合解决:

| 位置 | 作用 |
|---|---|
| `project.godot` 的 `stretch/mode="canvas_items"` | 把 960x640 设计视口拉伸到实际窗口,内容随之放大 |
| `privchat_session.gd` 的 `_apply_display_scale()` | 启动时按 `DisplayServer.screen_get_scale()` 放大**窗口**并重新居中 |

**只放大窗口,不要再设 `content_scale_factor`** —— 它会与 stretch 叠乘成
4 倍并把内容裁出窗口。写死 2 倍同样不行,非 Retina 屏上会把窗口撑爆。

## 已知限制

- **图形界面仅经自动走查**,手感与交互反馈仍需人工确认一次;
- 仅 macOS arm64;Android / iOS / Windows 构建未接线;
- 中文字体走 `SystemFont` 回退链,接移动端前须换成随包字体(见 `themes/README.md`);
- `auto_game_check` 验证的是通用 Transfer 原语,**不代表**真实玩法正路径;
- 无 CI,全部验证依赖本机与共用开发服务。
