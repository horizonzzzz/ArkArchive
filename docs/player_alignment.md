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

页面资源调度与映射代码见 [StoryPlayer.DH9HUkmm.js](https://static.prts.wiki/widgets/production/StoryPlayer.DH9HUkmm.js) 和 [context.DG_3DzZj.js](https://static.prts.wiki/widgets/production/context.DG_3DzZj.js)。文件名包含构建哈希，未来可能变化；它们仅作为本次对齐依据，应用不下载执行这些 JavaScript。

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
6. **原生验收**：Windows 已通过 `just_audio_windows` 接入音频平台实现，release 构建通过；尚未验收实际音频播放。Android / iOS 真机未连接，浏览器构建和测试不能替代移动设备的音频衔接、横屏、飞行模式重启和帧率验收。

持久缓存目前按 URL 的 SHA-256 命名，保留媒体扩展名并在下载完成后原子重命名。不同 URL 的相同内容尚未做内容哈希去重；`latest` 元数据与脚本尚未建立版本更新/失效策略。缓存命中与纯内存模拟测试不能代替完整断网验收。

## 指令覆盖审计（2026-11-03）

本节以当时线上构建 `StoryPlayer.DH9HUkmm.js` 的指令分发表，以及 `story_review_table.json` 中的 2061 条 `storyTxt` 为样本，统计公开剧情脚本的指令分布。成功下载 2036 条（25 条返回 404），共 695,675 条指令行与 370,397 条对白行；只统计标签，不提交脚本和素材。

参考端指令表有 58 个 tag，可执行 56 个（`bgeffect`、`effect` 直接给出 `unsupported_command`）。Flutter 侧注册 28 个，命中其中 27 个，29 个未实现。按指令行计已覆盖 95.9%，参考端可执行而本实现缺失的占 3.6%，参考端同样跳过的占 0.5%，两端都不认识的拼写错误占 0.3%。脚本级影响更集中：约 40% 的脚本至少缺一个效果。

### 缺失且可按参考实现复现

| 指令 | 参考端行为 | 脚本占比 | 次数 |
|---|---|---|---|
| `cameraeffect` | `Grayscale` 全屏灰度（`amount`/`initamount`/`keep`/`block`）与 `Colorinverse` 反色 | 31.5% | 2,152 |
| `subtitle` | `x`/`y`/`width`/`size`/`alignment` 的旁白打字机，`multi` 可续接 | 30.0% | 8,107 |
| `multiline` | 同一句对白多行续接，`end=true` 结束 | 24.1% | 1,968 |
| `characteraction` | `move`/`jump`/`shake`/`zoom`/`exit`，含方向、`power`、随机角度与次数 | 22.0% | 4,599 |
| `sticker` 家族 | 自由坐标富文本贴纸、打字机、`stickertween`/`timersticker`/`stickerclear` | 12.0% | 5,915 |
| `animtext` | 仅 `group_location_stamp`：地点印章与 `<p=n>` 分段 | 6.4% | 264 |
| `charactercutin` | 立绘切入与 7 种展开遮罩 | 5.4% | 650 |
| `gridbg`/`verticalbg`/`largebg` | 多图拼接大场景、实色缝隙、`initposmode` | 4.9% / 0.6% / 2.4% | 226 / 32 / 123 |
| `largebgtween`/`largeimgtween` | 大场景补间，含 `ease`/`loop` | 4.7% | 150 |
| `cgitem`/`hidecgitem` | CG 道具层的透明度、位置、旋转与颜色动画 | 3.4% | 202 |
| `avgdisplay` | 仅 `style=bg` 有实现 | 1.8% | 137 |
| `showitem`/`hideitem` | 照片框/剪影框道具与相框 sprite | 1.2% | 24 / 25 |
| `focusparam` | 聚焦层的 `blur` 与 `Grayscale`/`Colorinverse` | 0.8% | 30 |
| `imagerotate` | 图片旋转与圈数 | 0.6% | 22 |
| `theater` | 剧院模式：隐藏 UI 并强制自动播放 | 1.0% | 41 |
| `video` | 全屏播放 `res`/`url`，播完恢复 UI | 0.3% | 7 |
| `spellsticker` | `sami`/`fire` 两种特殊字体样式 | 0.3% | 17 |
| `skipnode`/`skiptothis` | 跳过模式的分支节点 | 0.3% | 11 / 2 |

### 已实现但语义或参数不全

| 指令 | 缺口 | 语料证据 |
|---|---|---|
| `blocker` | 缺 `image` 与 `rfrom/gfrom/bfrom`；缺省 `a` 应为 1，当前按 0 处理（`story_engine.dart` 的 `_blocker`） | 缺 `a` 316 行；`image` 8 行 |
| `curtain` | 只画 0/2/4/6 方向，缺 1/3/5/7、`a`、`grad`、`delay` | 方向 1/3/5/7 共 77 行；`grad` 394 行 |
| `charslot` | `action=zoom/jump/shake` 与 `bstart/bend` 边缘黑化未实现，`action` 只用于判断 `setpos` | `action` 1,533 行；`bstart/bend` 约 3,900 行 |
| `character` | 缺 `xpos1/ypos1`、`transtype`、`enter`、`blackstart/blackend` | — |
| `camerashake` | 缺 `stop`、负数时长（=无限）、`randomness`；负时长当前不产生位移 | `duration=-1` 234 行；`stop` 13 行 |
| `focusout` | 缺 `lbg`/`cgitem` 目标与 `id` 通道；缓动为线性，参考端用 smoothstep | `cgitem` 25、`lbg` 12 |
| `interlude` | 只有矩形裁剪与头像；缺 6 种 `maskid` 模板、`type`、`slot`/`style`、`icharpos`/`icharscale`、`pfrom`/`pto`、`sfrom`/`sto`、`aduration` | `maskid` 192 行；`type=2/1` 共 110 行在当前实现中显示为空窗口 |
| `background`/`image` | 缺 `tiled`、`width`/`height` 倍率；缺省 `screenadapt` 时参考端不缩放，本实现按 `coverall` 缩放 | `background.width` 188 行；抽样 `image` 中 71% 省略 `screenadapt` |
| `imagetween`/`backgroundtween` | `loop` 只记录警告，`ease` 未实现 | — |
| `decision`/`predicate` | 只保留最后一次选择，多决策分支会走错；缺 `disabled` 选项 | 395 个脚本含分支 |
| `warp` | 拒绝回跳，参考端允许按标签跳转 | 7 行 |
| `header` | 未消费元数据：`fit_mode=BLACK_MASK`（黑边）、标题、`is_video_only`、`is_tutorial`、`is_skippable` | 2,036 行 header 被忽略 |
| 播放速度 | 缺 1×/2.5×/快速档，`delay` 与打字机不随档位缩放 | 固定 40ms |

### 参考端同样不处理，无法逆向

判据是参考 JS 自身对这些输入给出 `unsupported_command` 或 `unsupported_visual`，公开数据里只有名字：

- `bgeffect`/`effect`：`ca=new Set(['bgeffect','effect'])`；`story_variables.json` 仅提供 `e_slash_01_l` → `AVG_daoguang_attack_01_large` 一类映射，对应 PNG 与 `.prefab` 路径均 404。语料 1,984 + 1,173 行。
- `avgdisplay` 的 `bgeffect`/`animekv`/`effect` 样式（51 行）、`animtext` 除 `group_location_stamp` 外的名字、`cameraeffect=Chaos`（26 行）、`cgitem style=blocker`、非内置 `charslot` 槽位。
- 镜头与立绘动作的随机轨迹使用 `Math.random()` 且无种子，只能做到统计意义上相似；Pixi Text（WOFF2）与 Skia（TTF）的换行和字距也不会逐像素一致。

### 需要额外素材或平台能力

- 视频：`/assets/video/**/*.mp4` 公开可访问（实测 HTTP 206），路径需小写；Flutter 需引入播放插件，Windows 桌面没有官方 `video_player` 实现。
- 字体：`spellsticker` 用 `FZTYSK--GBK1-0.woff2`、`RoHMinSinkStd-UB.woff2`，`animtext` 用 `SourceHanSansCN-Heavy.woff2`；`FontLoader` 只接受 TTF/OTF，需转换并核对授权。
- `showitem` 相框、`interlude` 的 6 套模板、`animtext` 印章 sprite 都在 widget bundle 中；`avg/cutin/` 目录尚未在 `MediaCatalog.image` 中映射。

## 本轮验证结果

- `flutter analyze`：通过，无诊断。
- `flutter test --reporter expanded`：16 项通过，1 项联网测试按默认配置跳过；包含滑动遮罩 shader 的像素输出回归和打包字体/纹理的可读性检查。
- `flutter build web --release --no-web-resources-cdn`：通过，输出位于 `build/web/`。
- `git diff --check`：将 CRLF 按 Windows 换行处理后通过。
- 浏览器：TL-1 原始脚本完成加载并显示「开始播放」，点击后按钮消失。该轮字体与滑动遮罩纹理被 CORS 拦截；两项现已改为打包资源，尚未在浏览器重新跑完整演出验收。
- 独立联网测试：GitHub 脚本入口因本机 DNS 解析失败退出；改用 PRTS TL-1/END 页面后通过。解析 639 条指令，检查 92 个静态资源并成功解码 63 张图片，解码内存约 134.3 MiB；未支持指令为 `bgeffect`、`effect`。这项检查验证资源下载与图片解码，不代表音频听感或完整演出验收。

## 播放后黑屏修复

Windows 与 Web 出现音乐和历史记录正常、舞台全黑且无法点击的问题，根因是 `StoryPlayer` 外层 `Column` 未提供紧的横向约束。开始按钮消失后，`Stack` 唯一的非定位子组件变为 `SizedBox.shrink()`，使 `Positioned.fill` 中的整个舞台缩为零宽。外层改用 `CrossAxisAlignment.stretch`，让舞台始终占满可用宽度。

`test/story_player_layout_test.dart` 直接挂载完整播放器，覆盖开始按钮消失后的舞台宽度、点击补全文本和推进对白。旧代码可复现宽度期望 800、实际 0；单独测试 `StoryStage` 无法覆盖这一外层约束。

修复后验证：`flutter test --reporter expanded` 为 17 项通过、1 项联网测试按配置跳过；`flutter analyze` 无诊断。Windows 与 Web 的真实关卡画面仍需运行复验。

## 资源与授权边界

公共可访问不代表获准再分发。游戏文本、立绘、CG 与音频不提交到仓库或捆绑到安装包；开发时只按需请求公开源。仓库内只有两类上游静态资源：OFL 授权的 Noto Sans 字体（转为 TTF）和滑动遮罩纹理，均用于渲染效果。用户自有资源的导入也不能被笼统描述为「零侵权风险」。发布前仍需核实上游服务使用条件与素材授权。
