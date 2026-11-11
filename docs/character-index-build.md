# 人物档案数据构建

本文记录人物档案 P0.1 构建工具和 P0.2 数据验收。2026-11-10 快照已通过完整扫描、台词覆盖率和干员立绘覆盖率门槛；仍有未归属台词，不能把出场统计解释为游戏中的全部出场。客户端页面与剧情回放在后续阶段接入。

产品定义见 [人物档案设计](character-archive-design.md)，交互参考见 [HTML 原型](prototypes/character-archive.html)。原型只扫描了 41 篇样本，不作为全量统计依据。

## 构建与打包

在项目根目录执行，使用项目现有 Flutter/Dart 环境与依赖，无需安装额外依赖。

```sh
# 小样本，默认写入 build/characters-sample
dart run tool/character_index/build.dart --limit 8

# 全量扫描并验证图片，默认写入 build/characters
dart run tool/character_index/build.dart --verify-art

# 使用相同下载缓存和图片校验缓存离线复现
dart run tool/character_index/build.dart --offline --verify-art --out build/characters-repro

# 只允许完整、通过验收且索引与报告属于同一批次的数据进入应用
dart run tool/character_index/bundle.dart build/characters assets/characters

# 查看全部构建参数
dart run tool/character_index/build.dart --help
```

`--cache` 指定元数据缓存目录，默认 `.cache/character-archive`；`--stories-cache` 默认是其下的 `stories/`。`--npc-page` 可接收本地 PRTS HTML 或 MediaWiki API JSON 快照。`--concurrency` 为 1–16，默认 8。

`--refresh` 重新获取上游数据；同时指定 `--verify-art` 时也重新检查图片，不复用旧的成功或 404 记录。它不能与 `--offline` 同用。图片校验只接受 PRTS 媒体站的 HTTPS 图片响应，临时网络失败不永久缓存。离线校验使用最近一次实际联网验证结果，并不代表图片服务此刻仍可访问。

`.cache/` 与 `build/` 不提交到 Git。缓存保留响应原字节，报告记录输入校验和；脚本目录层次与 `storyTxt` 一致。`assets/characters/` 是经过验收、供应用读取的文本快照，应随功能提交。

## 输入与人工维护

| 输入 | 用途 |
| --- | --- |
| `character_table.json` | 可获取干员 ID、名称、职业、星级与阵营代码 |
| `char_patch_table.json` | 官方明确的形态关系，包括阿米娅的近卫与医疗形态 |
| `handbook_info_table.json` | 档案正文、解锁类型与适用形态 |
| `handbook_team_table.json` | 国家、地区和组织的中文名称 |
| `story_review_table.json` | 与剧情馆一致的剧情目录及顺序 |
| PRTS「剧情角色一览」 | NPC 名称、简介、出处与剧情立绘候选 |
| `tool/data/form_merge.json` | 38 组人工确认的异格同体关系 |
| `tool/data/character_aliases.json` | 138 条人工确认的真名、英文名及简称映射 |
| `tool/data/npc_extra.json` | 人工收录表：边缘剧情人物建卡与伪装/归属合并 |
| `tool/data/character_blocklist.txt` | 占位名与群体称呼，一行一个，支持 `#` 注释 |

元数据来自 `torappu.prts.wiki`。剧情脚本主源不可用时，按现有剧情仓库顺序回退到同一资源仓库的 jsDelivr 与 GitHub raw 地址。NPC 页面使用 PRTS 的 MediaWiki API。具体请求地址与输入 SHA-256 写入报告。

人工关系参考 PRTS「角色真名」「异格干员」页面及对应角色资料。官方 patch 关系可以直接归并；其他异格同体必须进入人工表。英文名的 `the` 模式只生成候选，不能自动改变归属，也不是异格关系的穷举检测。别名冲突、缺失目标、重复关系、链式关系或循环关系均导致构建失败。未知身份继续保留在未归属报告中，不能为了提高匹配率而猜测归属。

### npc_extra.json 人工收录表

收录 PRTS 一览页未覆盖、但确有戏份的边缘剧情人物，以及剧情演出中的伪装称呼。单表三通道：

```jsonc
{
  // ① 建卡：faction 可选；avg 是脚本 Character/charslot 指令的资源 key，
  //    构建期枚举 Avg_<base>_1..4.png 交给图片校验淘汰
  "薇丽塔": { "faction": "莱塔尼亚", "avg": "avg_npc_123_1", "aliases": ["“医师”"] },
  // ② 伪装/归属合并：台词归入真身出场记录；
  //    假名不进入公开别名、搜索索引与卡片展示，防止身份揭示泄露
  "“凯尔希”": { "mergeInto": "op:char_003_kalts" },
  // ③ 已有卡片补充：为一览页已收录但缺立绘的人物补 avg 候选
  "已知人物": { "avg": "avg_npc_456_1" }
}
```

