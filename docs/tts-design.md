# 对白语音（本地 TTS）技术方案

> 本分支已实现可用首版：直接接入 sherpa-onnx，覆盖默认包下载/续传/校验、本地合成、切句打断、自动播放等待句尾、设置与右侧控制中心、角色映射及试听。下文阶段表保留规划背景；长句切段、下一句预合成和角色独立模型包仍待实现。模型包改为从国内镜像 hf-mirror 逐文件下载（共 176,285,027 字节，约 176 MB），失败自动回退 HuggingFace 官方源，语音默认关闭。模型与角色映射存放于应用支持目录的 `voice_packs`，不随剧情缓存目录迁移或清理；删除模型保留角色映射。

实现验证与平台边界见 [TTS 首版验证记录](tts-validation.md)。
> **2026-11-10 归档**：本分支已归档为 `archive/tts-local-playback`；端侧 TTS 保留为离线兜底。云端角色音色克隆的调研、成本与重估条件见 [TTS 方案调研](tts-cloud-voice.md)。

| 项 | 内容 |
|---|---|
| 状态 | 已实现首版，分支已归档 |
| 日期 | 2026-11-09 |
| 范围 | Android / Windows / Linux（与现有发布矩阵一致：Android arm64/arm32/x64、Windows x64、Linux x64/arm64） |
| 关联结论 | 实时合成路线（sherpa-onnx）；对白/旁白/结尾语配音，不覆盖字幕与贴纸；角色音色映射；先 1 个多说话人默认语音包，后续按角色独立语音包按需下载 |

---

## 1. 背景与目标

方舟档案室是离线剧情播放应用，剧本、图片、音频素材均已按需异步加载。本方案为其增加「对白语音」能力：在剧情播放时用本地 TTS 引擎把可见对白合成为语音播放，全程离线、不依赖云端。

### 1.1 目标

1. 对白、旁白（aside）、结尾语（endtip）随播放发声，多行对白（multiline）整句合成；
2. 角色音色映射：同一角色跨剧情音色一致；
3. 默认提供 1 个多说话人语音模型；分发优先按需下载（与项目「大资源按需加载」的现状一致），随包打包作为备选；
4. 后续支持按角色扩展独立语音包，按需下载安装；
5. 语音开关、音量、角色音色可在设置中调整；未安装语音包或合成失败时静音降级，不影响正常播放。

### 1.2 非目标

- 不覆盖字幕（subtitle）与自由贴纸（sticker）——它们是演出元素而非对白；
- 不使用云端 TTS（费用、隐私、离线相悖）；
- 不引入游戏原声语音（版权归鹰角；TTS 为全新生成内容，不涉游戏资源）；
- 不做语音克隆训练；
- iOS / Web 本期不做（sherpa-onnx 具备能力，留作后续）。

### 1.3 版权与合规

- sherpa-onnx：Apache-2.0；
- 默认模型 Kokoro-82M-v1.1-zh：Apache-2.0（落地时以 HuggingFace 模型页为准，`落地核验`）；
- 合成语音为运行时生成内容，随应用分发的是模型文件而非游戏音频素材；
- 落地时在 README「鸣谢与声明」补充 sherpa-onnx 与所用模型的许可信息（遵循 AGENTS.md 的 README 同步原则，功能上线时更新）。

---

## 2. 技术选型

### 2.1 候选方案对比

| 方案 | 说明 | 优点 | 缺点 | 结论 |
|---|---|---|---|---|
| flutter_tts（系统 TTS） | 封装系统引擎（Android TTS / Windows SAPI / Linux speech-dispatcher） | 接入成本最低 | 音色不可控、各端不统一、Linux 依赖用户环境、无法角色差异化 | 仅作 MVP 链路验证 |
| **sherpa-onnx 实时合成** | ONNX Runtime 设备端推理，pub.dev 官方包 `sherpa_onnx`（当前 2.0.1，支持 Android/Windows/Linux/macOS/iOS/web） | 跨端同一份模型、音色统一、多说话人/多音色可选、完全离线 | 模型体积大（数十至数百 MB）、低端机推理耗时需评估 | **主方案** |
| 预合成语音缓存 | 离线管线预先合成整篇对白 wav 供播放 | 运行时零推理、播放稳定 | 需维护生成管线、文本变化需重生成、总量随剧情线性膨胀 | 暂不采用（剧本按需加载的模式下不匹配），留作远期可选优化 |

