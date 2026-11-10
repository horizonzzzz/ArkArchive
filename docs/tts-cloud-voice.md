# TTS 方案调研：端侧合成与云端角色音色克隆

> 状态：调研归档，暂不实施。端侧方案已落地在 `feat/tts`（归档为 `archive/tts-local-playback`）；云端克隆方案等用户量达到重估条件后再启动。
>
> 日期：2026-11-10
>
> 关联：[对白语音（本地 TTS）技术方案](tts-design.md)、[TTS 首版验证记录](tts-validation.md)

## 0. 结论

1. 手机端离线 TTS 已经能做到“不机械”，可行路线是 `sherpa-onnx` + 轻量神经模型；中文首选 `matcha-icefall-zh-baker`（快）和 `kokoro-multi-lang-v1.1`（自然）。
2. 端侧方案的天花板是“通用音色”，无法做到每个角色贴近游戏配音；要做到角色化，只能上云端大模型 + 音色克隆。
3. 云端克隆的最优解是自建：本机 4080 + GPT-SoVITS 批量生成，音频放对象存储 + CDN。全剧情 600 小时音频约 13GB，存储月费 1–2 元，成本瓶颈是 CDN 流量而不是算力。
4. 现在不实施的原因不是技术，而是投入产出：角色音色资产整理、版权合规、生成管线维护都是持续成本，用户量不足时没有收益。重估条件见第 5 节。

---

## 1. 两条路线的定位

| 路线 | 合成位置 | 音色 | 边际成本 | 适用阶段 |
|---|---|---|---|---|
| 端侧 TTS | 手机本地 | 通用多说话人音色 | 0 | 功能验证、离线兜底、用户量小 |
| 云端克隆 + 预生成 | 本机/服务器离线批量 | 每角色贴近原配音 | 存储 + 流量 + 维护 | 用户量稳定、内容消费量大 |

两者不冲突：端侧 TTS 作为“模型未下载/网络异常/新剧情未生成”时的兜底，云端音频作为默认播放源。

---

## 2. 端侧 TTS 调研

### 2.1 方案对比

速度数据来自 sherpa-onnx 官方在树莓派 4 单线程上的 RTF（生成 1 秒音频所需秒数）。手机 CPU 通常快 2–4 倍，只能作量级参考。

| 方案 | 体积 | 中文 | RTF（Pi4 单线程） | 主观质量 | 许可/备注 |
|---|---|---|---|---|---|
| iOS 系统 TTS（AVSpeechSynthesizer + 增强音色） | 0 | 有 | 真流式 | 中等 | 免费；音色和发音不可控 |
| Android Google TTS | 0 | 有 | 真流式 | 偏低，偏机械 | 跨设备差异大 |
| Piper `zh_CN-huayan-medium` | ~60MB | 有 | <0.5 | 能听懂，偏平 | MIT；各 voice 许可不同 |
| Matcha `zh-baker` | 72M + 51M 声码器 | 单女声 | 0.892 | 清晰稳定，语气偏平 | 训练数据限非商用 |
| Kokoro `v1.1-zh` | 310MB fp32 + 26MB voices | 100 中文音色，中英混读 | 7.635 | 端侧第一梯队 | Apache 2.0 |
| MeloTTS `zh_en` | 163MB | 中英 | 6.727 | 好于 Piper，弱于 Kokoro | MIT（代码），权重需确认 |
| VITS 中文多说话人 | 116–117MB | 187/804 音色 | 4.3–6.0 | 可用，音色参差 | 各模型不同 |
| aishell3 | 30MB | 174 音色 | 0.365 | 较旧 | 需确认许可 |
| ZipVoice-Distill `zh-en` | 123M | 中英，零样本克隆 | 官方未给移动端数据 | 克隆自然，偶有误读 | 需参考音频 + 精确转写 |
| PocketTTS-ZH-6L | 223MB int8 | 中文克隆 | 桌面 i7 约 6.5 倍实时 | 长句 CER 8.1% | 社区模型，许可不明确 |
| NeuTTS Air | ~360M 激活 | 仅英/西/德/法 | Galaxy A25 约 20 tok/s | 英文克隆不错 | Apache 2.0 |
| CosyVoice2-0.5B | 0.5B | 强（CER 1.45%） | 手机不可行 | 接近真人 | 仅服务端/PC |
| VoxCPM-0.5B | 0.5B | 强 | M4 Pro 端侧 RTF 1.76 | 接近真人 | 手机不可行 |

