# privchat-godot-demo

`privchat-godot` addon 的演示工程,同时充当它的**回归测试套件** ——
addon 的每次改动都靠这里的 headless e2e 验证。

`addons/privchat` 是指向 `../privchat-godot/addons/privchat` 的相对软链接;
链接丢失时用 `ln -sfn ../../privchat-godot/addons/privchat addons/privchat` 恢复。

## 运行

Godot 没装进 PATH,二进制在 staging 目录里;先把两个变量 export 出来,
下面所有命令(含本文其余部分的 `$GODOT` / `$DEMO`)都能直接用:

```bash
export GODOT=~/projects/Menghuan/.staging-godot/tools/Godot.app/Contents/MacOS/Godot
export DEMO=~/projects/Menghuan/privchat-godot-demo

$GODOT --path $DEMO                                    # 图形界面
$GODOT --headless --path $DEMO -s res://scripts/auto_mmo_check.gd   # headless e2e
```

图形界面的登录方式由服务端配置决定(`GET /app/config/bootstrap` 的
`auth.registerModes`,见 `scripts/login.gd`):本机是 `USERNAME_PASSWORD`,
登录页给的是账号 / 密码 / 昵称与「登录」「注册」;没有账号就直接注册一个
(账号 3-32 位,密码 8-128 位)。headless 脚本仍用手机号种子账号,
因为 `sms-login` 在该模式下依然可用。

## 前置

需要三个服务在跑(**共用的开发服务,不要随意启停**):

| 服务 | 端口 |
|---|---|
| privchat-server | 9001(TCP)· 9090(service admin API) |
| privchat-application | 8080 |
| redis | 6379 |

登录用 `+8613800000001` / `+8613800000002`,验证码由脚本从 redis 读取
(开发环境无短信通道)。

### SPKI pin(必需)

privchat-sdk 落地 `feat(transport): require a pinned server identity` 之后,
没有 SPKI pin 就拒绝建立 tcp:// / quic:// 连接,且 **tcp:// 是 TLS-only,
不会退回明文**。网关地址、service API、pin 三个值必须同步变化,统一收在
`scripts/demo_env.gd`,所有入口经 `DemoEnv.make_client()` 取用。

服务端换证书后不必改代码:

```bash
PRIVCHAT_SPKI_PIN=<新 pin> $GODOT --headless --path $DEMO -s res://scripts/auto_login_check.gd
```

新 pin 的取法:

```bash
openssl x509 -in privchat-server/certs/server.crt -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | openssl base64
```

> 排错提示:`sms-login` 返回 `application code=4` 且 application 日志里是
> `privchat_devices_user_id_fkey`,说明演示账号(+86138…01/02)在 server 当前使用的
> 数据库里不存在——共享 server 曾切换过库(`privchat` → `privchat_dev`),把
> `privchat_users` 里这两行拷过去即可,不是代码问题。
>
> 排错提示:`tls handshake eof` 表示对端在讲明文 —— 多半是 server 进程
> 早于 TLS 支持启动,重启一次即可,不是 pin 配错。pin 不匹配报的是证书
> 校验失败,两者症状不同。
>
> 也不要试图改指另一个已开 TLS 的 server 实例:token 由
> privchat-application(:8080)经 9001 签发,换实例后 `authenticate`
> 直接返回 `10001 Token 验证失败`。

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

全部 9 条:

```bash
for s in auto_login_check auto_comm_check auto_chat_check auto_game_check \
         auto_resilience_check auto_robustness_check auto_token_check \
         auto_navigation_check auto_mmo_check; do
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
| `auto_login_check` | 先 `GET /config/bootstrap` 取服务端配置的注册方式:USERNAME_PASSWORD → 注册新账号 → 账号密码登录 → 错误密码被拒;PHONE_SMS → 短信登录;之后 authenticate → connect → bootstrap 门禁 |
| `auto_comm_check` | 双账号单聊收发、投递回执、Room 订阅与广播 |
| `auto_chat_check` | 历史、上滑翻页、已读推进、未读数、会话列表 |
| `auto_game_check` | 频道订阅 + transfer 指令 + 事件去重 |
| `auto_resilience_check` | 断连 → 离线本地读 → 离线入队 → 重连 → 自动重订阅 → 投递 |
| `auto_robustness_check` | 误用与生命周期:未 start 调用、close 排空、状态抖动、超时不泄漏、二进制 transfer |
| `auto_token_check` | 真实刷新、single-flight、终态不循环、两个竞态、刷新期本地读 |
| `auto_navigation_check` | 会话列表 → 聊天页:`channel_id`/`channel_type` 传递、消费后清零、logout 清理 |
| `auto_mmo_check` | module-mmorpg 场景闭环(MMO_WORLD_SCENE_SPEC §12):后台 `admin/admin123` 开场景(玩家进未开场景 → 21600);双角色 enter 同一场景 → 同一 Room channel;`mmorpg/scene/heartbeat` transfer;对方 enter/leave 的 presence 事件;错误码 21607/21610/21601 原样到达;private-snapshot 重连恢复;重进使旧 session 失效;点击寻路 + 服务端绕障碍 + NPC 交互;**回合制战斗**(MMO_BATTLE_PROTOCOL_SPEC §15):走到可战 NPC → `options` 含 `battle` → 发起 → 战斗中移动 21613 → private snapshot 的 `open_slots` → 提交 ATTACK → 旧回合 21402 → 打到 `battle_settled` → 重新 enter 场景再退订战斗 Room |

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
