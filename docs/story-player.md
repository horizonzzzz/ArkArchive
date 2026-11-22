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
- 进度条不对应音频时间；拖动手柄可连续定位，松手后保留所选位置，剧情跳转到最近的合法停点，继续播放时手柄随实际进度更新。选项等待、纯视频、尚未开始或已结束时禁用。长按快进档位为 2/4/8/16 倍，下移每 64 逻辑像素换一档。
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

当前 `video` 和依赖未授权字体的 `spellsticker` 仍跳过；`spellstickerclear` 为空处理。`cameraeffect=Chaos`、部分 `avgdisplay` 样式和非 `group_location_stamp` 的 `animtext` 尚不支持。通讯窗口部分模板、波形、关键帧和占位图仍简化，商业字体以 Noto 近似；随机震动不保证逐帧一致。`fit_mode` 仅保留元数据，未实现额外适配语义。

历史对齐细节可用 `git show 70b0fd2^:docs/player_alignment.md` 查阅；其旧测试数量和资源打包说明已过时。断点相关历史入口为 `f4a8892`、`261e499`，进度条为 `60a2c6a`、`6bb88e0`，人物回放保护为 `7fdb2f5`。

## 解包资源驱动的粒子特效

`bgeffect` / `effect` 使用通用的描述解析、粒子模拟和二维绘制管线。首批 `avg_fire_01`（8 个粒子发射器和 1 个烟雾网格）与 `avg_048_smoke_01`（4 个发射器）的 `fx.json` 和主贴图位于各自的 `assets/fx-runtime/particle/` 或 `assets/fx-runtime/baked/` 特效目录，已在 `pubspec.yaml` 注册，默认通过 Flutter `rootBundle` 离线加载，无需配置外部目录。
`bgeffect` / `effect` 使用统一的资源描述、粒子模拟和烘焙帧管线。运行时资源按 `assets/fx-runtime/particle/<name>/` 或 `assets/fx-runtime/baked/<name>/` 组织，并在 `pubspec.yaml` 中逐目录注册；Flutter 不递归收录目录。默认通过 `rootBundle` 离线加载，资源缺失只记录警告并继续对白。

资源映射来自 `story_variables.json`。背景特效默认绘制在背景之后、CG 之前，`drawAfterImages: true` 时移到 CG 之后；前景特效默认绘制在人物之后、遮罩之前，`drawAfterBlocker: true` 时移到遮罩之后。`bgeffect` 同组同层的新实例替换旧实例，普通 `effect` 可叠加多个实例；空名称按组或层清除。`delay`、`fade`、`fadetime`、`block` 和 `x/y` 遵守现有指令语义，三维资源按 Unity 的 Z→X→Y 顺序投影，旧资源继续使用兼容性缩放。

粒子、网格和采样动画共用特效时钟，暂停时冻结；重播、跳转和断点重建创建新实例，旧淡出回调不能删除新实例。循环资源按时钟取模，预热最多 10 秒，长帧最多追赶 250ms，并受发射器数量上限限制。转换器保留材质混合、UV、顶点色、Transform、显隐和动画轨道；不支持的 shader 或缺失贴图必须明确跳过，不能用误导性的矩形近似替代。

当前资源覆盖火焰、烟雾、刀光、雪、雨、扬尘、风沙、落沙、太阳光晕、速度线、电视噪声和黑白遮罩等。未接入的自定义后处理、部分 shader、Noise、HDR/Bloom 和辅助贴图仍属于近似范围，不能宣称逐像素复现。剧情脚本中的时间线、分组、层级、遮罩和多实例叠加必须单独核对，不能只凭静态截图验收。

需要重建派生资源时，先用 ArkUnpacker 导出对应 AssetBundle 的 typetree、PNG 和 shader，再运行 `tool/fx/avg_fx_extract.py` 或对应烘焙脚本。临时解包结果、原始 AssetBundle、完整 typetree 和验收帧放在忽略的 `.temp/`；只有运行时使用的 `fx.json`、主贴图和生成资源进入 `assets/`。转换失败或动画、材质、贴图引用不完整时应中止，不能生成半成品。

