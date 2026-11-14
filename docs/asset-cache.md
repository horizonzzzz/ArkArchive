# 资源映射与离线缓存

本文是资源加载、独立剧情缓存和目录迁移的维护文档。剧情入口见 [story-library.md](story-library.md)，演出与音频消费见 [story-player.md](story-player.md)，偏好与更新见 [settings-and-updates.md](settings-and-updates.md)。

## 代码入口与资源映射

| 位置 | 职责 |
| --- | --- |
| `lib/story_player/data/media_catalog.dart` | `MediaCatalog`、图片和音频映射、静态依赖扫描 |
| `lib/story_player/data/asset_store.dart` | `AssetStore`、内存与持久缓存、并发请求、重试和偏好存储 |
| `lib/story_player/data/story_repository.dart` | 单篇下载事务、完整缓存索引、删除与清空 |
| `lib/story_player/data/file_cache.dart`、`lib/story_player/data/file_cache_io.dart`、`lib/story_player/data/file_cache_web.dart` | 平台后端选择、原生文件与 Web CacheStorage |
| `lib/story_player/data/cache_control.dart` | 暂停、恢复与取消检查点 |
| `lib/app/cache_job.dart`、`lib/app/cache_page.dart` | 任务状态与缓存管理界面 |
| `lib/app/story_launcher.dart` | 任务队列、网络确认、目录操作和播放作用域 |

`MediaCatalog` 通过共享缓存加载 `story_variables.json`、`assets/avg/character.json` 和 `assets/avg/background.json`。资源基础地址为 `https://torappu.prts.wiki/assets/`，背景在 `avg/background/`，CG 在 `avg/images/`；立绘按元数据拼接路径并逐段编码。切入图使用 `media.prts.wiki` 的文件名及 MD5 分桶规则，不能把所有图片统一拼成一个目录。

音频支持 `$` 变量、大小写回退、完整 HTTP 地址和 `@` 资产路径；`Sound_Beta_2/` 映射为小写的 `assets/audio/` MP3 地址，路径须逐段编码，避免 `#retro` 等名称被解析为 URI 片段。新增指令或资源形式时，同时修改依赖扫描与运行时映射，检查变量解析、中文 URL、表情差分和前奏/循环体。

## 共享资源与独立剧情

共享缓存用于在线试看、元数据和人物图片；显式下载的每一篇剧情拥有完整脚本与演出资源，即使不同剧情使用同一 URL，也应能独立删除和离线播放。

- `AssetStore.loadShared` 固定访问共享层；普通 `load` 读取当前剧情作用域。`runCacheDownload` 使用 Zone 传递下载、控制器与剧情标识，优先于全局 `playbackScope`。
- 显式剧情下载绕过共享内存命中及共享文件回退，保证该篇目录实际写全。不能因为资源曾在线播放或被另一篇缓存，就省略当前篇目的资源写入。
- 请求合并键包含 URI、共享/剧情作用域和下载控制上下文，不能只按 URL 合并，否则并行下载会串用暂停/取消状态或漏写另一篇目录。
- 默认并发为 4。网络异常、超时、429 和服务端错误采用有限重试；取消应立即退出，不应无限重试。
- 拒绝空响应及伪装成图片、音频、JSON 或文本的 HTML 错误页。写磁盘失败必须进入预加载错误，不能把内存加载成功视为持久化成功。

## 完整缓存的提交与删除

`StoryRepository.cacheEntry` 先撤销旧的完整标记，再加载脚本、映射表和全部静态依赖。目录索引与映射表写共享层，脚本与剧情资源写入该篇目录。只有没有 warnings、预加载错误且未被取消时，才提交完整缓存索引；失败或取消会删除本次未完成的剧情资源。

完整索引写入由 `_indexWrite` 串行化，`_activeDownloads` 阻止同篇重复下载。单篇删除先撤标记、再删资源；清空先撤全部标记，再清文件。调整顺序时防止出现「界面显示已缓存、文件已缺失」。单篇完整不代表所有动态效果均已实现，指令支持范围仍由播放器决定。

