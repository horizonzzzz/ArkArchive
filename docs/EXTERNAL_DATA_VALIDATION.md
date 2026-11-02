# 剧情外部数据验证与 Flutter 接入可行性

> 验证日期：2026-11-02  
> 范围：外部剧情索引、脚本、图片与音乐样本；结合 PRTS `0-2/BEG` 页面评估 Flutter 原生播放器接入。本文记录样本实测，不代表对上游服务的可用性承诺或法律意见。

## 结论

Flutter 原生实现剧情播放器的核心流程可行：客户端读取剧情索引和脚本，解析脚本中的演出指令，再通过资源映射取得背景、立绘和音频并缓存到本地。建议把 PRTS 页面和公开资源字典作为兼容性参考，不嵌入 PRTS 网页播放器，也不依赖它的动态播放接口。

本次验证发现，路线图中图片 URL 的直接拼接示例不适用于当前资源路径。背景、立绘需经过映射表解析，音乐变量也需先解析为资源路径。应先用 `0-2/BEG` 做一次离线端到端试点，再确定完整脚本兼容范围。

## 数据源验证

### 剧情索引和脚本

[Kengxxiao/ArknightsGameData](https://github.com/Kengxxiao/ArknightsGameData) 的 GitHub Contents API 当前可读取：

- 剧情索引：[`zh_CN/gamedata/excel/story_review_table.json`](https://api.github.com/repos/Kengxxiao/ArknightsGameData/contents/zh_CN/gamedata/excel/story_review_table.json?ref=master)，API 元数据报告大小为 1,896,810 bytes；本次记录的文件 SHA 为 `329ac2e4b6208729382c17315eda6e0f8251e9f5`。
- `0-2/BEG` 样本脚本：[`zh_CN/gamedata/story/obt/main/level_main_00-02_beg.txt`](https://api.github.com/repos/Kengxxiao/ArknightsGameData/contents/zh_CN/gamedata/story/obt/main/level_main_00-02_beg.txt?ref=master)，大小为 6,233 bytes；本次记录的文件 SHA 为 `58d96330d1c3b4db8b1e9260f009e542dc563e96`。

Contents API 返回的脚本正文为 Base64 编码。样本内容包含 `HEADER`、`Background`、`PlayMusic`、`Blocker`、`Image`、`Character` 和对话等结构，说明脚本需要经过 DSL 解析和状态推进，不能作为普通文本文件直接展示。脚本路径可由索引提供，解析后应保留原始命令和行号，方便错误诊断。

仓库的 `master` 分支会变化；以上 SHA 只标识本次查询的文件版本。实际客户端应记录数据版本或内容哈希，避免目录、脚本和缓存资源来自不同更新批次。

## PRTS 页面与媒体路径

检查的页面是 [PRTS 0-2 守卫/行动前](https://prts.wiki/w/0-2_%E5%AE%88%E5%8D%AB/BEG)。页面当前可切换完整加载和只加载文本；完整加载后播放器提供手动、自动、快速、全屏、文本、导出、反馈、开始和跳过等控件。当前页面加载的资源中观察到：

- 剧情变量：[`story_variables.json`](https://torappu.prts.wiki/gamedata/latest/story/story_variables.json)
- 角色配置：[`character.json`](https://torappu.prts.wiki/assets/avg/character.json)
- 背景配置：[`background.json`](https://torappu.prts.wiki/assets/avg/background.json)
- 样本 `$escape_intro` 和 `$escape_loop` 对应的音乐文件。

脚本里的资源标识需要查映射，而不是直接用 key 拼接 URL。PRTS 的 [Data Image](https://prts.wiki/w/%E5%BE%AE%E4%BB%B6:Data_Image)、[Data Char](https://prts.wiki/w/%E5%BE%AE%E4%BB%B6:Data_Char) 和剧情变量数据可用于验证映射。例如，本次查询得到：

| 脚本/变量标识 | 映射后的样本资源 | HEAD 结果 | Content-Length |
|---|---|---:|---:|
| `bg_cher_1` | [背景 PNG](https://media.prts.wiki/6/62/Avg_bg_bg_cher_1.png) | 200 | 254,205 bytes |
| `char_003_kalts_1` | [立绘 PNG](https://media.prts.wiki/d/d3/Avg_char_003_kalts_1.png) | 200 | 203,208 bytes |
| `$escape_intro` | [Intro MP3](https://torappu.prts.wiki/assets/audio/music/beta2_180603/m_dia_escape_intro.mp3) | 200 | 943,586 bytes |
| `$escape_loop` | [Loop MP3](https://torappu.prts.wiki/assets/audio/music/beta2_180603/m_dia_escape_loop.mp3) | 200 | 908,896 bytes |

以上是 2026-11-02 对单个样本发出的请求结果，不表示所有剧情素材均存在，也不表示服务有 SLA。`character.json` 还包含角色尺寸、位置和表情/图层配置；后续需要确认 Flutter 的立绘组合方式，不应假设所有角色都对应一张简单图片。

### 路线图 URL 需要修订

[road_map.md](road_map.md) 中示例的以下直拼路径在本次请求中返回 HTTP 404：

- `https://static.prts.wiki/assets/bg/bg_corridor.png`
- `https://static.prts.wiki/assets/character/char_003_kalts_1.png`

音乐同样不能只用音乐 key 直拼。样本变量先映射为 `Sound_Beta_2/Music/beta2_180603/m_dia_escape_intro`，再使用当前音乐资源路径规则。实施前应将“下载 URL 解析器”列为独立模块，并为背景、角色、音乐和音效各选取多个真实样本测试。

## Flutter 原生实现可行性

**数据解析：可行。** Flutter/Dart 可获取 JSON 和脚本文本；Contents API 的脚本正文需 Base64 解码后再按 UTF-8 处理。解析器应覆盖常见标签和台词格式，保留未知标签并给出诊断。不能仅靠一个正则就假定覆盖所有历史脚本格式。

**场景渲染：MVP 可行，全量等价尚未证实。** Flutter 的 `Stack`、图片、透明度、变换和动画能力足以实现背景、立绘槽位、遮罩、对话框、点击推进和基本转场。PRTS 页面使用网页端播放器资源；Flutter 需要把兼容命令映射到自己的舞台状态与处理器。特殊滤镜、复杂叠层和长尾演出需要按真实脚本逐项验证。

**音频：可行，部分行为需自行编排。** [`just_audio`](https://pub.dev/packages/just_audio) 支持 Android/iOS 的 URL、文件、播放列表和循环能力。Intro 播放一次后仅循环 Loop，以及跨曲 Crossfade，都需要应用层的播放状态控制，不能视为单一内置配置即可完成。

**离线：可行，但要验证完整闭环。** 一个剧情只有在脚本及其资源均已落盘后才能保证断网播放。缓存应支持重复资源去重、部分下载识别、下载失败诊断和版本更新；不能把“联网播放成功”当作离线验收。

## 风险与边界

1. **资源覆盖和服务限制未知。** 本次只测了一个剧情的样本资源；没有测全量路径、限速阈值、历史活动资源覆盖率或不同网络环境下的可达性。
2. **上游格式和路径可能变化。** GitHub `master`、PRTS 配置和静态资源服务均不是本项目控制的固定接口；需要记录版本/哈希，并对请求失败和字段变化提供诊断。
3. **版权与再分发需谨慎。** [GitHub 仓库 API](https://api.github.com/repos/Kengxxiao/ArknightsGameData) 当前返回 `license: null`。公共可访问不等于获准再分发；Wiki 页面内容许可也不自动授予游戏原始文本、图片和音频的再分发许可。不要将这些游戏素材直接打进安装包或公开仓库，公开发布前应核实使用授权。
4. **全量兼容范围尚未确定。** 目前只有一个 `0-2/BEG` 样本和一组媒体映射经过验证，不足以承诺所有活动、角色立绘结构或特殊演出都能正确播放。

## 建议的验证试点

以 `0-2/BEG` 建立最小端到端验收：

1. 从剧情索引定位脚本并解析脚本正文。
2. 解析背景、立绘、对话、`PlayMusic`、`Blocker` 等必要命令。
3. 使用资源映射取得 PNG 和 Intro/Loop MP3，下载并写入本地缓存。
4. 在 Flutter 横屏页面中播放背景、立绘和对话，验证音乐切换及点击推进。
5. 强制关闭并重启应用，开启飞行模式后再次播放同一剧情。

试点通过后，再扩展到含选择支、复杂立绘差分、SE 和特殊演出的脚本，并据此统计兼容率和调整工期。

## 本轮未验证

- 未遍历全量剧情、音频、背景和立绘资源。
- 未进行 CDN 并发、压力、限流或不同地区网络测试。
- 未在 Flutter 设备上实现或测量音频切换、图片内存和渲染帧率。
- 未给出游戏数据再分发的法律结论。