### 2.2 默认模型选型（多说话人中文）

官方 [tts-models](https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models) 中支持中文的候选：

| 模型 | 语言 | 说话人数 | 说明 |
|---|---|---|---|
| vits-piper-zh_CN-chaowen / xiao_ya-medium | 中 | 1 | 单说话人，无法做角色映射 |
| matcha-icefall-zh-baker | 中 | 1 | 单说话人 |
| matcha-icefall-zh-en | 中+英 | 1 | 单说话人 |
| **kokoro-multi-lang-v1.1** | 中+英 | **103** | sid 0–2 英音/美音女声，sid 3–57 中文女声 55 个（zf_*），sid 58–102 中文男声 45 个（zm_*），24 kHz，自带中英混读词典 |

**选定 `kokoro-multi-lang-v1.1`** 为默认语音包模型：一个模型内 100 个中文音色（55 女 + 45 男），足以支撑数十个常驻角色的差异化映射；中英混读符合剧情中夹杂英文专有名词的情况；每句合成通过 `sid` + `speed` 指定音色与语速。

体积与推理：官方提供 fp32 与 int8 量化两种打包（int8 体积约为 fp32 的 1/4、推理更快、音质略降）。默认分发 int8 版，体积与实测 RTF 以 Release 实际文件为准（`落地核验`）。

> sherpa-onnx Dart API 关键形态（来自官方示例）：
> `OfflineTts(OfflineTtsConfig(model: OfflineTtsModelConfig(kokoro: OfflineTtsKokoroModelConfig(...), numThreads: n)))` →
> `tts.generateWithConfig(text:..., config: OfflineTtsGenerationConfig(sid:, speed:, silenceScale:))` →
> `audio.samples`（Float32List PCM）+ `audio.sampleRate`。

---

## 3. 总体架构

### 3.1 分层与数据流

```
剧情脚本
   │
   ▼
StoryEngine（现有，仅增加接线点）
   │  触发: _showDialogue（dialogue/dialog/aside/endtip）
   │        multiline end 整句汇总
   │  打断: advance / seekToCommand / restart / skipNode / choose / 快进
   │  门控: !_rebuilding（重放期间不发声）
   ▼
DialogueVoice（新抽象）          SilentDialogueVoice（默认实现=静音，回滚点）
   │
   ├── sherpa_voice: OfflineTts 合成 PCM → 内存 WAV
   │
   ▼
独立 just_audio AudioPlayer（BytesSource 播放，voiceVolume × master 混音）

VoicePack / VoiceProfile（数据层）
   ├── 语音包 manifest（内置默认包 + 后续远端包）
   ├── 文件下载与 sha256 校验（复用 file_cache / cache_control 下载管线）
   └── 角色 → (packId, sid, speed) 映射表
```

### 3.2 DialogueVoice 接口

```dart
abstract class DialogueVoice {
  /// requestId 由引擎每次推进递增；speak 内先停旧句，过时请求直接丢弃。
  Future<void> speak({
    required String speaker,   // 已 translate 的说话人显示名，旁白为空串
    required String text,      // plainText 后的合成文本
    int? requestId,
  });
  Future<void> stop();    // 打断当前语音
  Future<void> pause();   // 与播放器暂停同步
  Future<void> resume();
  Future<void> dispose();
}
```

设计要点：