动态验收必须使用 Flutter 实际资源、正确的 `effect`/`bgeffect` 分组和脚本参数，按参考录像提取连续帧，覆盖出现、叠加、暂停、跳转和消散阶段。参考录像只用于方向、覆盖和形态核对；随机种子、Unity Noise、HDR/Bloom 和未支持 shader 造成的差异需记录为已知边界。游戏素材版权不因转换或打包改变，也不自动适用项目代码许可证。

可执行的基础自检：

```sh
uv run --no-project --with pillow python tool/fx/avg_fx_extract.py <解包目录> assets/fx-runtime/particle --project-particles --shaders ".temp/unpacked-avg-shaders/TT_[uc]shaders.ab.json"
uv run --no-project python tool/fx/test_avg_fx_extract.py
flutter test test/fx_test.dart
```

```sh
uv run --no-project python tool/fx/avg_fx_extract.py .temp/unpacked-fire-smoke assets/fx-runtime/particle
uv run --no-project python tool/fx/avg_fx_extract.py .temp/unpacked-smoke assets/fx-runtime/particle
uv run --no-project python tool/fx/test_avg_fx_extract.py
flutter test test/fx_test.dart
flutter run -d windows
```

每组资源目录为 `assets/fx-runtime/particle/<特效小写名>/` 或 `assets/fx-runtime/baked/<特效小写名>/`，并在 `pubspec.yaml` 注册；Flutter 不递归收录目录。含材质烘焙帧或采样动画的资源归入 `baked/`，其余归入 `particle/`，烘焙资源仍可同时包含 Dart 粒子模拟。开发时可用 `--dart-define=STORY_FX_ROOT=...` 替换默认资源根目录：桌面/移动端接受绝对本地目录或 `file:` URI，Web 可使用 HTTP(S) 地址，服务端需允许跨域。外部覆盖资源未纳入“完整下载”的依赖与完成状态判断；默认打包资源不占用剧情缓存，删除剧情缓存不会删除它们。资源缺失时记录警告并继续对白。

`avg_magic_fire_01` 只有粒子发射器，没有材质烘焙帧或采样动画，因此归入 `particle/`。

特效指令中的 `delay` 以秒计并按播放速度缩放；延迟期间不绘制或推进粒子，`fade` 与实际显示时刻对齐。清除尚未启动的实例会立即取消。
变量按 `story_variables.json` 解析，例如 TL-10「活着的重量」行动后使用 `$eb_smoke_01 → avg_048_smoke_01`（layer 1）及 `$eb_burn → avg_fire_01`（layer 2）。背景特效默认在背景之后、CG 之前绘制；资源声明 `drawAfterImages: true` 时改为在 CG 之后绘制，用于太阳光晕等覆盖画面的效果。前景特效默认在人物之后、遮罩之前绘制；资源声明 `drawAfterBlocker: true` 时在遮罩之后绘制，各绘制阶段按 layer 从低到高排列。同组同层的新 `bgeffect` 替换旧实例；一次性 `effect` 连续创建独立实例，保留同层刀光的叠加，淡入/淡出按实例调度；无名称且指定 layer 时清除此层，空指令清除该组全部层。`fade=true` 配合 `fadetime` 淡入/淡出，`block=true` 等待结束；`x/y` 使用舞台中心原点、y 向上，三维网格和带 `transform3D` 的粒子按 Unity Z→X→Y 顺序应用 `roz/rox/roy` 再投影；旧描述继续用余弦缩放近似投影。

粒子共用引擎时钟，暂停时冻结；重播、跳转和断点重建创建新的实例，旧淡出不会移除新实例。重建还原特效是否存在，不追赶已跳过对白的历史粒子时间。Unity 的 prewarm 仅对声明预热的循环发射器执行，最多 10 秒；长帧最多追赶 250 毫秒，粒子数量按发射器上限限制。