补充：Supertonic（66M/99M）体积很小，但**不支持中文**，仓库已于 2026-07 归档，不纳入选型。

### 2.2 sherpa-onnx 生态

- 官方 Dart/Flutter 绑定，支持 Android、iOS、Windows、macOS、Linux、Web；Android 有预编译产物，**iOS 的 TTS 示例需要从源码构建**。
- 已接入的模型家族：VITS、Piper、Matcha、Kokoro、MeloTTS、ZipVoice、PocketTTS、KittenTTS、SupertonicTTS。
- 移动端默认走 CPU（ONNX Runtime），不走 NPU；RTF 主要由单核性能、线程数和模型量化决定。
- 当前分支使用 `kokoro-int8-multi-lang-v1_1`，约 176MB，按需下载 + 断点续传 + 校验。

### 2.3 端侧方案的局限

1. **音色是通用音色**，无法贴近角色原配音；Kokoro 的 100 个中文音色只能做到“区分”，做不到“还原”。
2. **机型差异大**：Kokoro 在低端机上首句延迟和发热明显，Matcha 音质又偏平。
3. **包体与维护**：模型 80–300MB，需要下载管线、版本管理、失败回滚。
4. **文本坑多**：方舟文本里的英文代号、数字、省略号、多音字、生僻字，端侧模型的误读率高于大模型。

因此端侧方案保留为兜底与离线能力，不作为角色化配音的最终形态。

---

## 3. 云端角色音色克隆方案

### 3.1 目标

- 有官方配音的角色：用 5–60 秒参考音克隆，贴近原音色。
- 无配音角色：按性别/年龄映射到 4 个默认音色（年轻男/女、成熟男/女）。
- 旁白：单独中性音色，语速略慢。
- 播放完全离线：音频预生成后放对象存储 + CDN，客户端只做流式播放与缓存。

### 3.2 模型选型

| 模型 | 用途 | 关键数据 | 许可 |
|---|---|---|---|
| **GPT-SoVITS v2ProPlus** | 主力，角色音色克隆 | 4090 RTF 0.014，4060Ti 0.028；5 秒零样本，1 分钟小样本微调；中英日韩粤 | MIT |
| IndexTTS2.5 | 关键情绪场景精修 | 0.8B，中文 WER 4.36 / SS 77.10，4090 RTF 0.2065 | bilibili 模型许可，商用需联系 |
| CosyVoice2-0.5B | 备选/对照 | 中文 CER 1.45%，无官方移动端方案 | 需确认 |

选择 GPT-SoVITS 的理由：速度快（4080 约 30–50 倍实时）、中文二次元音色相似度高、MIT 许可、社区工具链成熟（参考音分离、ASR 转写、微调、API 都有）。

### 3.3 成本测算

按全剧情 600 万–1000 万汉字、280 字/分钟估算，约 350–600 小时音频。

| 项目 | 用量 | 成本 |
|---|---|---|
| AAC-LC 48kbps 单声道 | 21.6MB/小时 | 600h ≈ 13GB |
| Cloudflare R2 存储 | $0.015/GB/月 | ≈ $0.20/月，出站免费 |
| Backblaze B2 | $6/TB/月 | ≈ $0.08/月，配 Cloudflare 出站免费 |
| 阿里云 OSS 标准存储 | ¥0.12/GB/月 | ≈ ¥1.6/月 |
| 阿里云 CDN 流量 | ¥0.20/GB | 200 DAU ≈ 65GB/月 ≈ ¥13；2000 DAU ≈ ¥130 |
| 4080 生成 600h | RTF 0.02 | 约 12 GPU 小时，电费几元 |
| 50 个角色微调 | 每个 10–20 分钟 | 约 10–17 GPU 小时 |

对比云端 API：火山引擎声音复刻套餐页的量级是 10 万字包原价 ¥1400 一档（折后 ¥420），600 万字就是数万元；MiniMax、Fish Audio 按分钟计费会便宜一些，但仍远高于自建。

音频格式用 **AAC-LC 48kbps / 24kHz 单声道 `.m4a`**。不用 Ogg Opus：Android 没问题，iOS 的 AVPlayer 原生不支持，Flutter 端还要额外解码器。

### 3.4 架构

