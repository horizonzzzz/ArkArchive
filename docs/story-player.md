# 剧情播放器

本文是原生 Flutter 播放器的维护文档，保留脚本解释、演出时序、音频和观看进度的必要约束。目录与加载入口见 [story-library.md](story-library.md)，资源来源和离线策略见 [asset-cache.md](asset-cache.md)，人物台词定位规则见 [character-archive.md](character-archive.md)。

## 代码入口

| 位置 | 职责 |
| --- | --- |
| `lib/story_player/script.dart` | `StoryScript.parse`、命令参数与原始行号 |
| `lib/story_player/runtime/story_engine.dart` | 指令注册、执行队列、动画、分支、暂停和跳转 |
| `lib/story_player/stage_state.dart` | 舞台、对白、立绘和效果状态 |
| `lib/story_player/ui/story_stage.dart`、`lib/story_player/ui/stage_painter.dart` | 舞台布局、文本和图层绘制 |
| `lib/story_player/ui/story_player.dart` | 播放控制、快进、进度条、生命周期和断点保存 |
| `lib/story_player/runtime/story_audio.dart`、`lib/story_player/runtime/just_audio_output.dart` | 音频接口、BGM 与音效通道 |
| `lib/story_player/runtime/playback_checkpoint.dart` | 可重建的执行路径 |
| `lib/story_player/data/playback_progress.dart` | 脚本指纹和断点匹配 |

## 脚本与演出约定

解析器去除 BOM、空白和 `//` 注释，支持反斜杠续行；指令名与参数键转小写，保留原始命令和未知指令。普通文本和具名文本转成 `dialogue`。带引号、转义和括号的参数不能用简单字符串分割替代。错误应携带原始行号：`commandIndex` 从 0 开始，脚本行号从 1 开始。

运行时为每类指令注册处理器，将结果写入 `StageState`，绘制层只消费状态。新增指令还要核对 `MediaCatalog.dependencies` 的资源收集，避免在线可播却无法完整缓存。未知指令记录诊断并继续，不应直接导致整篇剧情不可读。

以下规则来自历史 PRTS 对齐及当前回归，应在修改时保持：

- 舞台逻辑坐标为 1280×720。L/M/R 中心 x 为 440/640/840；立绘左上角为 `slotX - width / 2 + pos.x`、`720 - height / 2 - pos.y`。整张表情切片覆盖 `faceRect`，不要再次按身体尺寸裁剪；非焦点角色亮度为 0.5，`focus=n` 使全部变暗。
- 默认打字间隔为 40ms。未完成文字时点击先补全，再次点击才推进；未显示字符仍参与排版，防止文本逐字跳行。空具名对白、`dialog` 和 `aside` 清除底部对白，`subtitle` 不隐式清除它。
- 自动等待从打字完成后计时。打字累计用毫秒，自动等待换算为微秒，不能把不同单位直接相加。
- `delay`、`fadetime` 与部分动画随速度缩放，但 `imagetween`、`cgitem`、`showitem` 的时长需分别遵守处理器语义。不要对所有 `duration` 统一乘倍速；`block` 与 `isblock` 也不能统一替换。
- 动画由可暂停、可取消的帧调度执行。循环按 `elapsed % duration / duration` 重复；零时长直接落终值，循环动画不能永久阻塞命令队列。
- 淡出完成前对象仍应参与绘制。隐藏、更新、重播与图层替换通过 epoch 或会话标识取消旧任务，旧的淡出回调不能删除新对象，旧循环也不能复活。
- `subtitle.multi` 合并历史但替换舞台文字；`sticker.multi` 还会续接可见文字，已显示部分不重新打字。分支、日志和舞台文本不是同一个状态。

字体 `assets/fonts/NotoSansHans-Medium.ttf`、滑动遮罩和 `assets/images/prts_ui/` 装饰图随包提供。`FontLoader` 使用 TTF，不能直接换回上游 WOFF2。游戏背景、立绘和音频通过 `MediaCatalog` 映射并按需加载。

## 音频、暂停与取消

`StoryAudio` 提供执行、暂停、恢复、停止和释放；`SilentStoryAudio` 可用于测试。`JustAudioOutput` 用独立通道播放 BGM 和音效，前奏只播放一次，循环体单独循环。