复合 bundle 可用 `--prefab` 选择子树，并用 `--shaders` 提供同版本 shader typetree；此路径通过临时的 `uv --with pillow` 烘焙材质图集，无需给 Flutter 增加依赖。`tool/fx/avg_fx_mesh.py` 保留三维网格、UV、顶点色和 renderer 材质动画，读取 streamed/dense/constant 轨道；支持的材质族为 `Torappu/Particles/Additive`、`AlphaBlend`、`Dissolve Add`、`Dissolve AB` 和 `Dissolve AB UVTween`，按 shader pass 混合状态、溶解方程与 UV 滚动生成 30fps 图集；既有烘焙资源保留原颜色系数；三维天气粒子在运行时乘二以对应 shader 的顶点颜色计算，混合因子若由 shader 属性引用（如 `_PremultiplyAlpha`）指定，须读取材质实际值，不能把 typetree 中的占位 `val=0` 当作最终混合方式。运行时不按特效名称分支，也不为每个粒子运行 fragment shader。

`avg_036_daoguang_01` 已重新从 `battle.ab` 中的同名预制体提取，修正此前误用其他预制体资源的问题。CF-9 行动后连续四组、每组两个同层 `Effect`，分别具有不同 `rox/roy`，不能当成同层替换。转换还保留 burst、尺寸 X/Y 独立曲线、常量粒子颜色、渲染枢轴与局部变换；预制体根位置由脚本 `x/y` 接管。

```sh
uv run --no-project --with pillow python tool/fx/avg_fx_extract.py .temp/unpacked-battle/TT_battle.ab.json assets/fx-runtime/baked --prefab AVG_036_daoguang_01 --shaders ".temp/unpacked-android-shaders/TT_[uc]shaders.ab.json"
```

动态验收以用户提供的 CF-9 录像 22:18–22:20 为参照，截取原片、提取脚本时间轴、固定随机种子，并用 Flutter 实际绘制出现、叠加、消散阶段的帧后并排播放。参考片与绘制结果保留在 `.temp/`，不能用非空图片或单张截图代替动态验收。当前主刀光的方向、刀芯和连续生成已经复现；火星分布、尺寸和亮度仍有偏差。三维发射形状、Noise、HDR 超亮叠加及未支持的 shader 仍需继续校准，不能宣称像素一致。新增效果须先确认其模块和材质是否受支持，再扩展通用转换与绘制能力。

TL-10「活着的重量」行动后的 `$e_snakeslayer → avg_079_daoguang01` 已改用 `battle.ab` 中的同名预制体。六个核心刀光保留三维网格、顶点颜色和粒子生命周期，并将原材质的扭曲、溶解、自定义数据和颜色随时间的变化烘焙为 60fps 图集；其他粒子继续由现有模拟器驱动。`$eb_072cg_solarhalo → avg_072_speech` 保留圆环和星点粒子，并将 Animator 的位置、缩放和颜色轨道采样为 30fps 动画；含 UV 滚动的溶解材质使用 15fps 图集。动画和图集使用同一个特效时钟，暂停时冻结，重建时从新实例开始。两个资源均已随应用打包。

太阳光晕的辅助 Quad 所用 `trail_34.png` 尚未能从原包导出，因此辅助光线暂缺；圆环主体的原始贴图已接入。太阳光晕粒子的面向相机缩放使用近似投影，刀光的亮度和细节与录像仍有偏差。验收时使用 TL-10 录像两段及 `.temp/` 中的连续帧和 Flutter 绘制结果，不能据此宣称逐像素一致。

转换脚本接收已解析共享材质和贴图引用的中间目录；太阳光晕动画另需原始预制体的 typetree。中间目录保留在 `.temp/fx-stage/`，不参与运行时加载：

```sh
uv run tool/fx/avg_fx_snake_bake.py .temp/fx-stage/avg_079_daoguang01 assets/fx-runtime/baked/avg_079_daoguang01
uv run --no-project python tool/fx/avg_fx_solar_animation.py .temp/unpacked-missing/avg_072_speech/TT_avg_072_speech.ab.json assets/fx-runtime/baked/avg_072_speech/fx.json
uv run tool/fx/avg_fx_solar_bake.py .temp/fx-stage/avg_072_speech assets/fx-runtime/baked/avg_072_speech
```