- **与现有 `StoryAudio` 彻底分离**：BGM/音效由脚本命令驱动、按 channel 管理；对白语音是「跟随可见文本、随处可打断」的独立声部，不并入 channel 机制，避免互相污染 stale/epoch 语义；
- 语音走独立 `AudioPlayer`，经 `BytesSource` 播内存 WAV，混音只依赖 just_audio，各端行为一致；
- 默认实现 `SilentDialogueVoice` 全空操作——引擎接线后默认关闭语音（静音），**阶段 0 合入即零行为变化**，任一环节失败（模型未安装、初始化异常、合成超时）都退回静音，不阻塞剧情播放。

---

## 4. 语音包设计

### 4.1 VoicePack 抽象与 manifest

从第一天起按「包」建模（即使初版只有 1 个），后续按角色加包不改抽象：

```json
{
  "id": "kokoro-zh-v1_1",
  "name": "kokoro 中文语音包（int8）",
  "version": 1,
  "engine": "kokoro",
  "sampleRate": 24000,
  "defaultSid": 3,
  "files": [
    { "path": "model.onnx",        "url": "...", "sha256": "...", "bytes": 0 },
    { "path": "voices.bin",        "url": "...", "sha256": "...", "bytes": 0 },
    { "path": "tokens.txt",        "url": "...", "sha256": "...", "bytes": 0 },
    { "path": "espeak-ng-data/*",  "url": "...", "sha256": "...", "bytes": 0 },
    { "path": "lexicon-zh.txt",    "url": "...", "sha256": "...", "bytes": 0 },
    { "path": "lexicon-us-en.txt", "url": "...", "sha256": "...", "bytes": 0 }
  ],
  "voices": [
    { "sid": 3,  "name": "zf_001", "gender": "f" },
    { "sid": 58, "name": "zm_009", "gender": "m" }
  ],
  "license": { "model": "Apache-2.0", "source": "hexgrad/Kokoro-82M-v1.1-zh" }
}
```

- `engine` 决定构造哪种 `OfflineTts*ModelConfig`（kokoro/vits/matcha…），为后续接入其他模型家族预留；
- manifest 内置于应用（初版直接随代码发布），后续角色包的 manifest 从远端目录拉取，同一 schema；
- 包安装目录：应用支持目录（`path_provider`）下 `voice_packs/<id>/`，以 manifest `version` + 文件 sha256 判断升级与完整性，未通过校验的包不加载。

### 4.2 分发策略：按需下载为主，随包备选

| 维度 | 甲：按需下载（推荐） | 乙：随包打包 |
|---|---|---|
| 安装包体积 | 不变（新增的仅是 sherpa-onnx 原生库约十余 MB） | 增加约 80–300 MB（`落地核验`） |
| 与项目现状 | 一致：剧本/图片/音频全部按需异步加载，语音模型同理 | 违背既有「轻包体 + 按需取资源」模式 |
| 首启体验 | 首次开启语音需等待下载，需设置页引导 | 开箱即用 |
| 实现成本 | 复用现有下载管线（暂停/恢复/失败原因/并发控制/移动网络提醒均有现成语义） | assets 无法直接给 native 层文件路径，需「打包 + 首启复制到应用目录」流程 |

**结论：默认语音包走按需下载**，设置页首次开启语音时引导下载（含移动网络提醒，与剧情缓存同策略）。**下载源：国内镜像 hf-mirror（`csukuangfj/kokoro-int8-multi-lang-v1_1` 仓库逐文件拉取）优先，HuggingFace 官方源兑底**；单一源失败（网络错误、HTTP 异常、哈希不符）自动切下一源，逐文件 sha256 校验（哈希来源为 HF LFS oid 与镜像实测），失败可重试、可跳过（跳过即无语音）。原 GitHub Release tar.bz2 整包链路已移除（国内可达性差，且散文件可细粒度续传），`archive` 解压依赖随之清理。
若按需通道在初版受阻（如校验链路未就绪），降级为乙：随包 + 首启复制，二者对上层完全透明（`VoicePackStore` 统一暴露本地已就绪的包目录）。

### 4.3 下载与校验

