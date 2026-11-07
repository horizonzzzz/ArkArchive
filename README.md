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

## 功能特性

- **丰富剧情分类与快速检索**：全面收录主线章节、活动、故事集、插曲及别传等剧情篇章；支持移动端滑动切页与全局关键词搜索，快速定位篇章、关卡代号与剧情标题；支持加载本地自定义脚本（.txt）直接播放。
- **高还原度剧情播放引擎**：高度还原原作视觉排版与剧场级演出效果；支持角色立绘切换、背景变换、动态遮罩着色器特效与黑屏转场；支持打字机逐字输出、自由旁白贴纸、倒计时计时器与分支剧情对话选择。
- **音频回放与播放控制**：完整支持 BGM 背景音乐与环境音、角色与剧情音效（SFX），提供主音量、BGM 与音效分立调节；支持自动播放（可自定义等待时长与打字速度）、长按快进（2、4、8、16 倍速）、历史对白记录回顾（Log）与全屏沉浸播放。
- **观看断点记忆**：分别自动保存每篇未看完剧情的进度，列表对存在进度的条目显示「继续观看」标识，进入播放器后点「从上次继续」可恢复到上次对白或选项；普通播放仍从头开始，清理离线资源会保留断点，断点失效时会提示且不清除记录，播完后自动清除。
- **按需加载与离线缓存管理**：剧本、图片及音频素材按需异步拉取；可在剧情条目菜单中逐条缓存离线资源，缓存页支持暂停、恢复或删除单个任务并显示失败原因；提供网络状态感知（移动网络下载提醒）、并发下载控制、桌面端自定义缓存目录，以及可视化缓存管理（随时查看占用空间并支持一键清理）。
- **多平台适配与一致体验**：跨平台原生支持 Android、Windows 与 Linux；统一的视效主题与动效规范，移动端支持底部导航毛玻璃质感与手势交互，桌面端提供便捷窗口操作体验。
- **关于与检查更新**：设置页的「关于」展示版本、开源信息与项目链接，可检查 GitHub 最新发布；桌面端可直接下载更新包到系统下载目录，移动端跳转浏览器获取安装包。

## 下载与安装

前往 [GitHub Releases](https://github.com/horizonzzzz/arknights-story-player/releases) 下载适合您设备的最新安装包（文件名已包含对应版本号）：

- **Android**：提供通用版及主流架构（ARM64、ARM32、x86_64）的 APK 安装包。
- **Windows (x64)**：提供快速安装包（Setup）与免安装便携包（Zip）。
- **Linux (x64 / ARM64)**：提供 DEB 安装包、开箱即用的 AppImage 以及独立 tar.gz 压缩包。

## 版本与兼容性

Android Release 从签名变更后的版本起使用固定密钥签名，可以直接覆盖安装；从更早的版本升级到该版本仍需卸载一次，本地缓存和观看断点会随之丢失。Windows 安装包未配置代码签名，系统可能显示安全提示。正式安装前请备份本地数据，并从本项目的 GitHub Releases 下载文件。

## 鸣谢与声明

- [PRTS](https://prts.wiki/)：提供剧情索引及相关数据资源。
- [鹰角网络](https://www.hypergryph.com/)：创作《明日方舟》及其游戏内容。

本项目为非官方同人项目，与鹰角网络无从属或合作关系。《明日方舟》及其剧情、角色、图像、音乐等游戏资源的版权归鹰角网络所有。

## 许可证

本项目代码采用 [MIT License](LICENSE) 开源。游戏资源及其他第三方资源不属于该许可范围，其权利与使用条款由各自权利人决定。
