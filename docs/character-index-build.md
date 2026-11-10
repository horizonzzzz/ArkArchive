# 人物档案数据构建

本文记录人物档案第一阶段 P0.1 的构建工具、验证结果和后续工作。工具已能生成可复现的全量数据报告，但人物归属和图片质量尚未通过产品验收。当前没有新增客户端入口，也没有发布生产 manifest。

产品定义见 [人物档案设计](character-archive-design.md)，交互参考见 [HTML 原型](prototypes/character-archive.html)。原型中的出场数据只覆盖 41 篇样本，不作为全量统计依据。

## 运行方式

在项目根目录执行，使用项目现有 Flutter/Dart 环境与依赖，不需要安装 Python 或新增 Dart 依赖。

```sh
# 首次验证：扫描目录中的前 8 篇，默认写入 build/characters-sample
# 首次运行会下载元数据、NPC 页面和这 8 篇脚本。
dart run tool/character_index/build.dart --limit 8

# 全量构建：复用已有缓存，默认写入 build/characters
dart run tool/character_index/build.dart

# 使用相同输入缓存离线复现到独立目录
dart run tool/character_index/build.dart --offline --out build/characters-repro

# 查看全部参数
dart run tool/character_index/build.dart --help
```

可通过 `--cache` 指定元数据缓存目录，通过 `--stories-cache` 指定剧情缓存目录；默认分别为 `.cache/character-archive` 和其下的 `stories/`。`--npc-page` 可接收本地 PRTS HTML 或 MediaWiki API JSON 快照。`--concurrency` 为 1–16，默认 8。`--refresh` 重新获取上游数据，不能与 `--offline` 同用。

`.cache/` 与 `build/` 不提交到 Git。缓存保留响应原字节，报告记录输入校验和；脚本目录层次与 `storyTxt` 一致。缓存不按内容自动更新，需要刷新时显式使用 `--refresh`。

## 输入与维护文件

| 输入 | 用途 |
| --- | --- |
| `character_table.json` | 可获取干员的稳定 ID、名称、职业、星级及阵营原始代码 |
| `char_patch_table.json` | 官方明确的干员形态关系，包括阿米娅的近卫与医疗形态 |
| `handbook_info_table.json` | 档案正文、解锁类型及适用形态 |
| `story_review_table.json` | 与剧情馆一致的剧情目录及顺序 |
| PRTS「剧情角色一览」 | NPC 名称、简介、出处与剧情立绘候选 |
| `tool/data/form_merge.json` | 人工确认的异格同体关系；当前种子仅含 W/维什戴尔 |
| `tool/data/character_aliases.json` | 显示名到人物 ID 的人工别名映射；当前为 3 条种子 |
| `tool/data/character_blocklist.txt` | 不创建人物卡的占位名与群体称呼，一行一个，支持 `#` 注释 |

元数据来自 `torappu.prts.wiki`。剧情脚本主源不可用时，按现有剧情仓库的顺序回退到同一资源仓库的 jsDelivr 与 GitHub raw 地址。NPC 页面通过 PRTS 的 MediaWiki API 获取。具体请求地址与输入 SHA-256 写入报告。

官方 patch 关系可以直接归并，其他异格同体必须进入人工表。英文名的 `the` 模式仅生成候选，不改变人物归属，候选表也不是全部异格关系的完整清单。别名冲突、缺失目标、重复关系、链式关系或循环关系会导致构建失败，不能用后写入的值静默覆盖。

## 输出契约

这是 P0 调试数据，`schema: 1`、`stage: p0`。它不等同于设计文档中的最终客户端发布契约。

| 文件 | 内容 |
| --- | --- |
| `index.json` | 轻量人物导航信息、详情文件名、剧情目录、脚本校验和及扫描范围 |
| `details/*.json` | 形态、档案、未验证图片候选和每幕出场节选 |
| `report.json` | 数据源校验和、匹配覆盖率、失败脚本、未归属说话人、异格候选及剩余验收项 |
| `unmatched_speakers.csv` | 按台词量排序的未归属称呼、样本及留空的人工确认列；包含 CSV 转义和公式注入防护 |
| `.character-index-output` | 专用产物目录标记，防止误覆盖其他非空目录 |

干员 ID 为 `op:char_...`；NPC ID 为规范化名称的 URI 编码。详情文件名由 `detailFile` 给出，客户端不能自行拼接带冒号的人物 ID。NPC 以后改名会影响当前 ID，生产发布前需确定迁移规则。

`coverage.complete` 只表示 `story_review_table` 中全部脚本扫描成功，不表示所有人物已识别，也不覆盖目录之外的脚本。样本有 `sample: true`；不能把样本统计当成全部出场。