首批火焰与烟雾的 `fx.json` 和主贴图随应用打包在 `assets/fx-runtime/`，由 Flutter `rootBundle` 离线读取；它们不占用单篇剧情缓存，删除剧情缓存也不会删除打包特效。开发时可用 `STORY_FX_ROOT` 覆盖为外部目录，外部资源仍未进入 `cacheEntry` 的依赖扫描和完成标记；“已完整缓存”不保证这些覆盖资源可离线使用。资源目录与转换步骤见 [剧情播放器](story-player.md#解包资源驱动的粒子特效)。

完整索引同时保存剧情标题、章节和分类，缓存页面只依赖这些本地记录。旧版字符串路径索引仍可读取：优先使用本地目录补全并写回元数据，匹配不到的路径仍作为未分组条目保留；删除和清空操作同时移除对应记录。

清空媒体缓存保留目录所需数据，以及缓存并发、播放偏好、观看进度和移动数据许可等本地记录。人物包内文本不属于媒体缓存；人物图片使用共享层，清空媒体缓存后可按需重新请求。

## 任务与移动网络

`CacheJob` 状态为 `waiting`、`downloading`、`paused`、`completed`、`failed` 和 `cancelled`。已有队列可追加任务；暂停、恢复和取消通过 `CacheControl` 检查点传递，不只是修改界面状态。全部任务结束后断开网络订阅、释放资源内存并刷新统计。

移动端在尚未批准移动数据时检查连接：存在移动网络，或无法确认 Wi-Fi/以太网时请求确认；并发任务共用一次确认，网络变化时重新检查。批准可持久保存，拒绝不持久保存，并取消等待、下载及暂停中的任务。不要在任务尚未结束时销毁共用控制器或网络监听。

## 平台存储与目录迁移

原生默认使用应用支持目录下的 `story_assets/`：共享资源在 `_shared/`，单篇在 `stories/<剧情标识 SHA-256>/`。文件名是完整 URI 的 SHA-256 加原扩展名，无扩展名用 `.bin`。同一资源与剧情的写入串行化，临时文件写完后重命名；读取默认允许剧情层回退共享层，显式离线下载除外。

目录设置记录在 `story_cache_directory.json`。选择的目录是父目录，实际使用其中的 `story_assets/`；迁移流程为复制到临时目录、重命名目标、原子更新配置、切换后端。已有目标不覆盖，失败回滚临时/目标目录，原目录保留。存在在途请求时禁止迁移或清空，切换前等待设置写入；不能仅更新路径字符串而留下后台写入旧目录。

macOS 通过 `story_cache_directory` MethodChannel 保存和恢复安全书签。Windows 本地音频对非 ASCII 路径有兼容性风险，入口对任意非 ASCII 字符提示；即使资源文件名已哈希，父目录含中文仍可能触发。原生音频用文件 URI，保留正确编码，不手工拼接 `file://` 字符串。

Web 使用持久的 CacheStorage：共享缓存名为 `story-assets-v1`，每篇为 `story-<SHA-256>-v1`，删除单篇会删除对应 Cache。音频使用 data URI。Web 不提供本地目录路径、选择或迁移，不能沿用旧文档的「只有内存缓存」描述；浏览器存储仍可能被用户或浏览器回收。

## 修改后的验证

```sh
flutter test test/data_test.dart test/cache_page_test.dart test/cache_regression_test.dart test/file_cache_io_test.dart
flutter test --platform chrome test/web_cache_test.dart
```

Web 测试需要可用的 Chrome。涉及音频资源时可显式联网运行：

```sh
flutter test test/cache_audio_live_test.dart --dart-define=CACHE_AUDIO_LIVE=true
```

重点覆盖两篇共享相同 URL 的并行下载、在线试看与离线下载并行、写入失败、暂停后取消、删除一篇后另一篇仍可播放、迁移失败回滚，以及清空后设置和进度仍在。联网音频检查不替代真实平台的解码和播放验收。

历史入口：`a10f64d` 改为独立剧情存储，`3e8bab7` 分离下载与在线共享缓存，`19a887c` 修复并行缓存，`1fb8ab5` 改用 ASCII 文件名并提示路径风险。不要重新引入已移除的跨剧情资源引用计数来节省磁盘，除非先明确独立删除、并行下载和离线完整性的替代契约。