1. 首版复用 `cache_control` 的暂停与取消机制：单包为任务粒度，支持续传、失败原因展示及移动流量确认。模型独立存放于应用支持目录；后续再考虑接入统一缓存任务列表及桌面端自定义目录；
2. 每个文件下载后 sha256 校验（项目已有 `crypto` 依赖），全包通过后原子切换为「已安装」；
3. 语音包不挂在具体剧情缓存之下，全局独立管理（按包展示占用空间、删除），删除语音包不清除观看断点（与剧情缓存行为一致）。

### 4.4 后续按角色语音包扩展路径

- 阶段 5 引入「角色语音包」：面向特定角色（或角色组）的独立模型包，同一 manifest schema，`engine` 可为 kokoro/vits/matcha 等任意支持的家族；
- 扩展包的定位是「更高辨识度/更贴合人设的音色」，覆盖默认包中映射不佳的角色；默认包永远兜底，卸载扩展包自动回落默认映射；
- 远端 manifest 目录（同样可托管在本仓库 Release 资产上）列出所有可下载包，设置页按角色 / 按包两个视角管理。

---

## 5. 引擎接入设计（story_engine 接线）

### 5.1 触发点与文本规范化

| 脚本元素 | 触发位置（现有代码） | 语义 |
|---|---|---|
| `dialogue` / `dialog` | `_executeCommand` 对白分支 → `_showDialogue` 后 | `speaker = state.speaker`（translate 后），文本 = `plainText(state.text)` |
| `aside` | 同上（speaker 为空串） | 使用「旁白」音色 |
| `endtip` | 同上（仅非 default 模式会走到 `_showDialogue`，见 5.3） | 结尾语整句 |
| `multiline` | `_runMultiline` 中 `end` 汇总进 history 处 | **整句合成**（累积文本一次发声；中途续接不发声，被新对白打断时不补发旧句） |
| `subtitle` / `sticker` | 无 | 不触发（明确不配音） |

文本规范化：合成文本 = `plainText()` 去富文本标签后的可见文本（`translate` 已完成变量替换）；超长句（如 multiline 累计上百字）按标点切段顺序合成可作阶段 4 优化，初版整体合成。

同句去重：以「停顿点 commandIndex + 文本 hash」标识一句；`advance()` 在打字未完时先补全文本（同句），不重复发声；进入下一句才 `stop()` + `speak()`。

### 5.2 打断与重放语义

| 引擎路径 | 行为 |
|---|---|
| `advance()` 下一句 | `stop()` 后播新句 |
| `advance()` 同句补全（typing / overlay 打字） | 不打断、不重发 |
| `setPaused(true/false)` | `pause()` / `resume()`，与 BGM 同步 |
| `seekToCommand` / `restore`（`_rebuilding == true`） | **重放门控：全程不触发语音**；重放结束落在目标对白时正常发声。`_showDialogue` 在重放中会被反复调用，接线必须以此为前提 |
| `restart` / `skipNode` / `choose` | `stop()` 清空；跳节点后新句正常触达 |
| `setFastForward(≥2)`（长按快进） | 触发即 `stop()`，快进期间不发声，松手后当前句重新评估是否发声 |
| 播放完成 / dispose | `stop()` / `dispose()` |

### 5.3 播放模式策略

| 模式 | 策略 |
|---|---|
| default（手动） | 对白呈现即发声；用户自行控制节奏 |
| button_auto（自动） | 发声；阶段 2 起先「切句即停」不等待语音，阶段 4 把语音剩余时长并入 `autoWait` 计算，避免切句过快听不全 |
| quick_play（快速） | **静音**（与毫秒级推进节奏不匹配）；UI 上维持语音开关即可 |
| 长按快进 | 静音（见 5.2） |

### 5.4 音量与混音

- `PlaybackSettings` 增加 `voice` 字段（0~1，默认 0.9，**0 即关闭**，沿用现有 `Map<String, double>` 序列化与 clamp 模式，不必扩展存储结构）；实际音量 = `voice × master`；
- 语音通道音量固定由 just_audio `AudioPlayer.setVolume` 控制，不参与 `JustAudioOutput` 的 fade 通道逻辑。

