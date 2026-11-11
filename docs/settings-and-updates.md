# 设置、应用更新与发行

本文是设置、关于页面和应用更新的维护文档，保留偏好存储、平台差异及发布产物与客户端的约定。缓存目录和清理行为见 [asset-cache.md](asset-cache.md)，观看进度见 [story-player.md](story-player.md)。用户安装说明继续维护在 `README.md`。

## 代码入口与设置存储

| 位置 | 职责 |
| --- | --- |
| `lib/app/settings_page.dart` | 播放偏好、缓存设置、关于、版本检查和更新操作 |
| `lib/story_player/data/playback_settings.dart` | 偏好默认值、JSON 解析及范围校验 |
| `lib/story_player/data/asset_store.dart` | 设置和观看进度持久化、串行写入 |
| `lib/app/app_update.dart` | 项目链接、Release API、版本比较、下载与取消 |
| `lib/app/app_update_io.dart`、`lib/app/app_update_stub.dart` | 下载路径、Android ABI 探测及平台文件操作 |
| `.github/workflows/build.yml` | 构建矩阵、签名、产物与 tag 发布 |
| `packaging/windows/installer.iss`、`packaging/linux/package.sh` | Windows 安装器与 Linux 包装 |

播放设置默认值为总音量 0.8、BGM 0.75、音效 0.85、自动等待 2 秒、打字间隔 40ms。读取时校验有限数值，音量限制在 0–1，自动等待为 1–5 秒，打字间隔为 10–80ms；无效字段回退默认值。新增字段必须保持旧 JSON 可读，并同步默认值、界面和序列化。

本地记录借用 `FileCache` 的 URI 键存储，并非真正发往这些地址的接口：

| 键 | 内容 |
| --- | --- |
| `https://local.invalid/story-cache-settings` | 下载并发设置 |
| `https://local.invalid/story-playback-settings-v1` | 播放偏好 |
| `https://local.invalid/story-playback-progress-v1` | 各篇观看断点 |
| `https://local.invalid/story-mobile-data-approved-v1` | 移动数据批准状态 |

这些记录在清空媒体缓存时保留，目录迁移要等待已有写入。不能只改 URI 的版本后缀而不处理旧数据。原生目录配置另外保存在 `story_cache_directory.json`；Web 不提供目录操作。关于页中的项目、反馈和发布链接由 `AppUpdateLinks` 集中定义，仓库地址变更时一起检查 API 地址和外部链接。

## 检查更新与下载流程

`PackageInfo` 提供当前应用版本，`AppUpdateClient.check` 请求 GitHub `repos/<仓库>/releases/latest`，超时为 15 秒；解析 tag 后使用 `compareVersions` 比较版本。更新判断依据版本值，不能按字符串字典序比较，也不按发布时间判断。

产物匹配依赖文件名：

- Android 先筛选 `-android-`，通过 `getprop ro.product.cpu.abilist` 选择支持的 ABI，再优先匹配 `-<abi>.`。找不到时回退 universal，再考虑唯一候选；探测失败同样优先 universal。
- Windows 和 Linux 分别筛选 `-windows-`、`-linux-`，目前仅在候选唯一时直接选中。候选为多个架构或包格式时转到发布页面，不会自动判断桌面 CPU 架构或安装格式。
- Web 展示所有产物；未定义发布产物的平台转到发布页面。新增平台必须同步 `_assetPlatformToken`、产物选择和工作流。

只有桌面端支持应用内下载，其余交给外部浏览器。桌面下载以 `.part` 临时文件流式写入，完成后生成目标文件；取消清理临时文件。建连超时为 30 秒。完成后可定位文件，使用 Windows Explorer、macOS `open` 或 Linux `xdg-open`；当前没有自动安装或静默替换流程。

更新服务依赖 GitHub API 与下载地址可用。解析失败、网络异常、取消和目标文件冲突应保持可重试，不能把失败显示成「已是最新版本」。UI 销毁后异步返回也不能继续更新已释放状态。

## 发行约定与现有限制

当前工作流固定 Flutter 3.47.9；构建环境要求同时检查 `pubspec.yaml` 的 Dart 约束和锁文件，不自动升级依赖。Windows 的 `just_audio_windows` 固定在 Git 提交，升级时要单独验证真实音频播放。

推送 tag 触发构建，Android、Windows、Linux x64 和 Linux arm64 全部成功后发布该 tag 的 GitHub Release；发布说明优先读取 `.github/release-notes/<tag>.md`。当前工作流没有 macOS 或 iOS 发行任务，不将源码平台目录写成已有安装包承诺。

- Android 同时构建分 ABI APK 和 universal APK，使用固定上传密钥签名并校验；分 ABI 构建使用 `--split-per-abi -P force-version-code-ignoring-abi=true`。安装包升级还取决于 application ID、签名和版本码，不能只增加展示版本。
- Windows 发布完整便携 ZIP 和 Inno Setup 安装器，便携版包含运行所需 DLL 与数据，不能只分发 EXE。
- Linux 分别构建 x64 和 arm64，包格式由 `packaging/linux/package.sh` 决定。修改包装后运行 `bash packaging/linux/package_test.sh`，并在对应系统验证安装与桌面入口。
- 客户端匹配文件名与工作流必须一起维护。当前 Android x86_64 产物名使用 `-android-x64.apk`，ABI 匹配器寻找 `-x86_64.`，因而会退到 universal；这是现有限制，后续修复需覆盖命名与选择测试。

版本来源为 `pubspec.yaml` 的 `version: <展示版本>+<构建号>`。发布时核对 tag、展示版本、Android 版本码和产物名一致，不能仅凭旧文档推断真实 Release 已上传的文件。Android 当前还通过 `-P force-version-code-ignoring-abi=true` 保持各 ABI 版本码一致；改动时检查 Android 工程和工作流的配合。

## 修改后的验证

```sh
flutter test test/settings_platform_test.dart test/settings_about_test.dart test/app_update_test.dart
```

偏好改动还需回归 `test/data_test.dart`，检查重启读取、无效 JSON 和清空缓存后保留。更新改动覆盖相等/新旧版本、无可用产物、多个候选、ABI 探测失败、下载取消与错误恢复。静态测试不能替代设备上的外部浏览器、打开文件和 Android 同签名升级验收。

历史入口：`2a74af6` 引入关于与更新，`1834c44` 调整 Android 更新体验。真实产物名称始终以工作流、包装脚本及实际 Release 为准；变更后同步用户首页对应说明。