资源加载和播放请求完成前，必须再次核对 epoch 与请求标识；暂停、跳转、重播或销毁后，旧请求不得重新开始播放。播放列表的 `currentIndex` 监听需忽略重复索引，避免 `setLoopMode` 反馈触发微任务循环。修改音频时还需验证 intro→loop、停止后慢请求返回、重复切歌与页面退出。

## 断点、进度条与人物回放

观看进度按 `StoryEntry.path` 隔离。指纹是命令 `raw` 列表经 JSON 编码后的 SHA-256，与人物节选使用的原始脚本字节 SHA-256 不同。只有指纹匹配且 checkpoint 对当前脚本有效时才能恢复。

`PlaybackCheckpoint` 保存 `cursor` 和 `trace`，通过重演执行路径恢复场景，不保存逐帧动画或音频播放时间。`trace` 中非负值表示指令索引，`-1` 表示跳节点，`-2 - optionIndex` 表示选项；路径长度上限为 100000。修改编码必须考虑已有本地断点。

- 普通进入先从头展示，由用户点击继续观看后校验并恢复旧断点；恢复失败应明确反馈。
- `seekToCommand` 停止旧动画和音频、清空场景并从头重建，恢复目标处的 BGM/环境音及原暂停状态。重建按首个可用选项走分支，最多执行 `commands.length * 8` 步防循环；不可达目标返回失败，不伪造定位成功。
- 进度条对应合法停点，不对应音频时间；选项等待、纯视频、尚未开始或已结束时禁用。长按快进档位为 2/4/8/16 倍，下移每 64 逻辑像素换一档。
- 断点写入跟随 `checkpointRevision`，避免逐帧重复写磁盘。应用失去前台时强制保存正常进度，并结束快进和拖动状态。
- 人物档案回放期间，推进、跳转、生命周期变化、结束和退出均不能写入或清除原断点，也不提供原断点续播。只有确认「继续观看」替换本篇断点后，才恢复保存。修改任何保存路径都要保留此保护。
- 普通观看到达结束画面时记录已看完并清除断点；未开始或中途退出不会记录。写入按发生顺序串行，重播产生的新断点不能被上一轮结束操作删除。人物档案回放未确认「继续观看」前，即使到达结尾也不记录已看完。

## 回归与已知边界

解释器和演出变更优先运行：

```sh
flutter test test/script_test.dart test/engine_test.dart test/alignment_runtime_test.dart test/alignment_painter_test.dart test/slide_mask_test.dart
flutter test test/story_player_layout_test.dart test/story_fast_forward_test.dart test/playback_progress_test.dart test/playback_progress_widget_test.dart
```

布局回归应挂载完整 `StoryPlayer`，只测 `StoryStage` 无法发现外层约束造成的零宽度。演出回归应检查动画中间帧、取消和重播；仅测最终状态不能确认淡出或循环正确。

可显式运行真实脚本资源检查：

```sh
flutter test test/reference_live_test.dart --dart-define=STORY_REFERENCE_URL=https://torappu.prts.wiki/gamedata/latest/story/activities/act55side/level_act55side_01_end.txt
```

此检查下载静态依赖、解码图片并报告指令覆盖，默认不联网；它不能证明动态演出和音频听感正确。历史视觉参照为 [PRTS TL-1 行动后](https://prts.wiki/w/TL-1_%E5%BA%B8%E4%BF%97%E7%9A%84%E5%AE%9E%E8%B7%B5/END)。应用原生解释脚本，不下载执行 PRTS 播放器 JavaScript；参考端构建文件名会变化。

当前 `bgeffect`、`effect`、`video` 和依赖未授权字体的 `spellsticker` 仍跳过；`spellstickerclear` 为空处理。`cameraeffect=Chaos`、部分 `avgdisplay` 样式和非 `group_location_stamp` 的 `animtext` 尚不支持。通讯窗口部分模板、波形、关键帧和占位图仍简化，商业字体以 Noto 近似；随机震动不保证逐帧一致。`fit_mode` 仅保留元数据，未实现额外适配语义。

历史对齐细节可用 `git show 70b0fd2^:docs/player_alignment.md` 查阅；其旧测试数量和资源打包说明已过时。断点相关历史入口为 `f4a8892`、`261e499`，进度条为 `60a2c6a`、`6bb88e0`，人物回放保护为 `7fdb2f5`。