`namedLineCoverage` 的分母是所有非空、具名的 dialogue 指令，分子是成功归属到人物的指令数；排除称呼仍在分母中，并单独计入 `blockedLines`。`top200NamedLineCoverage` 先按称呼台词量选前 200 个称呼，再在这些称呼的台词上计算相同指标，不是前 200 个人物的比例。

台词扫描直接复用播放器的 `StoryScript.parse`。节选保存 `commandIndex`、原始行号、显示名和文本；脚本 SHA-256 来自原始字节。每幕保留首句、末句和中间最长句，长度相同取靠后一句，最终按剧情顺序排列；不足三句时不重复。未来回放应校验脚本版本，再使用指令位置，不能把原始行号当指令序号。

## 剧透与缺失数据

- 导航索引不写入档案正文或台词节选。
- 干员非 `DIRECT` 档案带剧透标记，并保留适用形态；NPC 简介可能直接透露身份和结局，因此全部默认标记为剧透内容。
- 当前图片只有 `artCandidates`，均为 `verified: false`，不生成已经验证过的 `card`、`hero` 或生产 `arts`。
- 有档案但零出场的人物仍保留。当前匹配不完整，客户端应说明“已识别的出场”，不能断言人物从未登场。
- `releaseReady` 固定为 `false`，防止把阶段产物误当成可直接发布的数据。

## 失败和重复构建

元数据结构异常会直接失败。个别脚本下载或解析失败时，工具继续收集错误，将不完整结果写入 `<out>-failed` 并返回退出码 1，上次成功的 `<out>` 不变。离线模式不会联网，缺失或损坏的缓存必须显式报错。

生成器先完整写入临时目录；已有产物先备份，再逐文件替换，失败时恢复旧文件。输出根目录保持不动，以兼容 Windows 中被监听、不能整体重命名的目录。如果恢复本身失败，错误信息会给出保留的备份目录。

这不是面向并发读取的事务发布机制。同一缓存或输出目录不要同时构建，也不要把正在构建的目录直接提供给客户端；正式 manifest 的版本切换和发布流程属于 P0.2。

## 2026-11-10 的验证结果

本次以下载到本地的真实数据快照为准，报告保存在 `build/characters/report.json`，后续上游更新可能改变数量。

| 指标 | 结果 |
| --- | ---: |
| 剧情目录条目 / 成功扫描 / 失败 | 2,061 / 2,061 / 0 |
| 人物记录 | 1,092 |
| 干员人物 / NPC 人物 | 437 / 655 |
| 干员形态 | 440 |
| 具名台词指令 | 375,432 |
| 已归属 / 排除 / 未归属台词 | 216,004 / 5,844 / 153,584 |
| 未归属称呼 | 6,374 |
| 带名台词匹配率 | 57.53%（目标 ≥ 70%） |
| 高频前 200 个称呼的台词匹配率 | 76.74%（目标 ≥ 90%） |
| 待人工复核的异格候选 | 29 |
| 生成的台词节选 | 26,930 |

两次全量离线构建生成 1,096 个文件；除 `index.json` 和 `report.json` 的生成时间外，内容完全一致。全部 2,061 个脚本校验和、1,092 个详情引用及 26,930 条节选的结构与位置顺序检查通过。模拟缺少两篇缓存时，退出码为 1，失败报告明确标记为不完整，既有成功样本的索引校验和不变。

23 项回归测试覆盖形态归并、别名冲突、NPC 页面解析、剧透标记、解析器位置、节选、缓存、下载回退、目录监听、失败回滚和路径安全。复现命令：

```sh
flutter test test/character_index_test.dart test/character_index_build_test.dart
dart analyze tool/character_index test/character_index_test.dart test/character_index_build_test.dart
dart format --output=none --set-exit-if-changed tool/character_index test/character_index_test.dart test/character_index_build_test.dart
```

验证环境为本地 Windows；本阶段未改客户端，也未验证各平台应用打包。图片连通性、干员立绘覆盖率、全部人工身份关系及生产发布尚未验证。

## 后续阶段

1. **P0.2 数据验收**：先复核高频未归属称呼与全部异格关系，避免为了提高比例而错误归并；补充干员剧情形象归属、图片有效性探测、中文阵营映射、稳定 ID 与生产 manifest，再重新核对覆盖率。
2. **P1.1 人物列表**：接入可版本化的数据仓库、搜索与筛选、详情按需缓存、无图及离线状态。完成数据验收前不能把当前报告当成完整人物出场数据。
3. **P1.2 人物详情**：实现形态切换、画廊、档案分区、出场章节和节选，默认保护 NPC 简介及未观看剧情的内容。
4. **P1.3 档案回放**：校验脚本版本并跳转对应指令，复用播放器但不写正常观看进度；验证退出回放后的原进度不变。

本阶段还同步消除了设计文档前后关于“只合并同名形态”和“人工合并异格”的冲突。下一阶段优先处理真实报告暴露的数据缺口，再落地客户端界面。
