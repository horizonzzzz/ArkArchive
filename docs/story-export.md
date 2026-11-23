# 素材导出

本文是剧情素材导出的维护文档，供 agent 定位清单生成、预览、导出与任务协调。资源映射见 [asset-cache.md](asset-cache.md)，剧情馆入口见 [story-library.md](story-library.md)。

## 代码入口

| 位置 | 职责 |
| --- | --- |
| `lib/story_player/data/media_catalog.dart` | `AssetKind`/`AssetFile`/`AssetRef`、`collect` 逐指令收集带分类的资源引用 |
| `lib/story_player/data/asset_package.dart` | `AssetItem`/`AssetPackage` 聚合、文件名清洗、目录命名 |
| `lib/story_player/data/asset_store.dart` | `loadTransient`（缓存优先、不落缓存）、`cachedSize`、导出目录记忆 |
| `lib/story_player/data/preview_cache.dart` | 预览字节 LRU；对话框关闭即释放 |
| `lib/story_player/data/story_export.dart` | `StoryExporter` 导出编排、manifest、失败汇总 |
| `lib/story_player/data/export_target.dart` + `_io` + `_backend` | 导出门面：按平台分发后端，平台差异收敛于此 |
| `lib/story_player/data/export_target_desktop.dart` | 桌面写入端：目录创建、原子写、打开文件夹 |
| `lib/story_player/data/export_target_android.dart` | Android 写入端：zip 流式打包、系统分享 |
| `lib/story_player/data/story_repository.dart` | `packageEntry` 清单构建；脚本缓存优先加载 |
| `lib/app/story_export_page.dart` | 资源浏览器对话框：分类、缩略图、大图、音频行、任务视图 |
| `lib/app/audio_preview.dart` | `AudioPreviewBackend` + 30 秒试听控制器 |
| `lib/app/export_job.dart` | 导出任务的可观察状态，菜单与对话框共享 |
| `lib/app/story_launcher.dart` | 菜单入口、任务生命周期、后台继续与完成提示 |

## 清单模型与合并规则

`MediaCatalog.collect` 逐条指令输出 `AssetRef`（带 kind/title/group 与导出路径），`AssetPackage.fromRefs` 聚合成用户看到的 `AssetItem`。两层模型的目的是保证「能播放、能缓存、能导出」共享同一清单：

- `dependencies()` 是 `collect()` 的 URI 投影；两者必须一致，用测试锁住。新增资源指令时先扩展 `collect`，投影与导出自动跟随。
- BGM：同一 `PlayMusic` 的 `key`（循环体）与 `intro`（前奏）合并为一个条目，条目名去 `_loop`/`_intro` 后缀；同一曲目跨指令去重。
- 立绘：`character()` 的 body 与表情差分按角色基础键（`characterBase`）合并，预览取 body，角标显示差分数。差分导出路径保留上游相对目录与 `$` 差分名。
- `interlude` type=3 立绘缺失时静默回退切入图，不告警；其余未解析项进入 `unresolved`（来自现有 warnings 语义）。
- 导出路径：`images/background|cg|cutin|item/<上游文件名>`、`characters/<上游相对路径>`、`audio/<上游相对路径>`；非默认资源站的完整 URL 落入 `extras/`。音频路径段中的 `#` 等特殊字符经逐段编码下载、解码后写盘。
- 路径在 `AssetPackage.fromRefs` 统一「定稿」：逐段 `sanitizeFileName` 清洗；不同来源撞同一路径时加 8 位来源哈希后缀（`a_1a2b3c4d.mp3`）；定稿路径同时用于写盘与 manifest，两者必须一致。同一来源用于不同分类（如既作 CG 又作道具图）时路径不同，各写一份。
- 末层目录已存在自动追加 ` (2)` 序号，不覆盖任何已有内容。
- 父目录（默认导出路径「下载/方舟档案室」由应用拼接、此前不存在）由 `ExportTarget.createDirectory` 递归创建，首次直接导出即可成功；取消只清理导出根目录，不连带删除自动创建的父级目录。

## 预览与选择

- 对话框默认全选；左栏四个类别（图片/立绘/音频/脚本），图片与音频有子类筛选；选择粒度为条目，导出写条目下全部文件，避免导出残缺组合（如只有前奏没有循环体）。
- 缩略图懒加载，解码宽度 320px；字节 LRU 上限 48MB，对话框关闭整体释放。预览加载在 build 外回写状态，禁止在 build/errorBuilder 中调用 setState。
- 音频试听 30 秒自动停；同一时间只播一项，切歌先停旧项。**先订阅位置并启动计时器，再 `await backend.play()`**——just_audio 的 `play()` Future 要等到播放结束、暂停或停止才完成，不能作为「已出声」信号，否则计时与进度在 Android/macOS 上会等到整首播完才生效。后端 `positions` 必须是可重复监听的广播流（just_audio 的 positionStream 即是）。本地 file URI 打不开（如父目录含非 ASCII）时回退网络地址重试；仍失败才在对应行显示错误。
- 体积统计：`cachedSize` 只查磁盘不发网络；已缓存条目显示精确大小，全部已知时底栏显示精确总量，否则显示已统计部分。选择统计按**来源 URI 去重**（同一文件被多个条目引用只计一次）；文件数按「来源 + 目标路径」去重（同一来源用于不同分类时目标路径不同，各计一份）。

