import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../data/asset_store.dart';
import '../data/media_catalog.dart';
import '../script.dart';
import 'story_video.dart';
import 'video_player_factory.dart';

/// 剧情内嵌视频输出：官方 `video_player` 平台实现（Android ExoPlayer /
/// iOS AVPlayer / macOS / Web）。
///
/// 语义对齐参考端 VideoPanel（StoryPlayer.DH9HUkmm.js）：
/// - 播放为全屏黑底覆盖层，视频按原始比例居中；
/// - [execute] 阻塞指令队列，直到播放自然结束、失败或被 [stop] 中断；
/// - 失败只记录警告并结束，不让剧情停摆（替代参考端启动时的 HEAD
///   缺失探测：缺失资源在 initialize 阶段报错，行为等价且少一个请求）；
/// - 播放期间会话标识防止旧请求复活（参考端 ++sessionId）。
class VideoPlayerStoryVideo implements StoryVideo {
  VideoPlayerStoryVideo(this.catalog, this.assets, {this.onWarning});

  final MediaCatalog catalog;
  final AssetStore assets;
  final void Function(String message)? onWarning;

  VideoPlayerController? _controller;
  Completer<void>? _completer;
  int _session = 0;
  bool _paused = false;
  bool _disposed = false;
  final _active = ValueNotifier<bool>(false);

  @override
  bool get active => _active.value;

  @override
  Future<void> execute(StoryCommand c) async {
    if (_disposed) return;
    final url = c.value('url');
    final res = c.value('res');
    final uri = catalog.video(url, res);
    if (uri == null) {
      onWarning?.call('第 ${c.line} 行：video 缺少 url 或 res 参数');
      return;
    }
    await play(uri, line: c.line);
  }

  Future<void> play(Uri uri, {int line = 0}) async {
    await _teardown();
    if (_disposed) return;
    final session = _session;
    final completer = Completer<void>();
    _completer = completer;
    Uri? source;
    try {
      // 缓存命中时使用本地文件或 Web Blob URL，未命中才回退网络流播。
      final cached = await assets.playableVideoUri(uri);
      source = cached.scheme == 'file' || cached.scheme == 'blob'
          ? cached
          : uri;
      if (session != _session) return;
      final controller = createVideoController(source);
      _controller = controller;
      _active.value = true;
      void finish() {
        if (!completer.isCompleted) completer.complete();
      }

      controller.addListener(() {
        final value = controller.value;
        if (value.hasError) {
          onWarning?.call('视频播放失败：${value.errorDescription ?? uri}');
          finish();
        } else if (
        // 官方完成状态（VideoEventType.completed → isCompleted），
        // 无容差不截片尾；到达时长的兜底判定保留为双保险。
        value.isCompleted ||
            (value.isInitialized &&
                value.duration > Duration.zero &&
                value.position >= value.duration)) {
          finish();
        }
      });
      try {
        await controller.initialize();
        if (session != _session) return;
        // 初始化异常、未就绪或无时长都可能既不播放也不触发完成事件，
        // 这里全部结束等待，避免指令队列永久卡住。
        if (!controller.value.isInitialized ||
            controller.value.duration == Duration.zero) {
          onWarning?.call('第 $line 行：video 无法播放 $uri（初始化未就绪）');
          return;
        }
        // 仅在没有暂停意图时开播；初始化期间切后台/暂停的意图不丢。
        if (!_paused) {
          await controller.play();
        }
      } catch (e) {
        onWarning?.call('第 $line 行：video 无法播放 $uri（$e）');
        return;
      }
      await completer.future;
    } finally {
      if (session == _session) {
        _completer = null;
        _paused = false;
        _active.value = false;
        final controller = _controller;
        _controller = null;
        await controller?.dispose();
      }
      assets.releaseVideoSource(source ?? uri);
    }
  }

  /// 中断当前播放并释放控制器；参考端 stop() 语义。
  Future<void> _teardown() async {
    _session++;
    final completer = _completer;
    _completer = null;
    _active.value = false;
    _paused = false;
    final controller = _controller;
    _controller = null;
    if (completer != null && !completer.isCompleted) completer.complete();
    if (controller != null) await controller.dispose();
  }

  @override
  Future<void> pause() async {
    // 意图式暂停：控制器尚未创建（下载/初始化窗口）时仅记录意图，
    // 待就绪后不自动开播，由 resume 清除。
    if (_paused) return;
    _paused = true;
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.pause();
    } catch (_) {
      // 控制器并发销毁时静默；播放会话已结束。
    }
  }

  @override
  Future<void> resume() async {
    // 意图式恢复：控制器尚未创建时清除暂停意图，初始化完成后照常开播。
    if (!_paused) return;
    _paused = false;
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.play();
    } catch (_) {
      // 同上，不中断剧情推进。
    }
  }

  @override
  Future<void> stop() => _teardown();

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _teardown();
  }

  @override
  Widget? buildSurface() => _VideoSurface(video: this);
}

/// 视频画面覆盖层：黑底全屏，视频按原始比例居中（参考端 DOM video 的
/// object-fit: contain 行为）。active 变化时自动挂载/卸载。
class _VideoSurface extends StatelessWidget {
  const _VideoSurface({required this.video});

  final VideoPlayerStoryVideo video;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: video._active,
    builder: (context, active, _) {
      final controller = active ? video._controller : null;
      if (controller == null) return const SizedBox.shrink();
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.isInitialized
                ? AspectRatio(
                    aspectRatio: value.aspectRatio == 0
                        ? 16 / 9
                        : value.aspectRatio,
                    child: VideoPlayer(controller),
                  )
                : const SizedBox.expand(),
          ),
        ),
      );
    },
  );
}
