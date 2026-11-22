import 'package:flutter/widgets.dart';

import '../script.dart';

/// 剧情内嵌视频输出接口；与 [StoryAudio] 同构，便于测试注入静音实现。
///
/// 参考语义对齐 PRTS 生产播放器（StoryPlayer.DH9HUkmm.js，2026-11 审计版）：
/// `url` 优先、`res` 次之；播放为全屏黑底覆盖层，阻塞指令队列直到
/// 播放结束或出错；出错记录警告并继续，不让整篇剧情停摆。
abstract class StoryVideo {
  /// 执行 [Video] 指令；resolve 负责把 `url`/`res` 映射为可播放地址。
  /// 实现应在播放自然结束、失败或被 [stop] 中断后返回，不抛出异常。
  Future<void> execute(StoryCommand command);

  /// 输出通道是否正在播放；引擎据此向 StageState 写入渲染状态。
  bool get active;

  /// 供 UI 渲染的画面覆盖层；无画面（Noop/无平台实现）时返回 null。
  Widget? buildSurface();

  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> dispose();
}

/// 无画面实现：记录一次警告后立即返回，剧情继续。
class NoopStoryVideo implements StoryVideo {
  NoopStoryVideo({this.reason = '当前平台暂不支持剧情内嵌视频播放，已跳过', this.onWarning});

  final String reason;

  /// 可变：引擎默认实例在构造完成后晚绑定（构造期拿不到 this.warn），
  /// UI 显式注入时则通过构造参数传入。
  void Function(String message)? onWarning;

  @override
  Future<void> execute(StoryCommand command) async {
    onWarning?.call('第 ${command.line} 行：$reason');
  }

  @override
  bool get active => false;

  @override
  Widget? buildSurface() => null;

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
