# 设置、应用更新与发行

本文是设置、关于页面和应用更新的维护文档，保留偏好存储、平台差异及发布产物与客户端的约定。缓存目录和清理行为见 [asset-cache.md](asset-cache.md)，观看进度见 [story-player.md](story-player.md)。用户安装说明继续维护在 `README.md`。

## 代码入口与设置存储

| 位置 | 职责 |
| --- | --- |
| `lib/app/settings_page.dart` | 播放偏好、缓存设置、关于、版本检查和更新操作 |
| `lib/story_player/data/playback_settings.dart` | 偏好默认值、JSON 解析及范围校验 |
| `lib/story_player/data/asset_store.dart` | 设置和观看进度持久化、串行写入 |
| `lib/app/app_update.dart` | 项目链接、Release API 与订阅备用通道、版本比较、代理多源下载、sha256 校验与取消 |
| `lib/app/app_update_io.dart`、`lib/app/app_update_stub.dart` | 下载路径、Android ABI 探测、sha256 计算、平台文件操作与 Android 安装通道 |
| `.github/workflows/build.yml` | 构建矩阵、签名、产物与 tag 发布 |
| `packaging/windows/installer.iss`、`packaging/linux/package.sh` | Windows 安装器与 Linux 包装 |

播放设置默认值为总音量 0.8、BGM 0.75、音效 0.85、自动等待 2 秒、打字间隔 40ms。读取时校验有限数值，音量限制在 0–1，自动等待为 1–5 秒，打字间隔为 10–80ms；无效字段回退默认值。新增字段必须保持旧 JSON 可读，并同步默认值、界面和序列化。

外观主题保存在同一份偏好 JSON 的 `lightTheme` 字段中；缺失、无效或为 `false` 时使用原有暗色，`true` 时使用明亮色。加载偏好及切换设置后更新应用主题，清空素材缓存时保留该字段。剧情演出画面保留独立配色。

设置入口按“基础设置”“缓存设置”“网络设置”“关于”排列。基础设置集中主题、音频和演出速度；网络设置仍在进入时自动检测。

本地记录借用 `FileCache` 的 URI 键存储，并非真正发往这些地址的接口：

| 键 | 内容 |
| --- | --- |
| `https://local.invalid/story-cache-settings` | 下载并发设置 |
| `https://local.invalid/story-playback-settings-v1` | 播放偏好 |
| `https://local.invalid/story-playback-progress-v1` | 各篇观看断点 |
| `https://local.invalid/story-mobile-data-approved-v1` | 移动数据批准状态 |

这些记录在清空媒体缓存时保留，目录迁移要等待已有写入。不能只改 URI 的版本后缀而不处理旧数据。原生目录配置另外保存在 `story_cache_directory.json`；Web 不提供目录操作。关于页中的项目、反馈和发布链接由 `AppUpdateLinks` 集中定义，仓库地址变更时一起检查 API 地址和外部链接。

## 检查更新与下载流程

`PackageInfo` 提供当前应用版本，`AppUpdateClient.check` 先请求 GitHub `repos/<仓库>/releases/latest`，超时为 15 秒；解析 tag 后使用 `compareVersions` 比较版本。更新判断依据版本值，不能按字符串字典序比较，也不按发布时间判断。

主通道失败时自动改用 Release Atom 订阅（`releases.atom`）备用通道：HTTP 403（匿名限流，常见于代理/VPN 共享出口 IP）、超时或网络异常都会切换，用户无需关闭代理重试；404（尚未发布）与版本号缺失属于确定结论，不再重试。备用通道从发布链接提取完整版本标签并跳过非版本条目，只提供标签与说明，下载链接按工作流产物命名约定（`arknights_story_player-v<版本>-<平台>-<架构>.<扩展>`）构造，命名规则变化必须与 `.github/workflows/build.yml` 一起维护；该路径资产没有大小与 sha256，进度依赖响应 Content-Length。两个通道都失败时合并双方错误提示。

产物匹配依赖文件名：

- Android 先筛选 `-android-`，通过 `getprop ro.product.cpu.abilist` 选择支持的 ABI，再优先匹配 `-<abi>.`。找不到时回退 universal，再考虑唯一候选；探测失败同样优先 universal。
- Windows 筛选 `-windows-`，同时发布便携 ZIP 与 `-setup.exe` 安装器时展示两者；仅有一个候选时直接选中，否则转到发布页面，不自动判断桌面 CPU 架构。
- Linux 筛选 `-linux-`，候选为多个架构或包格式时转到发布页面。
- Web 展示所有产物；未定义发布产物的平台转到发布页面。新增平台必须同步 `_assetPlatformToken`、产物选择和工作流。

应用内下载覆盖 Android 与桌面端，iOS 与 Web 交给系统浏览器。GitHub API 提供 `digest` 时，GitHub 下载地址依次经过 `githubProxyPrefixes` 中的公开加速代理，全部失败后直连兜底；每次下载完成后先校验 sha256 再落盘。没有 sha256 的资产（包括 Atom 备用通道构造的资产）不经过公开代理，直接从原始地址下载。非 GitHub 地址单源直连。单源失败（HTTP 错误、连接或传输异常、建连 15 秒超时、空闲 30 秒无数据、sha256 不一致）自动换下一个源，全部源失败才报错并清理临时文件。下载按 256 KB 或 200ms 粒度汇报进度，界面再按 3 秒滑动窗口计算速度与剩余时间并显示当前下载源。换源时重置统计，从头下载。

- Android 下载到应用专属外部目录（无公共下载目录写权限，`UpdateFileStore.downloadDirectory` 回退 FileProvider 可访问的应用内部支持目录），完成后自动拉起系统安装器，也可手动点「安装」；需要 `REQUEST_INSTALL_PACKAGES` 权限与 FileProvider（路径配置 `@xml/update_file_paths`），安装通道为 MainActivity 的 `app_update/install` MethodChannel，首次安装需「未知来源」授权，失败时保留手动按钮兜底。
- Windows 下载到系统下载目录，`-setup.exe` 可直接「运行安装程序」（Inno Setup 为 per-user 安装，无需管理员）；便携 ZIP 保持手动解压。
- 下载完成后的重试、换源与取消都必须保持可重试；UI 销毁后异步返回不能继续更新已释放状态。

更新服务依赖 GitHub API 与下载地址可用。解析失败、网络异常、取消和目标文件冲突应保持可重试，不能把失败显示成「已是最新版本」。

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

偏好改动还需回归 `test/data_test.dart`，检查重启读取、无效 JSON 和清空缓存后保留。更新改动覆盖相等/新旧版本、无可用产物、多个候选、ABI 探测失败、下载取消与错误恢复，以及备用通道、代理多源回退、sha256 校验与下载源提示。静态测试不能替代设备上的系统安装器、真实代理连通、打开文件和 Android 同签名升级验收。

历史入口：`2a74af6` 引入关于与更新，`1834c44` 调整 Android 更新体验。真实产物名称始终以工作流、包装脚本及实际 Release 为准；变更后同步用户首页对应说明。