按当前项目要求，运行时使用的派生 `fx.json` 和主贴图纳入 `assets/` 并随应用打包；原始 AssetBundle、完整 typetree、中间解包结果和验收截图继续保留在忽略的 `.temp/`。游戏素材的版权归属不因转换或打包而改变，也不自动适用项目代码许可证。

P1 天气特效包括 `$eb_rain → avg_rain_02`、`$eb_dust_01 → avg_043_yanchen_01`、`$eb_sand02 → avg_53_fengsha_01` 和 `$e_sandfall_01 → avg_035_sandfall_01`。前三种来自独立 AB；落沙从 `battle.ab` 的 `AVG_035_sandfall_01` 预制体解析 `sharedbattle` 材质与贴图。三维粒子转换使用可选的 `emissionBasis` 保留父级四元数、XYZ 发射形状与局部速度在舞台上的投影；不能把局部 Z 速度丢弃或统一镜像 Y 轴，否则会出现雨和落沙不可见、风沙粒子停在右侧等错误。未声明该字段的既有资源沿用原模拟方式。

天气资源按 shader pass 解析透明混合；粒子颜色由运行时保留 `_TintColor × startColor × colorOverLife × 2`，溶解蒙版与主贴图的 UV 滚动分别烘焙。循环图集按统一特效时钟取模，不在最后一帧停住；风沙 mesh 保留真实三维顶点、UV 与顶点色。剧情 `flip` 的位 1、位 2 分别镜像舞台 X、Y，独立于资源内局部发射方向。

重建前先用 ArkUnpacker 导出对应 typetree、PNG 与 shader。雨、扬尘、风沙分别以 `.temp/unpacked-p1-rain`、`.temp/unpacked-p1-yanchen`、`.temp/unpacked-p1-fengsha` 为输入执行：

```sh
uv run --no-project --with pillow python tool/fx/avg_fx_extract.py <解包目录> assets/fx-runtime/particle --project-particles --shaders ".temp/unpacked-avg-shaders/TT_[uc]shaders.ab.json"
uv run --no-project --with pillow python tool/fx/avg_fx_sandfall.py
```

落沙还需 `.temp/unpacked-battle/` 与 `.temp/unpacked-fx-shared/`。四组资源均随应用打包。参考片段为 14-11 行动前 00:41–00:43、TL-9 行动后 01:03:50–01:03:55、TD-ST-2 00:24–00:27、TO-4 行动后 18:27–18:30；它们用于核对方向、覆盖和形态，不代表所有剧情的调用参数。连续帧必须使用 Flutter 实际资源、正确的 `effect`/`bgeffect` 分组及脚本参数；不能在已经含原版特效的视频截图上叠画后据此宣称一致。

按上述四段参考导出了每种效果 6 秒、15fps 的 Flutter 连续帧，并将原片与中性背景上的实际绘制并排检查。雨与两种落尘均向下进入画面，风沙粒子由右向左穿过舞台，落沙按一次性实例停止发射；随机初始颜色及透明度保留 `TwoColors` 两端值，避免生成默认不透明白色。密度和亮度会随随机种子、剧情时刻与背景改变；Unity Noise 和 HDR/Bloom 仍为近似，细颗粒与原片尚有差异，不能据此宣称逐像素一致。


## P2 第一人称叙事镜头与视效

P2 七项按 `story_variables.json` 映射并打包：`$eb_signalInterference → avg_signalinterference_01`、`$eb_tvnoise → avg_056_tvnoise_01`、`$eb_dim_openeye → avg_mohu_zhengyan_01`、`$eb_dim_closeeye → avg_mohu_biyan_01`、`$eb_speedline → avg_suduxian`、`$eb_whitemask → avg_062_white_01`、`$eb_blackmask → avg_062_black_01`。五项粒子资源由 `.temp/unpacked-p2/<资源名>/` 解包结果通过 `tool/fx/avg_fx_extract.py` 转换；主贴图随 `fx.json` 存入 `assets/fx-runtime/particle/<资源名>/` 并在 `pubspec.yaml` 注册。转换会省略带不支持材质或缺 MainTex 的发射器：信号干扰的刀光蒙版粒子、白/黑遮罩中依赖未支持材质的原版子节点不直接绘制。

