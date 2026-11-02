# 剧情播放器演出对齐记录

本文记录 2026-11-02 对 TL-1「庸俗的实践」行动后的实测依据、当前模块边界和仍需校准的效果。参考页是 [PRTS TL-1/END](https://prts.wiki/w/TL-1_%E5%BA%B8%E4%BF%97%E7%9A%84%E5%AE%9E%E8%B7%B5/END)。目标是原生 Flutter 播放器，不嵌入 PRTS 网页运行时。

## 参考页面实际加载了什么

当前页面按钮名称为「完整加载」。点击后观察到三个元数据请求：

- [story_variables.json](https://torappu.prts.wiki/gamedata/latest/story/story_variables.json)：音频变量等数据。
- [character.json](https://torappu.prts.wiki/assets/avg/character.json)：立绘单图、身体与表情差分、尺寸和位置。
- [background.json](https://torappu.prts.wiki/assets/avg/background.json)：背景 PPU（像素到舞台尺寸的换算比例）。

剧情本身来自页面的 `#datas_txt`，没有观察到额外的动态剧情接口请求。当前内联文本为 25,848 个字符。正文含 178 条 `charslot`、37 条 `Blocker`、47 条 `Delay`、5 条 `PlayMusic`、24 条 `PlaySound`、5 条 `CameraShake`、2 条 `BackgroundTween`、1 条 `Imagetween`、4 条 `focusout` 和 13 条 `interlude`。这些是指令出现次数，不是资源去重后的数量。

网络中实际出现的音频 URL 有 29 个，包括：

- `assets/audio/music/static/m_bat/m_bat_snowmonster_intro.mp3` 与 `..._loop.mp3`。
- `assets/audio/avg/d_gen_explo_n.mp3`。
- `assets/audio/avg/d_avg_battlefield_environment.mp3`。
- `assets/audio/avg/d_avg_warmbonfire_loop.mp3`。

页面资源调度与映射代码见 [StoryPlayer.QBOFHASl.js](https://static.prts.wiki/widgets/production/StoryPlayer.QBOFHASl.js) 和 [context.DG_3DzZj.js](https://static.prts.wiki/widgets/production/context.DG_3DzZj.js)。文件名包含构建哈希，未来可能变化；它们仅作为本次对齐依据，应用不下载执行这些 JavaScript。

公开游戏数据的 [story_review_table.json](https://torappu.prts.wiki/gamedata/latest/excel/story_review_table.json) 将本剧情定位到 `activities/act55side/level_act55side_01_end`。首页目录直接读取这张表（`storyCanShow=1` 的条目，按章节分组），再按 `storyTxt` 拼出[原始脚本](https://torappu.prts.wiki/gamedata/latest/story/activities/act55side/level_act55side_01_end.txt)。该静态站返回 `Access-Control-Allow-Origin: *`，Web 端同样可读；应用不需要内置关卡列表。

## 已核实的映射与布局

| 项目 | 可复核的依据 | Flutter 对应实现 |
|---|---|---|
| 背景和 CG | `context` 中背景目录为 `avg/background/`，CG 为 `avg/images/`，标识转小写 | `MediaCatalog.image` |
| 音频 | `$snowmonster_intro` 对应 `Sound_Beta_2/Music/static/m_bat/m_bat_snowmonster_intro`，转小写并映射到 `assets/audio/` | `MediaCatalog.audio` |
| 立绘 | `avg_npc_334` 的单图路径为 `avg_npc_334/avg_npc_334`；`avg_4247_oxi_1#6$3` 按 body=2/index=5 选中 `6$3` 表情 | `MediaCatalog.character` |
| 表情合成 | `bakeFaceOverlayTexture` 先画完整身体，再把整张表情切片画入 `faceRect` | `StagePainter._character` |
| 立绘大小与位置 | 逻辑舞台 1280×720，L/M/R 中心 x 为 440/640/840；左上角 x=`slotX-width/2+pos.x`，y=`720-height/2-pos.y` | `StagePainter._character` |
| 角色焦点 | `applyCharacterSlotFocus` 将非焦点角色亮度设为 0.5；`focus="n"` 使全部变暗 | `StoryEngine._characterSlot` |
| 主对白字体 | PRTS 网络字体是 `NotoSansHans-Medium.woff2`，weight=500，正文 24px、姓名最大 30px | 转成 TTF 后打包为 `assets/fonts/NotoSansHans-Medium.ttf`，运行时交给 `FontLoader` |
| 对白区域 | 底部区域高 182；姓名左边 20.7501、宽 312.3；正文左边 382.28、宽 735；姓名灰色、正文白色 | `StoryStage`，已移除原型的金色边框与姓名色 |
| 打字机 | 默认每字 40ms；点击未完成文本先补全，再次点击推进 | `StoryEngine`、`storyTextSpans`；未显示字符仍参与排版 |
| 背景与立绘过渡 | `fadetime` / `duration` 按秒；`block` 与 `isblock` 分别控制队列等待；非阻塞动画与后续对白并行 | 运行时可取消的动画调度 |
| 音频 | BGM 前奏只播一次，循环体单独循环；默认 crossfade 为 0.4 秒；音效默认 channel 为 key，可独立停止 | `JustAudioOutput`，播放列表与双播放器淡化 |

PRTS 当前生产代码将主对白字体定义为 `NotoSansHans-Medium`、weight=500；上游[原始文件](https://static.prts.wiki/NotoSansHans-Medium.woff2) 是 WOFF2。`FontLoader` 只接受 TTF/OTF 容器，Android、iOS 和桌面端都无法解码 WOFF2，因此仓库保存了用 fontTools 转出的 `assets/fonts/NotoSansHans-Medium.ttf`（约 8 MiB，未做子集裁剪），运行时从 `rootBundle` 读取，不再请求网络。字体为 Noto Sans 的 OFL 授权，可随应用分发；各平台字形光栅化差异仍需独立确认。

## 核心模块边界

- `lib/main.dart`：仅启动应用。
- `lib/app/`：主题、PRTS 剧情目录列表与资源加载进度。
- `lib/story_player/script.dart`：纯脚本解析，保留命令参数、原始文本和行号。
- `lib/story_player/data/`：故事文档与目录、资源映射、按 URL 去重预加载、原生端原子写入缓存。Web 暂为内存缓存。
- `lib/story_player/runtime/`：注册制指令处理、阻塞/并行动画、对白与选择分支、音频输出。未知命令记录诊断后继续。
- `lib/story_player/ui/`：1280×720 舞台缩放、立绘合成、文本、播放控制与诊断。
- `lib/story_player/story_player.dart`：供外部页面使用的导出入口。

外部页面用 `StoryRepository.loadIndex()` 取目录、`loadEntry()` 下载脚本，或直接用 `load(Uri)` 指定脚本地址，再调用 `prepare`，最后把 `PreparedStory` 传给 `StoryPlayer(story: prepared)`。播放器组件本身不读取 URL、不查询目录，也没有内置剧情列表；目录逻辑只在 `StoryRepository`。音频接口可注入静音实现，便于测试。

## 尚未完全对齐的效果

1. **游戏动态效果**：本剧情含 7 条 `bgeffect` 和 3 条 `effect`。当前 PRTS 生产播放器对这些指令给出 `unsupported_command` 并跳过；官方变量表可核实名称映射（例如 `$eb_burn` → `AVG_fire_01`），但这不足以推出 Prefab 内部粒子曲线或 Shader。本实现明确记录未支持项，不按名称臆造粒子。
2. **镜头震动**：已支持脚本强度、持续时间与衰减；具体轨迹与游戏随机序列尚未做逐帧校准。
3. **滑动转场**：PRTS 生产播放器加载 `https://static.prts.wiki/widgets/production/slide_mask.BQ3hXFW7.png`，并在 shader 中使用 `slide=0.601`、`end=0.641`、横向 `extent=0.787`（纵向 `extent=1`）和 `progress=clamp((alpha-0.2)*1.25,0,1)`。Flutter 版本复用该纹理及公式，纹理已保存为 `assets/images/slide_mask.png` 并从 `rootBundle` 读取；shader 像素测试验证了预乘透明度输出。坐标朝向与光栅化仍需逐帧比较，纹理缺失时回退到线性遮罩。
4. **通讯窗口**：可按 channel 处理尺寸动画、头像和开关；遮罩边缘、头像裁切和嵌套窗口尚需游戏画面对照。
5. **长尾指令**：复杂贴纸、动画标题、视频与特殊角色动作未承诺支持。运行中可通过诊断查看跳过项。
6. **原生验收**：当前设备只有 Windows 与浏览器，没有连接 Android / iOS 真机。浏览器构建和测试不替代移动设备的音频衔接、横屏、飞行模式重启和帧率验收。Windows 的 `just_audio` 需要独立的平台实现，本轮以 Android/iOS/Web 为音频目标。

持久缓存目前按 URL 的 SHA-256 命名，保留媒体扩展名并在下载完成后原子重命名。不同 URL 的相同内容尚未做内容哈希去重；`latest` 元数据与脚本尚未建立版本更新/失效策略。缓存命中与纯内存模拟测试不能代替完整断网验收。

## 本轮验证结果

- `flutter analyze`：通过，无诊断。
- `flutter test --reporter expanded`：16 项通过，1 项联网测试按默认配置跳过；包含滑动遮罩 shader 的像素输出回归和打包字体/纹理的可读性检查。
- `flutter build web --release --no-web-resources-cdn`：通过，输出位于 `build/web/`。
- `git diff --check`：将 CRLF 按 Windows 换行处理后通过。
- 浏览器：TL-1 原始脚本完成加载并显示「开始播放」，点击后按钮消失。该轮字体与滑动遮罩纹理被 CORS 拦截；两项现已改为打包资源，尚未在浏览器重新跑完整演出验收。
- 独立联网测试：GitHub 脚本入口因本机 DNS 解析失败退出；改用 PRTS TL-1/END 页面后通过。解析 639 条指令，检查 92 个静态资源并成功解码 63 张图片，解码内存约 134.3 MiB；未支持指令为 `bgeffect`、`effect`。这项检查验证资源下载与图片解码，不代表音频听感或完整演出验收。

## 资源与授权边界

公共可访问不代表获准再分发。游戏文本、立绘、CG 与音频不提交到仓库或捆绑到安装包；开发时只按需请求公开源。仓库内只有两类上游静态资源：OFL 授权的 Noto Sans 字体（转为 TTF）和滑动遮罩纹理，均用于渲染效果。用户自有资源的导入也不能被笼统描述为「零侵权风险」。发布前仍需核实上游服务使用条件与素材授权。