校验规则：mergeInto 目标必须存在且不得与其他称呼冲突；条目名不得命中排除表；建卡名与已有卡同名时只补充 avg/aliases，faction 不得与既有人物不一致。带引号的称呼不会自动视为伪装，也不自动建卡，一切以人工登记为准。

### 起草工具

```sh
# 从最近一次构建报告中起草候选（不直接参与构建）
dart run tool/character_index/draft_npc.dart

# 可选参数：--report --out --csv --npc-extra 指定输入输出路径；
# --min-lines（默认 30）、--min-stories（默认 3）为收录阈值；
# --avg-ratio（默认 0.6）、--avg-counts（默认 5）为立绘共现置信阈值。
```

扫描阶段会跟踪舞台立绘状态（近似播放器 `character`/`charslot` 语义，槽位别名存在差异），为每条未归属称呼记录「说话时台上是谁」的共现计数与出现篇目。起草规则：台词量或篇目数达到阈值且立绘共现集中（top key 占比 ≥ avg-ratio 且计数 ≥ avg-counts）时给出 avg 建议字段；假名/借名、问号占位、未达阈值一律写入 `npc_extra.candidates.csv` 待人工判断，绝不写入 draft.json。draft.json 中的 `_evidence` 字段仅供复核，拷入 `tool/data/npc_extra.json` 前需整段删除。

### 人工查询对照表

每次构建后生成在 `build/characters/` 下（UTF-8 BOM，Excel 可直接筛选；不进 Git，重跑构建即可恢复）：

| 文件 | 用途 | 关键列 |
| --- | --- | --- |
| `people_lookup.csv` | 按 name 查 mergeInto 需要的完整人物 ID（npc: 为 URL 编码，只能从此表复制）；含干员与剧情角色全量 1,087 人 | `name,id,kind,faction,aliases,lineCount,storyCount,formCount,inIndex` |
| `avg_keys.csv` | 全部 avg 资源 key（约 1.1 万个，剧本登场 ∪ 已绑定）与使用统计 | `key,useStories,coSpeakers,topCoSpeakers,boundTo` |
| `unmatched_speakers.csv` | 未归属说话人按台词量排序，含共现立绘证据 | `name,lineCount,stories,sampleStory,sampleText,avgKeys` |

### 人工复核流程

1. 运行 `dart run tool/character_index/draft_npc.dart`，从 `build/characters/npc_extra.draft.json` 开始逐条复核。草稿按台词量排序，已按阈值和群体、问号、引号规则初筛，但仍可能包含通用职务或多人共用的名字，不能直接导入。其他候选见 `npc_extra.candidates.csv`，完整未归属列表见 `unmatched_speakers.csv`。
2. 确认称呼指向的具体人物，并检查所有相关剧情。CSV 的 `stories` 只是篇目数，`avgKeys` 只列共现次数最多的三个 key；完整篇目路径和全部共现 key 在 `report.json` 的 `unmatchedSpeakers` 中。PowerShell 7 可用下列命令查询：

   ```powershell
   $report = Get-Content -Raw -Encoding utf8 build/characters/report.json | ConvertFrom-Json -AsHashtable
   $speaker = $report.unmatchedSpeakers | Where-Object { $_.name -eq '盾卫' }
   $speaker.stories
   $speaker.avgKeys
   ```

   使用 `-AsHashtable` 是因为报告中可能有仅大小写不同的键。`sampleStory` 和 `sampleText` 仅是样本；共现表示说话时立绘在场，不证明立绘就是发言人，槽位统计也可能存在误差。
3. 在 `people_lookup.csv` 查已有角色和完整 ID，再选择处理方式：独立且全局唯一的人物在 `npc_extra.json` 建卡；已有人物的公开真名、代号或简称写入 `character_aliases.json`，用于搜索和展示；归属本身会揭示身份的伪装称呼写入 `npc_extra.json` 的 `mergeInto`，仅归并台词。节选保留原说话人，用户主动展开后仍可看到。草稿复制到正式表前删除 `_evidence`。
4. 所有归属按称呼全局生效。同名职务、群体或不同剧情中指向不同人物的称呼不能直接建卡或归并；当前不支持按篇章分别归属。优先核对现有“主教”“班主任”“大审判官”“赦罪师”，有混用或无法确认时保留未归属；移除错误条目并重建可恢复未归属状态。群体规则或排除表命中的名称不得建卡，身份不明也不必强行处理。
5. 可选补图：用 `avgKeys` 找候选，在 `avg_keys.csv` 查看 `useStories`、`coSpeakers`、`topCoSpeakers` 和 `boundTo`，再结合剧情及实际图片判断；共现人数少、未绑定其他人都不是身份确认。可在浏览器打开 `https://prts.wiki/wiki/File:Avg_<key>.png` 查看。确认的基础款例如 `avg_npc_777_1` 可填入 `avg`，构建会检查该款及 `_2`、`_3`、`_4` 候选；复杂的 `#`/`$` key 见下方限制。无把握时不填，人物仍可建卡并显示姓名占位。
6. 每批修改后重新构建，检查 `statistics` 中的 `people`、`namedLineCoverage`、报告中的 `remainingGates` 和 `avg_keys.csv` 的 `boundTo`；打包后在应用中检查卡片，再运行回归测试。只增加名字且不需要验证新图片时，可先用 `--offline --verify-art` 做中间检查；新增 `avg` 时应联网运行 `--verify-art`，离线缓存缺少新 URL 会导致图片未通过校验。

   ```sh
   dart run tool/character_index/build.dart --verify-art
   dart run tool/character_index/bundle.dart build/characters assets/characters
   flutter test test/character_index_test.dart test/character_archive_test.dart
   ```

