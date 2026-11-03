# 嘉立创外壳与键床上传包

嘉立创将 `keybed.3mf` 识别为一个模型，因此不能再用该文件作为“键床板 + 13 个键帽”的打印对象包。

## 上传方式

上下壳使用单实体 STL：

- `bottom_shell_single.stl`
- `top_shell_single.stl`

检查结果见 `shell_parts.json`。两个文件均为单连通、闭合、绕序一致、正体积，
开放边和非流形边均为 0。上壳已翻成可见顶面朝下，下壳底面位于 Z=0。

键床部分优先上传：

- `keybed_parts.zip`

压缩包包含 14 个独立 STL：

- 1 个键床板
- 8 个白键帽：C4、D4、E4、F4、G4、A4、B4、C5
- 5 个黑键帽：C#4、D#4、F#4、G#4、A#4

如果嘉立创不接受 ZIP 包，则进入 `keybed_parts/`，逐个上传全部 14 个 STL。

不要在键床订单中继续使用由平台自动拆出的
`007white_key_6(1)1.step`、`002white_key_1(1)1.step` 等派生 STEP。

## 检查结果

`keybed_parts.json` 记录了每个文件的：

- AABB 包络
- 三角面数
- 体积
- 是否水密
- 三角面绕序是否一致
- SHA-256

14 个部件全部：

- `watertight=true`
- `winding_consistent=true`
- 体积为正
- 已摆放到 `Z=0`
- 功能高度方向为 +Z

## 打印摆放

每个键帽已分别居中，底面位于 Z=0。键床板也已翻转成 PCB 接触面朝下、开口朝上的姿态。

键帽和键床板必须作为独立零件排盘，不能相互融合。