### 5.5 合成执行模型

- **懒加载**：进入播放器且 `voice > 0` 且默认包已安装时才初始化 `OfflineTts`；离开播放器 `dispose` 释放；
- **异步不阻塞**：`speak()` 合成在后台完成，视觉推进不等合成（对白先出字，语音随到随播）；合成迟到但该句已被跳过（requestId 过时）则丢弃——与 `JustAudioOutput._requests` 的 stale 模式一致；
- 播放：PCM Float32 → 16-bit WAV 内存封装 → `BytesSource` → `AudioPlayer.play()`，播放完成自动释放；
- `numThreads` 初始 2（桌面可提高），合成耗时与整机 RTF 在阶段 2 实测后定档（`落地核验`）；低端机实测不达标时降级策略：继续用（错句即弃）或自动静音，由阶段 2 验收数据决定；
- **预取优化（阶段 4）**：剧本文本静态且引擎已有 `stopPoints` 索引，可在当前句播放期间推测并预合成下一句，掩盖首句合成延迟。

---

## 6. 角色音色映射

```dart
class VoiceBinding {
  final String role;      // 说话人显示名，如 「阿米娅」；空串表示旁白
  final String packId;    // 缺省默认包
  final int sid;          // 音色
  final double speed;     // 缺省 1.0
}
```

解析顺序（`VoiceProfile.resolve(speaker)`）：

1. 用户自定义覆盖（阶段 3+，设置页提供，仅本机生效）；
2. 内置映射表（静态数据文件，随版本更新扩充；初期手工指定高频角色）；
3. 兜底策略：
   - 旁白（空 speaker）→ 固定沉稳旁白音色（从包内选定，如 zm 系）；
   - 未映射角色 → 以角色名为键做**稳定散列**分配到音色池（默认池取音色分布均衡的子集），保证同一角色在任何剧情里音色一致、跨设备一致。

音色池与内置映射初版从 kokoro 的 55 女 + 45 男中按官方示例音频试听挑选取舍（阶段 3，`落地核验`）。角色性别信息应用内不掌握，散列池不做性别约束；对听感明显不符的角色，通过内置映射表修正，并随用户反馈迭代。

### 6.1 后续规划：人物档案馆与语音关联

人物档案馆用于统一管理所有剧情涉及的人物资料，并与角色语音关联一同开发。本节为后续规划，尚未实现；当前首版继续使用少量内置映射、按显示名稳定散列及本机用户覆盖，不要求补齐全部人物硬编码表。

- **人物来源**：从剧情对白和 multiline 指令提取说话人，记录出场剧情与原始显示名。区分“已收录人物”和“已遇人物”；除非已完成全量剧情索引，不将已收集列表宣称为全量人物。
- **稳定身份**：人物资料使用稳定的 `characterId`，显示名、别名和剧情中的称呼作为关联信息。音色绑定以人物身份为主键，避免改名或切换章节后丢失设置。优先复用可靠的角色资料来源；数据来源、字段和更新方式在该功能开发时确定，不仅凭名字相似度自动合并。
- **档案内容**：先记录姓名、别名、资料来源和出场剧情；性别等辅助资料只在来源明确时收录。未知身份允许保留未归并记录，用户可确认关联；合并需能撤销，并明确处理已有音色设置冲突。
- **剧情隐私**：别名可能暴露身份，默认按已阅读进度展示；不要在播放器中提前揭示未知说话人的真实身份。
- **通用称呼**：“？？？”、“士兵”、“市民”等不直接视作跨剧情同一人物。缺少可靠身份时，按剧情范围记录并使用通用音色；存在可靠标识后再关联人物档案。

语音与档案同步接入时，按“用户为人物指定的音色 → 人物默认音色 → 基于可靠资料的音色池分配 → 通用兜底”解析。未知人物不根据姓名推断性别；仍允许用户试听、调整和恢复默认。旁白独立绑定，同一人物可在多个剧情沿用设置；通用称呼的局部设置不影响其他剧情。