发布前须确认执行了图片校验：当前代码在未指定 `--verify-art` 时不会执行图片覆盖率门槛，即使报告显示 `releaseReady` 也不能视为完成图片验收。已有 NPC 的 `faction` 补充及冲突校验当前也存在问题，修复前不要依赖人工表更改其阵营。

## 输出与客户端契约

构建目录保留 `schema: 1`、`stage: p0`，用于审查和复现。

| 文件 | 内容 |
| --- | --- |
| `index.json` | 人物导航、形态、已验证图片引用、详情文件名、剧情目录与扫描范围 |
| `details/*.json` | 档案、图片候选及验证状态、每幕出场节选 |
| `report.json` | 输入校验和、覆盖率、失败脚本、未归属称呼（含立绘共现证据与篇目数）、异格候选与剩余门槛 |
| `unmatched_speakers.csv` | 按台词量排序的未归属称呼、篇目数、共现立绘 top3 及人工确认列，包含 CSV 转义与公式注入防护 |
| `people_lookup.csv` / `avg_keys.csv` | 人工查询对照表（见上文「人工查询对照表」节） |
| `.character-index-output` | 专用产物目录标记，防止误覆盖其他非空目录 |

打包工具移除索引中的阶段标记，加入质量摘要和内容版本，压缩 JSON 排版，并生成 `manifest.json`。manifest 含索引与逐个详情文件的 SHA-256；版本由内容决定，不随生成时间改变。客户端只使用 `index.json`、`details/` 和 `manifest.json`，不包含调试报告、CSV、剧情源脚本或图片文件。

首版采用包内完整文本快照：搜索和档案阅读不依赖未部署的数据服务，详情仍按需读取，图片复用应用的共享缓存。当前详情文本约 10.2 MB，逐文件 gzip 约 4.3 MB；这只是文本压缩测量，不是各平台安装包增量。远程 manifest 更新、完整图片离线包和按需下载机制留作后续功能。

干员 ID 为 `op:char_...`；NPC ID 来自规范化名称的 URI 编码。NPC 详情文件名使用该 ID 的完整 SHA-256（`npc_<hash>.json`），避免名称经 Flutter 再次转义后超过 Windows 文件名限制；干员沿用 `op_char_....json`。客户端与构建器共用路径规则，必须使用 `detailFile`。打包时会验证详情引用及人物 ID。NPC 更名可能改变 ID；首版不保存基于人物 ID 的收藏或外部链接，未来加入这些功能时须补迁移映射。

`coverage.complete` 只表示 `story_review_table` 中全部脚本扫描成功，不代表全部人物被识别，也不包括目录外脚本。样本有 `sample: true`。`namedLineCoverage` 的分母为全部非空、具名的 dialogue 指令，排除称呼也计入分母；`top200NamedLineCoverage` 按称呼台词量选出前 200 个称呼，再计算它们的台词匹配率。

扫描复用播放器的 `StoryScript.parse`。节选保留 `commandIndex`、1 起始原始行号、说话人和文本，脚本 SHA-256 来自原始字节。每幕保留首句、末句和中间最长句，同长取靠后一句，按剧情顺序排列；不足三句不重复。回放必须校验脚本版本，不能把行号当指令序号。

## 剧透与缺失数据

- 导航索引不包含档案正文或台词节选。
- 非 `DIRECT` 干员档案默认标记为剧透，并保留适用形态；NPC 简介全部默认标记为剧透。
- 图片只有校验成功后才提供给客户端；缺图使用占位，不把网络失败误报为人物没有立绘。
- 卡片默认图与画廊候选严格按人物形态顺序（标准形态优先）排列，上游 JSON 键序不影响展示；标准形态缺图时退回其它已验证立绘。
- 伪装称呼只影响台词归属，不进入公开别名与搜索。
- 有档案但零条已识别出场的人物仍保留，页面应写“已识别出场”。
- `releaseReady` 要求完整扫描、整体匹配率 ≥70%、高频称呼匹配率 ≥90%、干员标准形态立绘覆盖率 ≥95% 且无靠异格立绘兑底的形态、且没有未复核的异格候选。它不是对每个别名或全部 NPC 图像归属的保证。

