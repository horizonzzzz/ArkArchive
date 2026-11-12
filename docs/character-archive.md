# 人物档案

本文是人物档案模块的唯一维护文档，记录当前实现、数据更新流程和后续开发约束。功能以人物为单位组织资料、立绘和已识别出场，并支持从台词节选进入剧情回放。

## 当前能力与边界

- 主导航第二项为「人物档案」。列表支持姓名、英文名、公开别名和形态名称搜索，以及类型、职业、阵营、星级筛选和排序；职业与星级须由同一形态同时满足。
- 页头固定，搜索和人物类型快捷切换始终可见；职业、阵营、星级集中在筛选面板，排序独立操作。应用干员条件自动切换到干员；切换到其他类型前须确认清除这些条件。空结果可分别清除搜索和筛选，筛选面板重置不改变搜索与排序。
- 详情提供形态切换、分层档案、立绘画廊与全屏查看、按篇章分组的出场及每幕最多三条台词节选。出场按人物聚合，切换形态不改变出场记录。
- 索引和全部人物文本随应用发布，可离线搜索和阅读。详情按需解析，读取缓存最多保留 12 份；图片按需联网并复用共享缓存，缺图或加载失败显示占位。清理单篇剧情缓存不会删除内置文本。
- 档案正文、别名与立绘直接展示；出场按篇章折叠导航，展开篇章即可查看全部节选。
- 回放返回后保留列表搜索、筛选、滚动位置，以及详情形态和章节展开状态。

当前未实现远程档案更新、人物收藏与外部链接、完整图片离线包、拼音搜索、皮肤/表情画廊、全部台词页和播放器内点击说话人进入人物页。干员在剧情中的限定形象尚未完整归入画廊。

## 代码入口与数据契约

| 位置 | 职责 |
| --- | --- |
| `lib/app/character_archive_data.dart` | 人物模型、包内数据读取、搜索筛选与排序 |
| `lib/app/character_archive_page.dart`、`character_detail_page.dart`、`character_archive_widgets.dart` | 列表、详情和共享组件 |
| `lib/app/character_archive_paths.dart` | 客户端与构建器共用的详情路径规则 |
| `lib/app/character_replay.dart` | 校验节选并定位剧情指令 |
| `lib/app/story_launcher.dart`、`story_player.dart` | 导航集成、回放入口与进度保护 |
| `tool/character_index/` | `build.dart` 构建、`catalog.dart` 归属与扫描、`artwork.dart` 图片验证、`bundle.dart` 打包、`draft_npc.dart` 起草 NPC |
| `assets/characters/` | 已验收的包内文本快照 |
| `test/character_*_test.dart` | 构建、真实资源、界面与回放回归测试 |

构建输出为 `index.json`、`details/*.json`、`report.json` 及人工复核 CSV；打包只保留索引、详情和 `manifest.json`。manifest 记录索引及逐个详情的 SHA-256，版本由内容决定，与生成时间无关。报告和构建目录不是线上数据服务。

人物、形态和别名必须区分：一人一张卡，同体干员单位放入 `forms`，公开真名或称号用于搜索及台词归属。干员 ID 为 `op:char_...`，NPC ID 来自规范化名称的 URI 编码。NPC 详情文件名使用 ID 的完整 SHA-256（`npc_<hash>.json`），避免 Flutter 再次转义后超过 Windows 文件名限制；客户端必须读取索引的 `detailFile`，不能自行拼接路径。NPC 更名可能改变 ID，新增收藏或外部链接前须设计迁移映射。

扫描复用 `StoryScript.parse`。每幕节选取首句、末句和中间最长句，同长取靠后一句，再按剧情顺序排列；不足三句不重复。节选记录从 0 开始的 `commandIndex`、从 1 开始的原始行号、说话人和文本；脚本 SHA-256 来自原始字节，不能与正常观看断点的指令指纹混用。

回放先校验脚本哈希，并检查目标指令的说话人与台词。脚本变化时，仅在原始行可消歧或内容唯一匹配时重新定位，否则从头观看并提示。播放器按第一个可用选项重建分支，无法到达的台词也回退到开头。档案回放期间，推进、跳转、后台切换、结束与退出均不得写入或清除原观看断点，也不提供原断点恢复入口；只有确认「继续观看」会替换本篇断点后，才恢复正常进度保存。

