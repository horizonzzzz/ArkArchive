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
| `tool/data/character_blocklist.txt` | 占位名与群体称呼，一行一个，支持 `#` 注释 |

元数据来自 `torappu.prts.wiki`。剧情脚本主源不可用时，按现有剧情仓库顺序回退到同一资源仓库的 jsDelivr 与 GitHub raw 地址。NPC 页面使用 PRTS 的 MediaWiki API。具体请求地址与输入 SHA-256 写入报告。

人工关系参考 PRTS「角色真名」「异格干员」页面及对应角色资料。官方 patch 关系可以直接归并；其他异格同体必须进入人工表。英文名的 `the` 模式只生成候选，不能自动改变归属，也不是异格关系的穷举检测。别名冲突、缺失目标、重复关系、链式关系或循环关系均导致构建失败。未知身份继续保留在未归属报告中，不能为了提高匹配率而猜测归属。

## 输出与客户端契约

构建目录保留 `schema: 1`、`stage: p0`，用于审查和复现。

| 文件 | 内容 |
| --- | --- |
| `index.json` | 人物导航、形态、已验证图片引用、详情文件名、剧情目录与扫描范围 |
| `details/*.json` | 档案、图片候选及验证状态、每幕出场节选 |
| `report.json` | 输入校验和、覆盖率、失败脚本、未归属称呼、异格候选与剩余门槛 |
| `unmatched_speakers.csv` | 按台词量排序的未归属称呼及人工确认列，包含 CSV 转义与公式注入防护 |
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
- 有档案但零条已识别出场的人物仍保留，页面应写“已识别出场”。
- `releaseReady` 要求完整扫描、整体匹配率 ≥70%、高频称呼匹配率 ≥90%、干员立绘覆盖率 ≥95%，且没有未复核的异格候选。它不是对每个别名或全部 NPC 图像归属的保证。

## 失败与重复构建

元数据结构异常会直接失败。个别脚本失败时继续收集错误，将结果写入 `<out>-failed` 并返回退出码 1，上次成功的 `<out>` 不变。离线模式不联网，缺失或损坏的缓存必须报错。

生成器先写临时目录，备份已有产物，再逐文件替换；失败时恢复旧文件。输出根目录保持不动，兼容 Windows 目录监听。恢复失败时保留备份并报告路径。这不是并发读取事务：同一缓存或输出目录不能同时构建，也不能把正在构建的目录直接作为线上数据源。应用只读取提交并随包发布的快照。

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

数据工具和客户端已在 Windows 运行测试，全量 Web release 构建通过。客户端交付范围、回放保护与平台验证结果见[首版实现记录](character-archive-implementation.md)。
