<div align="center">

<img src="assets/branding/arkarchive.png" alt="方舟档案室图标" width="192" height="192" />

# 方舟档案室

**ArkArchive**

一款用于浏览和播放《明日方舟》剧情的非官方同人应用。

![Flutter](https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-0175C2?logo=dart&logoColor=white)
![平台](https://img.shields.io/badge/平台-Android%20%7C%20Windows%20%7C%20Linux-555555)
![许可证](https://img.shields.io/github/license/horizonzzzz/arknights-story-player)
![Release](https://img.shields.io/github/v/release/horizonzzzz/arknights-story-player)

[下载应用](https://github.com/horizonzzzz/arknights-story-player/releases) · [反馈问题](https://github.com/horizonzzzz/arknights-story-player/issues)

</div>

## 功能

- 按分类浏览，搜索篇章、关卡和剧情标题。
- 播放剧情演出，支持自动播放、分支选择、音量和播放速度设置。
- 下载剧情及相关素材，支持离线观看和缓存管理。

剧情目录、脚本和素材通过网络按需加载。首次浏览或下载需要联网；已下载内容可离线观看，缓存被系统清理后需要重新下载。

## 下载与安装

从 [GitHub Releases](https://github.com/horizonzzzz/arknights-story-player/releases) 下载与设备匹配的最新版本。每次正式 Release 由一个版本 tag 对应，文件名中的平台和架构用于选择安装包。

### Android

- `arknights_story_player-android-universal.apk`：通用 APK，适合不确定设备架构时使用。
- `arknights_story_player-android-arm64-v8a.apk`：大多数现代 Android 设备。
- `arknights_story_player-android-armeabi-v7a.apk`：32 位 ARM 设备。
- `arknights_story_player-android-x64.apk`：x86_64 Android 设备。

在 Android 设置中允许安装来自此来源的应用，然后打开对应 APK 完成安装。不同架构的 APK 不能混用。

### Windows x64

- `arknights_story_player-windows-x64-setup.exe`：安装版，推荐普通用户使用。
- `arknights_story_player-windows-x64.zip`：便携版，解压后运行 `arknights_story_player.exe`。

### Linux

x64 和 ARM64 各提供以下三种格式：

- `arknights_story_player-linux-x64.deb` / `arknights_story_player-linux-arm64.deb`：适用于 Debian、Ubuntu 及其衍生发行版，可使用系统包管理器安装。
- `arknights_story_player-linux-x64.AppImage` / `arknights_story_player-linux-arm64.AppImage`：下载后赋予执行权限，直接运行。
- `arknights_story_player-linux-x64.tar.gz` / `arknights_story_player-linux-arm64.tar.gz`：解压后运行 `arknights_story_player`，适合不使用 DEB 的发行版。

Linux 包依赖系统提供的 GTK、GLib、libstdc++ 等运行库，实际兼容性取决于发行版环境。AppImage 也不保证在所有发行版上都能运行。

### 当前不提供

当前 Release 不提供 iOS 和 macOS 版本。

## 版本与兼容性

Android Release 目前使用开发签名，后续版本可能无法覆盖安装旧版本；Windows 安装包目前未配置代码签名，系统可能显示安全提示。正式安装前请备份本地数据，并从本项目的 GitHub Releases 下载文件。

## 鸣谢与声明

- [PRTS](https://prts.wiki/)：提供剧情索引及相关数据资源。
- [鹰角网络](https://www.hypergryph.com/)：创作《明日方舟》及其游戏内容。

本项目为非官方同人项目，与鹰角网络无从属或合作关系。《明日方舟》及其剧情、角色、图像、音乐等游戏资源的版权归鹰角网络所有。

## 许可证

本项目代码采用 [MIT License](LICENSE) 开源。游戏资源及其他第三方资源不属于该许可范围，其权利与使用条款由各自权利人决定。