```text
游戏剧情 JSON
   │
   ├─ 文本清洗/分句 ──> 任务表（SQLite/Postgres）
   │                        │
   │            4080: GPT-SoVITS 批量推理
   │                        │
   │            ffmpeg: 响度归一化 + AAC 编码
   │                        │
   │            内容寻址对象存储（R2/OSS/B2）
   │                        │
   │                  CDN（immutable 缓存）
   │                        │
   └────────── Flutter: manifest → 流式播放 + 本地 LRU 缓存
```

### 3.5 角色音色分级

| 档位 | 对象 | 做法 |
|---|---|---|
| A | 主线/常驻干员 50–80 人 | 1 分钟参考音，GPT-SoVITS 微调，相似度最高 |
| B | 有官方配音的 NPC | 5–10 秒零样本克隆，不微调 |
| C | 无配音角色 | 4 个默认音色：年轻男/女、成熟男/女 |
| 旁白 | 叙述文本 | 单独中性音色，语速略慢 |

参考音要求：5–10 秒、无 BGM、无音效、情绪中性、单说话人；带混响或战斗音效的素材先用 UVR5 分离。GPT-SoVITS 的 zero-shot 需要 `prompt_text` 与参考音逐字对应，差一个字都会明显掉质量。

### 3.6 文本处理

1. 剥离标记：`<color=#...>`、`\n`、`[$player_name]`、`{...}`、说话人前缀“阿米娅：”。
2. 按 `。！？；……` 切到 30–60 字，保留原行号，便于播放高亮。
3. 数字/日期转写：“3-1”读“三杠一”，“12:30”读“十二点三十”。
4. 中英混读：`PRTS`、`RHODES ISLAND` 这类代号建立自定义词典，统一按字母或中文近似读，避免模型自由发挥。
5. 多音字/生僻字：维护 `overrides.txt`，人工标注高频错字（“砾”“澄闪”“黍”等）。
6. 情绪：零样本会复制参考音情绪；旁白用中性参考，关键剧情准备“悲伤/激动”两套参考音。

### 3.7 生成与存储

内容寻址，天然去重：

```text
tts/{model_version}/{voice_id}/{sha1[:2]}/{sha1}.m4a
sha1 = sha1(f"{model_version}|{voice_id}|{text}|{speed}|{emotion}")
```

剧情里大量重复的“……”“博士。”“嗯”只会存一份，通常能省 10–20%。

任务表：

```sql
CREATE TABLE lines (
  id INTEGER PRIMARY KEY,
  story_id TEXT, line_idx INTEGER,
  speaker TEXT, voice_id TEXT,
  text TEXT, text_hash TEXT,
  object_key TEXT, duration REAL,
  status TEXT DEFAULT 'pending'  -- pending/done/failed
);
CREATE INDEX idx_status ON lines(status);
```

批量 worker（伪代码）：

```python
for voice_id, lines in group_by_voice(pending_lines):
    load_reference(voice_id)
    for line in lines:
        key = object_key(line)
        if storage.exists(key):
            mark_done(line, key)
            continue
        wav = gpt_sovits.tts(
            text=line.text,
            ref_audio=ref.wav,
            prompt_text=ref.prompt,
            text_lang="zh",
            speed_factor=1.0,
        )
        m4a = encode_aac(wav, bitrate="48k", samplerate=24000)
        storage.put(key, m4a)
        mark_done(line, key, duration=probe(m4a))
```

编码命令：

```bash
ffmpeg -y -i out.wav -af "loudnorm=I=-16:TP=-1.5:LRA=11" \
  -c:a aac -b:a 48k -ac 1 -ar 24000 out.m4a
```

章节 manifest：

```json
{
  "story_id": "main_01-07",
  "model": "gpt-sovits-v2proplus@2026-11",
  "lines": [
    {"i": 0, "speaker": "amiya", "voice": "amiya_v3",
     "text": "博士，这边。", "key": "tts/.../a1/3f9c.m4a", "dur": 1.82},
    {"i": 1, "speaker": "narrator", "voice": "narrator_v1",
     "text": "……", "key": "tts/.../00/7d21.m4a", "dur": 0.90}
  ]
}
```

### 3.8 对象存储与 CDN