## 数据来源与人工维护

元数据来自 `torappu.prts.wiki`：`character_table`、`char_patch_table`、`handbook_info_table`、`handbook_team_table` 和 `story_review_table`。NPC 资料来自 PRTS「剧情角色一览」的 MediaWiki API；脚本复用剧情仓库的主源及 jsDelivr、GitHub raw 回退。具体请求地址和输入 SHA-256 写入构建报告。

| 文件 | 维护内容 |
| --- | --- |
| `tool/data/form_merge.json` | 人工确认的异格同体关系；官方 patch 关系可直接合并 |
| `tool/data/character_aliases.json` | 已核实、可公开展示和搜索的真名、英文名及简称 |
| `tool/data/npc_extra.json` | 边缘人物建卡、伪装称呼归属、已有 NPC 补图或别名 |
| `tool/data/character_blocklist.txt` | 占位名及群体称呼，一行一个，支持 `#` 注释 |
| `tool/data/npc_group_patterns.txt` | 群体称呼排除正则 |

不能按姓名子串、近似名称或台词热度猜测身份；英文名的 `the` 模式只生成待复核异格候选。别名冲突、缺失目标、重复、链式或循环关系会导致构建失败。问号、群体和无法确认身份的称呼保留在未归属报告，不自动生成空资料卡；有资料但零条已识别出场的人物仍保留。

`npc_extra.json` 有三种写法：

```json
{
  "新人物名": { "faction": "已确认阵营", "avg": "avg_npc_123_1", "aliases": ["公开别名"] },
  "“凯尔希”": { "mergeInto": "op:char_003_kalts" },
  "已有 NPC 名": { "avg": "avg_npc_456_1" }
}
```

示例资源 key 仅说明格式，录入前须核实。新人物的 `faction`、`avg`、`aliases` 均可省略；同名已有 NPC 只补充资料，不另建卡。`mergeInto` 必须指向已有完整人物 ID；归并称呼用于台词归属，也进入别名和搜索，节选保留原说话人。带引号本身不构成归属依据。

人工复核流程：

1. 构建后运行 `dart run tool/character_index/draft_npc.dart`，检查 `build/characters/npc_extra.draft.json` 和 `npc_extra.candidates.csv`。默认收录阈值为 30 句或 3 篇；立绘共现建议要求占比至少 0.6、计数至少 5，且模型复用度不超过 2。草稿不直接参与构建，仍须逐条复核。
2. 在 `people_lookup.csv` 查询已有角色和完整 ID，在 `unmatched_speakers.csv` 查询未归属称呼；完整篇目和全部共现 key 见 `report.json` 的 `unmatchedSpeakers`。CSV 只提供样本及前三个共现 key；共现表示发言时立绘在场，不能证明是发言人。
3. 核对相关剧情后，选择建卡、公开别名或 `mergeInto`，复制草稿前删除 `_evidence`。归属按称呼全局生效，当前不能按篇章区分同名人物；尤其应复核「主教」「班主任」「大审判官」「赦罪师」等职务称呼，无法确认则保留未归属。
4. 补图时结合 `avg_keys.csv` 的 `useStories`、`coSpeakers`、`topCoSpeakers`、`boundTo` 与实际图片确认。普通 `avg` 会枚举同款 `_1` 至 `_4` 候选并验证；带 `#`/`$` 的复杂 key 缺少 `avg_character_table` 映射，当前不绑定。舞台统计近似播放器 `character`/`charslot` 语义，槽位别名存在差异。
5. 每批修改后重建、检查报告、打包并回归测试；新增 `avg` 必须联网校验新 URL。用 PowerShell 读取完整报告时使用 `ConvertFrom-Json -AsHashtable`，避免仅大小写不同的键发生冲突。

起草工具使用 `--参数=值` 格式，可配置 `--report`、`--out`、`--csv`、`--npc-extra`、`--group-patterns`、`--min-lines`、`--min-stories`、`--avg-ratio`、`--avg-counts` 和 `--avg-max-reuse`。

## 构建、验收与打包

