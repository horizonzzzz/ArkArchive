# TTS 首版验证记录

本记录对应 `feat/tts` 分支的本地对白朗读实现。首版采用 sherpa-onnx 2.0.1 与 Kokoro v1.1 多语言 INT8，语音默认关闭。长句切段、下一句预合成和角色独立模型包仍属于后续范围。

## 2026-11-09 墙补：下载改为国内镜像多源

GitHub Release 下载在本机持续连接重置与超时，下载链路改为 hf-mirror 国内镜像优先、HuggingFace 官方兑底，按文件逐个拉取（不再下载/解压 tar.bz2 整包，`archive` 依赖已移除）：

- `flutter analyze --no-pub`：通过，无问题；
- `flutter test`：261 项通过，2 项跳过（新增镜像换源、篡改丢弃重下、细粒度续传、断点重启恢复、安装阶段 .part 清理等测试）；
- 真实网络验证：对 `hf-mirror.com/csukuangfj/kokoro-int8-multi-lang-v1_1` 的 resolve 链路实测——小文件 200；Range 请求返回 206 且 `content-range` 格式与实现一致（如 `bytes 100-1110/1111`，total 与清单吻合）；`number-zh.fst` 完整下载 sha256 与硬编码清单一致；
  - `model.int8.onnx`（114 MB LFS）经 hf-mirror 302 跳转到 HF 官方 CDN（us.aws.cdn.hf.co），Range 头在跳转后保留，206 与 total=114,203,914 与清单一致，本机可达。hf-mirror 对该大文件为跳转而非中转，实际加速效果取决于用户网络对 HF CDN 的连通性；若镜像体验不佳，可在 `downloadHosts` 清单中补充其他源（多源结构无需改动逻辑）；
- 默认包改为 8 个散文件共 176,285,027 字节（约 176 MB），哈希来源：LFS 文件为 HuggingFace 仓库 git-lfs oid（上游权威 sha256），小文件为镜像实测；任何源返回内容与哈希不符即丢弃 .part 自动换下一源。

## 自动检查

- `flutter analyze --no-pub`：通过，无问题。
- `flutter test --reporter expanded`：258 项通过，2 项跳过。
- `flutter build windows --debug --no-pub`：Windows Debug 构建通过，包含 sherpa-onnx 原生库。
- `git diff --check`：通过。

新增测试覆盖语音完成前自动播放等待、切句打断、迟到结果隔离、快进静音、暂停恢复、合成失败后继续播放、设置兼容、角色音色稳定映射、WAV 编码、下载续传与响应校验、损坏安装记录、文件篡改、窄屏控制中心、下载确认及试听门控。原有测试同步验证诊断迁至设置页，以及进入后台暂停、返回前台恢复。

## Windows 真实模型合成

使用与默认包对应的 `model.int8.onnx`、`voices.bin`、`tokens.txt`、中文与英文词典，直接运行生产代码中的 `VoiceSynthesisWorker`：

| 项目 | 结果 |
| --- | --- |
| 音色 3，中文句子 | 203,030 字节 WAV；首次加载加合成约 5,368 ms |
| 音色 58，另一中文句子 | 155,402 字节 WAV |
| 第一段音频 | 24 kHz、单声道 PCM16，约 4.229 秒 |
| 第一段样本 | 峰值 14,720，均方根约 2,335，确认包含非静音样本 |
| worker 退出 | 收到释放确认，正常结束 |

命令行首次验证误载了系统 ONNX Runtime 1.17.1，出现 `The requested API version [28] is not available` 并导致原生崩溃。验证脚本预载 Windows 构建产物随附的 `onnxruntime.dll` 后，两次合成都通过。Flutter Windows 构建会将该库与应用一起分发。

官方 GitHub 下载在本机发生连接重置和超时，因此本记录中的真实合成验证文件从镜像取得；后续下载链路已整体切换为「hf-mirror 镜像优先 + HuggingFace 官方兑底」的散文件方案（见顶部增量记录），不再依赖 GitHub。

## 验证边界

- 已验证 Windows 构建、真实模型合成和 WAV 样本；尚未完成从应用内下载真实完整压缩包、安装、扬声器试听的完整人工流程。
- Android 与 Linux 已接入相同实现，但本次没有对应设备或构建环境的验证结果。
- Web、macOS 和 iOS 本轮不启用本地 TTS。
- pi-lens 的主动 Dart 检查超时，未提供有效结论；静态检查结论来自实际执行的 `flutter analyze`。

模型与映射存放于应用支持目录的 `voice_packs`，独立于剧情缓存。删除模型保留角色映射；安装和启动时检查完整性。默认包8 个文件合计 176,285,027 字节（原 tar.bz2 整包 147,052,523 字节的方案已移除）。

> AI生成