白/黑遮罩保留已解包的颗粒与划痕，用手工维护的 `screenEffect: {type: "overlay", edge: [r, g, b, a]}` 补上屏幕边缘的亮幕与暗角。`edge` 不改变画面中心；可选的 `tint` 为独立的中央色调，两者用 0–1 的 RGBA。遮罩在场景合成后、幕布和 `Blocker` 之前按 layer 绘制，跟随特效延迟、淡入淡出和清除，不随脚本坐标或镜头抖动移动。重导粒子时须保留这两个资源的 `screenEffect` 字段。

白遮罩参考片段 `activities/act43side/level_act43side_08_end` 的白边与剧本独立指定的灰度叠加；`activities/act48side/level_act48side_06_end` 同时使用黑遮罩和 `$eb_oldtv`。后者映射到另行打包的 `avg_old_tv_01`，用中央暖色渐变近似截图色调，只在脚本启用该特效时显示。边缘与暖色均为渐变近似，未还原原版材质的溶解动画。

`$eb_speedline → avg_suduxian` 由 `.temp/unpacked-p2/avg_suduxian/` 配合解包的公共着色器包重导，以保留 `Torappu/Particles/Additive` 叠加混合、`emissionBasis` 三维投影、速度上限阻尼与贴图 U 轴拉伸：

```bash
uv run --no-project --with pillow python tool/fx/avg_fx_extract.py .temp/unpacked-p2/avg_suduxian assets/fx-runtime/particle --project-particles --shaders ".temp/unpacked-avg-shaders/TT_[uc]shaders.ab.json"
```

运行时同步补齐了四项通用能力并核对参考片段（墟 · AT-3 夜逃通告（行动后）片头，`[bgeffect(name="$eb_speedline", layer=1)]` 搭配 `[focusout(duration=1, type="bg", from=0, to=0.8)]`）：
- 三维圆锥（`shape.type == 4` 且存在 `emissionBasis`）按圆锥侧面几何在 360° 径向扩散，`angle=90°` 时在 XY 平面沿半径 330px 外环向外发射；无 `emissionBasis` 的历史资源保留原有二维扇形行为。
- 支持 `ClampVelocityModule` 导出的 `limitVelocity`（含 `magnitude` 曲线与 `dampen` 阻尼），使外层长线（`lizisha_dm`）在离屏前衰减停留在画面四周。
- 支持 Unity `Stretched Billboard` 贴图 U 轴对齐（`stretchAlignU: true`），正 `lengthScale` 向速度反方向拖尾、负 `lengthScale` 向速度正方向延伸并遵守 `pivot.y` 偏移；粒子绘制改用 `FilterQuality.medium`（Mipmap 采样）避免高缩放比细条纹理出现点状锯齿。
- `StagePainter` 在 `bg` 与 `lbg` 同失焦级别（或无大场景）时，将背景与 `bgeffect` 合并在同一 `_withFocus(canvas, 'bg', ...)` 离屏层绘制，既保留 `BlendMode.plus` 叠加混合又同步承受 `focusout` 模糊，并将 `focusout` 模糊系数校准为 `amount * 3.5`（`0.8` 时约 `2.8px`），与参考录屏中的背景和速度线宽（约 7–8px 柔边）一致。随机种子、压缩画面与 HDR/Bloom 仍有近似差异，其余未提供参考视频的 P2 项仍只验证了离线加载与管线运行。

睁眼/闭眼资源没有可直接绘制的粒子，而是相机后处理。运行时以共享 `FxSimulation` 时钟，在 1.5 秒内对舞台内容施加高斯模糊与径向暗角：睁眼逐渐清晰，闭眼逐渐模糊并压暗边缘；暂停与 seek 遵循现有特效时钟。该近似不会重建 Unity 的 HGMobileBlur、景深或原始遮罩材质，若原版使用非线性动画曲线，变化节奏也会不同。