- 海外优先：Cloudflare R2，出站免费，自定义域名 + CDN，`Cache-Control: public, max-age=31536000, immutable`。
- 国内为主：阿里云 OSS + CDN 或腾讯云 COS + CDN；自定义域名需备案，流量按 ¥0.2/GB 量级。
- 冷备：Backblaze B2 + Cloudflare（Bandwidth Alliance 出站免费）。
- 音频文件永不修改，CDN 命中率接近 100%，热门章节可提前预热。

### 3.9 按需生成

不要一上来全量生成：

1. 预生成主线前 3 章 + 当前活动 + 常驻干员密录，约 20–30 小时音频。
2. 播放到缺失行时先用端侧 TTS 兜底，同时把 `line_id` 上报队列；夜间批量生成并上传。
3. 第二天这条线就是克隆音色，存储随实际消费增长。

### 3.10 Flutter 客户端

- 打开章节拉取 manifest（50–100KB），预取当前行后 3 条。
- `just_audio` 支持 HTTP Range，可直接流式播放；配 `ConcatenatingAudioSource` 连续播放。
- 本地 LRU 缓存 200–300MB，key 用 `sha1`，离线可重听已缓存章节。
- 缺失/超时 → 端侧 TTS 或系统 TTS 兜底，UI 标注“AI 语音生成中”。
- 整章下载：Wi-Fi 下批量拉取。

### 3.11 落地节奏

| 阶段 | 内容 | 产出 |
|---|---|---|
| 第 1 周 | GPT-SoVITS 环境、5 个主角参考音、试听对比 | 确认相似度是否达标 |
| 第 2 周 | 文本清洗 + 分句 + 任务表 + 批量 worker | 跑通一个章节 |
| 第 3 周 | 对象存储 + manifest + Flutter 流式播放/缓存 | 端到端可用 |
| 第 4 周 | 50 个角色微调、主线前 3 章批量生成、CDN | 可发布的首个版本 |
| 之后 | 夜间按需补齐、长尾角色、情绪参考音 | 覆盖率逐步提升 |

### 3.12 风险

1. **版权（最大）**：用游戏原声克隆声优音色，公开发布存在声音权/肖像权风险；游戏语音素材本身也受版权保护。缓解：非商业、免费、显著标注“AI 合成”、提供下架联系方式；长期公开运营需取得授权，或改用自制/已授权参考音。
2. **相似度不稳定**：参考音太短、带情绪、带混响都会掉质量；主角值得花时间挑素材和微调。
3. **误读**：生僻字、多音字、英文代号是主要错误来源，必须保留人工 override 表。
4. **情绪单一**：零样本复制参考情绪；关键场景可用 IndexTTS2.5 精修。
5. **维护成本**：模型版本、角色音色版本、文本变更都会触发重生成，需要版本化路径与增量任务。

---

## 4. 与端侧方案的关系

- 端侧 TTS 继续作为离线兜底与新剧情未生成时的过渡。
- 云端克隆不改变现有播放架构：只是在 `DialogueVoice` 之上增加一个“远程音频源”，manifest 命中时直接播放 URL，未命中时回落到端侧合成。
- 两条路线共用同一套文本清洗、分句和角色映射表。

---

## 5. 重估条件

出现以下任意两条，再启动云端克隆：

1. 月活 ≥ 1000，且语音功能周活 ≥ 200；
2. 语音功能使用率 ≥ 20% 的活跃用户，或单章节平均收听完成率 ≥ 30%；
3. 用户反馈中“机械音/出戏/音色不对”占比 ≥ 10%；
4. 有稳定维护者能处理版权投诉、角色音色资产和模型更新；
5. 存储 + CDN 月成本可控制在 ¥200 以内（按当前测算，1000 DAU 量级可以做到）。

未达到之前，继续用端侧 TTS，不投入角色克隆。

---

## 6. 参考

- sherpa-onnx：https://github.com/k2-fsa/sherpa-onnx ｜ https://k2-fsa.github.io/sherpa/onnx/tts/index.html
- sherpa-onnx RTF：https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/rtf.html
- Kokoro v1.1-zh：https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh
- ZipVoice：https://github.com/k2-fsa/ZipVoice
- PocketTTS-ZH-6L：https://huggingface.co/hustfyb/PocketTTS-ZH-6L
- GPT-SoVITS：https://github.com/RVC-Boss/GPT-SoVITS
- IndexTTS：https://github.com/index-tts/index-tts
- CosyVoice：https://github.com/FunAudioLLM/CosyVoice
- VoxCPM：https://github.com/OpenBMB/VoxCPM

> AI生成