界面提供两个入口：播放器默认显示可搜索的“本篇人物”；人物档案馆集中管理“已遇人物”和其他已收录资料，并提供关联音色与试听。人物数量增大后使用搜索和分段加载，避免用一个下拉框列出所有人物。

迁移时保留现有按显示名保存的用户音色覆盖：只有唯一且可靠地匹配人物身份时才转为 `characterId` 绑定，歧义项保留原设置并等待确认。删除语音模型不删除人物档案及音色绑定。

验收需覆盖：新剧情人物自动收录；同一人物跨剧情和别名共享音色；同名路人互不影响；身份未知时可正常朗读；旧覆盖迁移不丢失；未读剧情身份不被提前揭示。人物资料源和完整索引方案确定后，再细化存储结构与实施任务。


---

## 7. 设置与 UI（阶段 3 落地）

- 播放器侧：语音作为音量体系一员（主音量/BGM/音效/语音），无需新增开关位；`voice=0` 即关；
- 设置页：语音区块 = 语音包状态（未安装 → 引导下载；已安装 → 显示版本/体积/删除）+ 语音音量滑杆 + 角色音色入口；
- 角色音色页：列出内置映射角色 + 当前散列命中的音色 → 可改选包内任意音色 + 试听（播放 1 句样例文本）；
- UI 风格沿用设置页现有控件，不引入新组件体系。

---

## 8. 实施计划（每阶段可独立验收、可回滚）

| 阶段 | 内容 | 主要改动 | 验收标准 |
|---|---|---|---|
| 0 接口与静默接线 | `DialogueVoice` 接口 + `SilentDialogueVoice` 引擎注入接线；触发/打断/重放门控（5.1–5.2）；`PlaybackSettings.voice` 字段 | `story_engine.dart`、`playback_settings.dart`、新增 `dialogue_voice.dart` | 默认关闭下全量功能与现状零差异；受影响测试通过 |
| 1 MVP 链路 | 用 flutter_tts 实现 `TtsMvpVoice` 打通「对白→发声→前进打断→暂停/跳转不串音」（平台差异此时无所谓） | 新增 mvp 实现 + 接线 | Windows + Android 手动与自动化验证：六类打断路径（5.2 表）行为正确 |
| 2 正式引擎与默认语音包 | `sherpa_onnx` 接入、`SherpaVoice`（合成→WAV→BytesSource）、kokoro int8 语音包按需下载与校验、下载引导 UI、降级静音 | 新增 `sherpa_voice.dart`、`voice_pack.dart`（store + manifest + 下载）、pubspec 增加 `sherpa_onnx` | 断网安装期：正常播放仅无语音；装包后离线出声；三平台安装、播放、打断、删除全通过；实测移动端首句延迟 |
| 3 角色映射与设置 | 内置映射表、稳定散列兜底、角色音色页与试听、语音包管理页 | 新增 `voice_profile.dart` + 设置页区块 | 同一角色音色跨剧情/跨设备一致；改音色即时生效 |
| 4 节奏与体验 | button_auto 等待语音句尾、长句切段、`stopPoints` 预取下一句、快进/quick 策略复查 | 引擎 speak 调度 + `JustAudioOutput` 无涉 | 自动播放不出现「语音刚起就被切」；快进中零残留发声 |
| 5 角色语音包扩展 | 远端 manifest、多包共存与按角色覆盖、包升级 | `voice_pack.dart` 扩展 + 设置页 | 扩展包安装/卸载回落正确；远端列表拉取与校验通过 |
| 后续：人物档案馆与语音关联 | 统一人物资料、剧情说话人收录、别名归并、通用称呼隔离与身份音色绑定，同步开发 | 人物档案数据与界面、剧情索引、`voice_profile.dart` 迁移 | 按 6.1 验收：跨剧情绑定一致、同名路人隔离、旧设置保留、避免身份剧透 |