## 导出执行与边界

- 字节获取统一走 `AssetStore.loadTransient`：剧情层缓存 → 共享层缓存 → 网络（主地址失败按序试脚本镜像）。结果不写入任何缓存层、不驻留 `_memory`，导出不改变「已缓存」标记与缓存体积统计。
- 全部文件（含 manifest）写完后调用 `target.commit()` 收尾：桌面为空实现，Android 在此写入 zip 中央目录；`createDirectory` 的返回值就是结果页与提示条展示的位置（桌面为目录路径，Android 为 zip 文件名），文案由后端的 `describeCompletion`/`openActionLabel` 提供。
- 任务通过 `store.runCacheDownload` 注入剧情标识与 `CacheControl`，与缓存下载共享并发信号量；导出中仍可播放与浏览目录。
- 逐文件失败不中断整体，结束后汇总在结果页与 SnackBar；`manifest.json` 记录每个文件的实际写入路径、来源 URL、字节数与 sha256，以及失败项与未解析项。
- 去重键为「来源 URI + 目标路径」：同路径同来源只写一次，同一来源不同分类各写一份。
- 取消导出删除未完成的目录；关闭对话框后台继续，剧情行菜单显示「导出中 N%」，重开对话框挂接同一任务查看进度或结果。
- 该篇正在缓存时禁用导出，避免同一资源同时跑两条下载链路；导出进行中反向禁用清空缓存、迁移缓存目录、删除离线剧情与缓存页删除操作（`_hasActiveExports` 参与 guard 与按钮禁用），否则未读取的文件会在导出中途消失，离线导出随之失败。

## 平台边界

菜单入口与对话框由 `store.supportsExport` 统一控制（桌面 + Android），界面不散落平台判断。

- 桌面（Windows/macOS/Linux）：散文件导出到用户选择或默认拼接的目录，完成后可打开文件夹。
- Android：素材逐文件流式写入 zip 并通过系统分享面板保存，不申请存储权限、不写公共存储。zip 位于 `getTemporaryDirectory()` 下的 `方舟档案室导出/`，文件名 `章节_标题.zip`，同名追加 ` (2)` 序号；图片、音频与视频按后缀直接存储不二次压缩。分享由 `story_export/share` 通道（MainActivity `shareZip`）拉起，FileProvider 需暴露 cache-path（`res/xml/file_paths.xml`）；zip 随应用缓存可被系统回收，只能作为分享中转，不当作用户的持久副本。
- iOS 与 Web 暂不提供；接入时新增后端并扩展 `supportsExport` 与门面分发，不要在界面层散落平台判断。

导出对话框按可用宽度断点（`LayoutBuilder` 的 700）自适应：窄屏（手机竖屏）隐藏固定 176 的左侧分类栏，分类改为顶部横向标签、条目网格两列占满全宽，统计与全选/清空移入底栏；宽屏保持左侧分类 + 右侧网格的双栏布局。窄屏网格用固定行高而不是比例换算，固定 96 高的缩略图在窄列比例布局下会溢出；不要把双栏布局沿用到手机竖屏，否则右侧预览区会被挤成细条。

特效贴图随应用打包、多篇共用，不属于单篇剧情素材，导出清单不包含；不要为「导出完整演出素材」悄悄扩大 `collect` 的范围。

## 修改后的验证

```sh
flutter test test/story_export_test.dart test/story_export_page_test.dart
flutter test test/data_test.dart test/product_ui_test.dart
```

重点覆盖：BGM 与立绘合并、`collect` 与 `dependencies` 投影一致、已缓存条目导出发起的网络请求数、单文件失败不中断、取消清理目录、重名目录序号、试听切歌与后端广播流契约、桌面/Android 菜单与底栏入口差异、Android zip 后端（条目名清洗、manifest 在包内、分享调用、取消清理、序号）。跨平台构建按当前环境验证并在提交说明记录未验证的平台。

历史依据：音频逐段编码修复（`#retro` 等）先于导出功能从特效分支移植至 main，属于导出与缓存下载的共同前提；如重新实现音频映射，须保持 `Uri.encodeComponent` 逐段编码语义。