## 失败与重复构建

元数据结构异常会直接失败。个别脚本失败时继续收集错误，将结果写入 `<out>-failed` 并返回退出码 1，上次成功的 `<out>` 不变。离线模式不联网，缺失或损坏的缓存必须报错。

生成器先写临时目录，备份已有产物，再逐文件替换；失败时恢复旧文件。输出根目录保持不动，兼容 Windows 目录监听。恢复失败时保留备份并报告路径。这不是并发读取事务：同一缓存或输出目录不能同时构建，也不能把正在构建的目录直接作为线上数据源。应用只读取提交并随包发布的快照。

## 2026-11-11 数据批次（Q1 修复 + Q3 边缘人物收录）

修复卡片默认立绘取图顺序（38 位多形态干员 38/38 与标准形态一致），引入 npc_extra.json 人工收录表与起草工具，收录第一批 32 位边缘剧情人物。

| 指标 | 2026-11-10 | 2026-11-11 |
| --- | ---: | ---: |
| 人物 / 干员 / NPC | 1,055 / 400 / 655 | 1,087 / 400 / 687 |
| 已归属台词 | 269,865 | 277,565 |
| 未归属称呼 | 6,241 | 6,209 |
| 整体匹配率 | 71.88% | 73.93% |
| 高频称呼匹配率 | 94.30% | 94.90% |
| 标准形态立绘覆盖 | —（口径为任一形态） | 400 / 400 |
| 图片 URL 有效 / 已检查 | 1,901 / 1,937 | 1,902 / 1,941 |

备注：图片校验存在瞬时网络抖动，`--refresh` 会丢弃已成功缓存导致结果回退；增量重跑 `--verify-art`（不带 `--refresh`/`--offline`）可收敛到全量验证。`baseFormPortraitCoverage` 验证阶段曾报 0.995/0.975，最终收敛为 1.0。

### 已知限制

- npc_extra 的 `avg` 绑定要求媒体文件名与资源 key 同形（`Avg_<key>.png`）；带 `#`/`$` 修饰的复杂 key 需经 avg_character_table 映射，当前数据源未提供该表，这类型号（如 `avg_npc_1068_1#1$1`）不做绑定，留待接入映射表后补。
- 同一 avg key 被多个说话人引用（路人复用模型）时不能自动绑立绘；起草工具以「模型复用 ≤2」为自动绑定阈值，超出的候选只建卡不绑图。

## 2026-11-10 验收结果

以本地下载快照及 `build/characters/report.json` 为准，上游更新会改变数量。

| 指标 | P0.1 | P0.2 |
| --- | ---: | ---: |
| 成功扫描 / 失败 | 2,061 / 0 | 2,061 / 0 |
| 人物 / 干员 / NPC | 1,092 / 437 / 655 | 1,055 / 400 / 655 |
| 干员形态 | 440 | 440 |
| 具名台词 | 375,432 | 375,432 |
| 已归属台词 | 216,004 | 269,865 |
| 排除 / 未归属台词 | 5,844 / 153,584 | 5,844 / 99,723 |
| 未归属称呼 | 6,374 | 6,241 |
| 整体匹配率 | 57.53% | 71.88% |
| 高频称呼匹配率 | 76.74% | 94.30% |
| 待复核异格候选 | 29 | 0 |
| 有效基础立绘的干员 | 未验证 | 400 / 400 |
| 图片 URL 有效 / 已检查 | 未验证 | 1,901 / 1,937 |
| 台词节选 | 26,930 | 33,448 |

人物数减少来自已确认的异格归并，并非删除形态。验收通过后仍保留 99,723 条未归属台词及对应审查报告。

回归测试覆盖归并、别名冲突、NPC 解析、剧透标记、解析器位置、节选、下载回退、图片响应与刷新缓存、输出回滚、详情路径安全和打包版本稳定性。

```sh
flutter test test/character_index_test.dart test/character_index_build_test.dart test/character_index_assets_test.dart
dart analyze tool/character_index test/character_index_test.dart test/character_index_build_test.dart test/character_index_assets_test.dart
dart format --output=none --set-exit-if-changed tool/character_index test/character_index_test.dart test/character_index_build_test.dart test/character_index_assets_test.dart
```

数据工具和客户端已在 Windows 运行测试，Web 与 Windows release 构建通过。客户端交付范围、回放保护与平台验证结果见[首版实现记录](character-archive-implementation.md)。

> AI生成
