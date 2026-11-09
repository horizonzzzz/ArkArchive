# TTS 首版验证记录

本记录对应 `feat/tts` 分支的本地对白朗读实现。首版采用 sherpa-onnx 2.0.1 与 Kokoro v1.1 多语言 INT8，语音默认关闭。长句切段、下一句预合成和角色独立模型包仍属于后续范围。

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

官方 GitHub 下载在本机发生连接重置和超时；真实合成验证所用文件从相同模型仓库的镜像取得。应用运行时仍使用官方 GitHub Release 下载地址及官方资产 API 备用地址，整包校验使用已核对的 SHA-256。

## 验证边界

- 已验证 Windows 构建、真实模型合成和 WAV 样本；尚未完成从应用内下载真实完整压缩包、安装、扬声器试听的完整人工流程。
- Android 与 Linux 已接入相同实现，但本次没有对应设备或构建环境的验证结果。
- Web、macOS 和 iOS 本轮不启用本地 TTS。
- pi-lens 的主动 Dart 检查超时，未提供有效结论；静态检查结论来自实际执行的 `flutter analyze`。

模型与映射存放于应用支持目录的 `voice_packs`，独立于剧情缓存。删除模型保留角色映射；安装和启动时检查完整性。默认包下载大小为 147,052,523 字节。