在项目根目录使用现有 Flutter/Dart 环境，无需额外依赖：

```sh
# 小样本，仅供调试，不能打包发布
dart run tool/character_index/build.dart --limit 8

# 全量扫描并验证图片
dart run tool/character_index/build.dart --verify-art

# 使用相同下载缓存和图片校验缓存离线复现
dart run tool/character_index/build.dart --offline --verify-art --out build/characters-repro

# 将通过验收的同一批次数据打包进应用
dart run tool/character_index/bundle.dart build/characters assets/characters

# 查看构建参数
dart run tool/character_index/build.dart --help
```

默认输出为 `build/characters`（样本为 `build/characters-sample`），下载缓存为 `.cache/character-archive`。`--cache`、`--stories-cache` 可指定缓存，`--npc-page` 可指定本地 PRTS HTML 或 MediaWiki API JSON，`--concurrency` 为 1–16，默认 8。`.cache/` 和 `build/` 不提交；验收后的 `assets/characters/` 随功能提交。

`--refresh` 刷新上游及图片验证，不能与 `--offline` 同用；不加 `--refresh` 的联网增量重跑可复用成功结果，重试临时网络失败。离线验证依赖先前联网结果，不代表图片当前仍可访问。只接受 PRTS 媒体站的 HTTPS 图片响应。

发布前检查 `report.json`：

- `coverage.complete` 为真且无失败脚本；它仅表示 `story_review_table` 目录内脚本全部扫描成功，不保证全部人物被识别，也不包括目录外脚本。
- `namedLineCoverage` ≥70%，`top200NamedLineCoverage` ≥90%；前者分母为全部非空具名 dialogue，包含被排除称呼，后者先选台词量前 200 个称呼再计算匹配率。
- 标准形态立绘覆盖率 `baseFormPortraitCoverage` ≥95%，无依赖异格图兜底的标准形态，无未复核异格候选，`remainingGates` 为空。
- 必须实际使用 `--verify-art`。当前不指定此参数会跳过图片门槛，单看 `releaseReady` 不能证明图片验收完成。卡片与候选图须按 `forms` 顺序取图，不能依赖上游 JSON 键序。

构建元数据异常会失败；部分脚本失败时写入 `<out>-failed`、返回退出码 1，并保留上次成功输出。生成器先写临时目录再替换，失败时恢复备份；这不是并发读取事务，同一缓存或输出目录不能同时构建。打包器只接受完整、通过验收、索引与报告属于同一批次的数据，并校验详情引用和人物 ID。

截至 2026-11-11，随包数据版本为 `259d2ef98590156c`：1,087 人（400 位干员、687 位 NPC），440 个干员形态，扫描 2,061 篇剧情；整体具名台词匹配率 73.93%，高频称呼匹配率 94.90%，标准形态立绘覆盖 400/400。数量及覆盖率是该批次构建结果，上游更新后须重新验收；界面应使用「已识别出场」，不能宣称完整出场统计。

## 回归检查与后续开发

```sh
flutter test test/character_index_test.dart test/character_index_build_test.dart test/character_index_assets_test.dart test/character_archive_test.dart test/character_replay_test.dart
flutter analyze --fatal-infos
```

修改身份归属或数据格式时重点检查：阿米娅三个形态、W/维什戴尔归并、真名与英文名搜索、标准形态默认立绘、伪装称呼不进入公开搜索、资源哈希及 `detailFile`。修改页面或回放时检查窄屏与文字放大、组合筛选、缺图和重试、重复台词与非默认分支降级、回放全程不写进度及确认后恢复保存。

已知待处理项：已有 NPC 的 `faction` 补充及冲突校验存在问题，修复前不要依赖人工表改阵营；复杂 AVG key 映射与按篇章区分同名称呼尚不支持。优先保证身份归属正确，再扩大收录；未确认条目继续留在报告。

历史验证边界：2026-11-11 数据批次通过 302 项测试和静态分析；此前 Web、Windows release 构建及资源校验通过，Web 做过桌面和 390px 浏览器交互检查。Windows 未做窗口交互验证，Android、iOS、macOS、Linux 未在该轮构建。后续修改须按受影响平台重新验证，这些记录不能替代当前检查。