依赖关系：0 → 1 → 2 → 3 → 4，5 依赖 3；每阶段独立分支提交（遵循 AGENTS.md），阶段 0 即「接线不发声」，从架构上保证不破坏现有播放体验。

## 9. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| 模型体积（int8 约 80–100 MB 级，`落地核验`） | 下载门槛 | 按需下载 + 移动网络提醒 + 断点续传（复用现有管线）；安装包不增重 |
| sherpa-onnx 原生库使 universal APK / 桌面包体积上升 | 发布体积 | Android 已按 ABI 分包；桌面端绝对量小可接受 |
| 低端机合成延迟 / 发热 | 体验 | int8 + numThreads 调档 + 预取 + 过时丢弃；实测不达标自动静音降级 |
| kokoro 音色辨识度对二次元角色人设的一般性 | 听感 | 接受「可用级」定位；阶段 5 用角色包逐步补强关键角色 |
| 各端 PCM→播放链路差异（采样率、通道） | 播放异常 | 统一 24 kHz 单声道 WAV；just_audio 三端一致路径 |
| 与打字机节奏不同步 | 观感 | MVP 不强求同步（念整句 vs 打字机逐字）；阶段 4 评估按语速对齐 reveal 的可行性 |
| 重放/跳转路径遗漏触发点 | 串音 | 阶段 1 以 5.2 表为用例清单逐项验收；`_rebuilding` 门控单元测试 |

## 10. 测试与验证

- 单元测试：触发点矩阵（5.1 表 × 5.2 打断表）、multiline 整句与打断不补发、`_rebuilding` 门控、同句去重、`VoiceProfile.resolve` 稳定散列一致性、manifest 校验与损坏回滚、`PlaybackSettings.voice` 序列化；
- 平台验证：本地跑 Windows + Android（模拟器/真机）；Linux（x64/arm64）以 CI 构建产物验证——项目现有 GitHub Actions 矩阵已覆盖三平台，阶段 2 起 Release 产物即含语音能力的构建（遵循 AGENTS.md「按当前环境可用平台验证、明确记录未验证平台」）；
- 性能采样：三端各取长/短/中英混排三类文本，记录合成耗时与 RTF，作为阶段 2 验收附件。

## 11. 开放问题

1. 默认包内音色池与内置映射表的初版选择（需试听，阶段 3 输入）；
2. 桌面端是否额外提供「随包离线版」构建（当前结论：不做，按需即可，待用户确认后关闭）;
3. 语速 `speed` 是否按对白情绪/长度参数化（先固定 1.0，阶段 4 观察）；
4. 收尾语（endtip）在 button_auto 下与 `autoWait` 的合并策略细节（阶段 4 设计输入）。

---

## 附录 A：kokoro-multi-lang-v1.1 音色摘要

- 下载：`https://hf-mirror.com/csukuangfj/kokoro-int8-multi-lang-v1_1/resolve/main/<file>`（全部共 176,285,027 字节；哈希清单见 `lib/story_player/data/voice_pack.dart`）
- 采样率 24000 Hz；103 说话人：
  - sid 0–2：英语（af_maple / af_sol / bf_vale）
  - sid 3–57：中文女声 55 个（zf_001 … zf_099）
  - sid 58–102：中文男声 45 个（zm_009 … zm_100）
- 文件组成：model.onnx、voices.bin、tokens.txt、espeak-ng-data/、lexicon-zh.txt、lexicon-us-en.txt
- 每句合成：`OfflineTtsGenerationConfig(sid: 选定音色, speed: 语速)`

## 附录 B：参考

- sherpa-onnx 仓库与文档：https://github.com/k2-fsa/sherpa-onnx ｜ https://k2-fsa.github.io/sherpa/onnx/tts/index.html
- Flutter 包：https://pub.dev/packages/sherpa_onnx（2.0.1，含 TTS Dart API 与跨平台预构建示例 App）
- TTS 模型总览：https://k2-fsa.github.io/sherpa/onnx/tts/all ｜ 全部可下载模型：https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models
- Kokoro 原模型：https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh

> AI生成
