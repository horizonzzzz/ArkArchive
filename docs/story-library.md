# 剧情馆与应用导航

本文是剧情馆和应用导航的维护文档，供 agent 定位目录、搜索、播放入口及页面状态。播放器语义见 [story-player.md](story-player.md)，离线下载见 [asset-cache.md](asset-cache.md)，人物回放见 [character-archive.md](character-archive.md)。

## 当前能力与代码入口

剧情馆按章节浏览主线、活动、故事集、玩法剧情及其他剧情，支持搜索、分类、章节分页、逐幕播放和缓存。应用通过同一入口整合剧情馆、人物档案、缓存管理和设置。

| 位置 | 职责 |
| --- | --- |
| `lib/app/app.dart` | `MaterialApp`、应用标题和主题入口 |
| `lib/app/story_launcher.dart` | `StoryLauncher`、主导航、剧情馆、播放准备与缓存任务协调 |
| `lib/story_player/data/story_repository.dart` | `StoryRepository`、目录模型、脚本加载和预加载 |
| `lib/app/activity_images.dart` | 章节活动 ID 与展示图片的映射 |
| `lib/app/app_theme.dart`、`lib/app/archive_widgets.dart` | 全站主题和公共组件 |
| `lib/app/archive_motion.dart` | 页面及列表过渡、减少动态效果适配 |

## 目录与标识约定

- 主目录读取 `https://torappu.prts.wiki/gamedata/latest/excel/story_review_table.json`；脚本基础地址为 `https://torappu.prts.wiki/gamedata/latest/story/`。
- 主目录只排除空的 `storyTxt`。不要按 `storyCanShow` 过滤：它标记游戏内剧情回顾是否展示，主线和干员密录也可能为 0。
- `StoryGroup` 保存章节名称、条目、`entryType` 和 `id`；`StoryEntry` 保存展示标题、`path`、`code`、`name` 和 `tag`。展示标题由剧情编号、名称和行动前后标签组成。
- `StoryEntry.path` 同时关联脚本、独立缓存、观看进度和人物出场。修改路径规则必须同步处理旧缓存和进度，不能用展示标题代替稳定标识。
- 启动时先读取共享层中的主目录和玩法目录，后台刷新 PRTS 主目录及「剧情一览」中的玩法条目；刷新失败时保留已读取的本地目录。玩法目录远端不可用时回退本地副本。缓存页面独立读取完整缓存索引，不等待目录请求。
- 分类映射在 `_categoryOf`：`MAINLINE`、`ACTIVITY`、`MINI_ACTIVITY`、`GAMEPLAY`，其他类型统一归入其余分类。新增上游类型时同时核对筛选和排序。

## 搜索、分页与页面状态

搜索对输入去首尾空白并转小写，匹配章节名或条目标题；命中章节名时显示整章，命中条目时只保留对应剧情。修改搜索时保留这一区别。

剧情馆每页显示 10 个章节，分别记录分类的页码。搜索、分类切换和数据更新后应保证当前页有效；空结果、末页和返回原分类都需回归。分页发生在章节层级，不应拆散同一章的剧情条目。

宽度达到 1100 时使用桌面导航；移动端玻璃导航还受平台和高对比度设置约束。页面状态由 `IndexedStack` 保留；切换导航不应重置人物筛选、目录页码或正在执行的缓存任务。`ArchiveMotion` 尊重系统减少动态效果设置，`ArchivePageTransition` 不额外保留旧页面的可操作副本，避免过渡期间重复语义节点和点击目标。

剧情行将「继续观看」和「已看完」放在同一个观看状态位置：重看产生断点时优先显示「继续观看」，原有看完记录不删除；断点清除后再次显示「已看完」。离线列表采用相同优先级。剧情馆以带语义说明的图标展示已缓存或缓存中，减少与剧情编号、行动前后标签的并列数量。看完记录按 `StoryEntry.path` 保存，删除剧情缓存或清理资源不会删除记录。

## 播放入口与数据源回退

`StoryLauncher._open` 负责完整入口：加载脚本、检查可播放性、可选人物台词定位、读取正常观看断点、准备资源、打开播放器，返回后等待进度写入并刷新缓存统计。它与删除、迁移和其他播放准备互斥；后台下载本身不应阻塞已缓存剧情的播放。

- 已完整缓存的剧情将 `AssetStore.playbackScope` 设为 `entry.path`，优先读取该篇目录；在线试看使用共享作用域。退出或失败后必须清理作用域，避免污染下一篇剧情。
- 离线播放先在该剧情的独立目录中检查所有脚本候选地址，包括镜像；找不到脚本时提示重新缓存，不等待网络探测。
- 普通观看把断点交给播放器，由用户选择继续；人物档案回放不传入普通续播入口，且不得覆盖原观看进度。
- 原始脚本依次尝试主源、jsDelivr 的 `yuanyan3060/ArknightsGameResource@main/gamedata/story/`、同仓库 GitHub raw 地址。当前仅对 `http.ClientException` 切源，取消请求直接上抛；解析错误和超时不会自动换源。不要把取消误当作网络重试。
- PRTS 页面通过 MediaWiki `api.php` 的 `parse` 接口提取 `#datas_txt`。中文路径在构造 API 请求前先解码，避免将已有 `%` 再次编码成 `%25`。
- 原始文本响应须排除 HTML。原始脚本的 `sourceHash` 是响应字节的 SHA-256；从网页提取的脚本没有相同的字节来源，不能伪造该值。
- `prepare` 加载 `MediaCatalog` 并预加载静态依赖，结果中的 `warnings` 需要在入口展示；能打开播放器不代表离线包完整。

## 修改后的验证

目录、入口与页面状态改动优先运行：

```sh
flutter test test/data_test.dart test/product_ui_test.dart test/archive_motion_test.dart
```

涉及人物入口或续播时，还需运行 `test/character_replay_test.dart` 和 `test/playback_progress_widget_test.dart`。在窄屏与桌面宽度分别检查搜索、分类分页、空结果、播放失败后重试，以及播放器返回后的页面状态；不把历史截图作为当前布局的验收结果。

## 历史依据与边界

目录并非本地固定清单，上游条目和网页结构会变化。当前没有独立的目录版本迁移或后台增量同步协议；新增刷新能力时应明确主目录、玩法目录和现有共享缓存的更新策略。

历史定位入口：`80316d9` 引入玩法目录，`dd1d4bb` 引入章节分页，`ba4fbe0` 引入脚本回退源，`45ff49d` 修正 URL 编解码。已删除的早期总体设计可通过 `git show 2f26ce7^:docs/DESIGN.md` 查阅，但其结构和功能设想不能替代当前源码。
