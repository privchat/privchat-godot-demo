# demo_theme.tres

全局主题,唯一职责是提供中文字体 —— 没有它,Godot 默认字体渲染不出 CJK,
所有中文显示为方框。

## 字体链是权宜之计

`SystemFont` 依赖**宿主机已安装**的字体,按 `font_names` 顺序回退:

```
Hiragino Sans GB W3  macOS
PingFang SC          macOS
Microsoft YaHei      Windows
Noto Sans CJK SC     Linux / Android
Source Han Sans SC   通用
sans-serif           最终兜底(可能仍无 CJK)
```

**接入 Windows / Android / iOS 前必须换成随包发布的开源 CJK 字体**
(如 Noto Sans SC 子集),否则:

- 目标机器缺字体时回退到无 CJK 的 sans-serif,又变方框;
- 各平台字形不同,布局在不同设备上不一致。

届时改为 `FontFile` 指向 `res://fonts/` 下的实际字体文件,不再用 `SystemFont`。
