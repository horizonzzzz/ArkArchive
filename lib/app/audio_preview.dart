import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// 试听后端抽象：生产使用 just_audio，测试注入假实现。
abstract class AudioPreviewBackend {
  Future<void> setSource(Uri uri);

  /// 开始播放。注意 just_audio 的 Future 在「播放结束、暂停或停止」时才
  /// 完成，调用方不得依赖它表示「已经出声」。
  Future<void> play();
  Future<void> pause();

  /// 播放位置流；切歌会取消旧订阅后重新订阅，必须是可重复
  /// 监听的广播流（just_audio 的 positionStream 即广播流）。
  Stream<Duration> get positions;
  void dispose();
}

class JustAudioPreviewBackend implements AudioPreviewBackend {
  final _player = AudioPlayer();

  @override
  Future<void> setSource(Uri uri) => _player.setUrl(uri.toString());
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Stream<Duration> get positions => _player.positionStream;
  @override
  void dispose() => _player.dispose();
}

/// 30 秒试听控制器：同一时间只播一项，切换自动停止上一项；
/// 旧请求在用户切歌或停止后不得重新出声。必须在界面销毁时 dispose。
class AudioPreviewController extends ChangeNotifier {
  AudioPreviewController({
    required this.resolveSource,
    AudioPreviewBackend? initialBackend,
  }) : _backend = initialBackend;

  static const limit = Duration(seconds: 30);

  /// 把资源地址解析为可播放地址（已缓存时是本地 file: URI）。
  final Future<Uri> Function(Uri uri) resolveSource;
  AudioPreviewBackend? _backend;
  AudioPreviewBackend get backend => _backend ??= JustAudioPreviewBackend();

  String? _playingId;
  Duration _position = Duration.zero;
  bool _ended = false;
  String? _errorId;
  String? _error;
  StreamSubscription<Duration>? _subscription;
  Timer? _stopwatch;
  int _request = 0;
  bool _disposed = false;

  String? get playingId => _playingId;
  Duration get position => _position;
  bool get ended => _ended;
  String? get errorId => _errorId;
  String? get error => _error;

  bool isPlaying(String itemId) => _playingId == itemId && !_ended;

  /// 某一条目的上次试听错误；只显示在对应的行上。
  String? errorOf(String itemId) => _errorId == itemId ? _error : null;

  Future<void> toggle(String itemId, Uri sourceUri) async {
    if (isPlaying(itemId)) {
      await stop();
      return;
    }
    await _start(itemId, sourceUri);
  }

  Future<void> replay(String itemId, Uri sourceUri) => _start(itemId, sourceUri);

  Future<void> _start(String itemId, Uri sourceUri) async {
    _teardown(notify: false);
    if (_disposed) return;
    _playingId = itemId;
    _position = Duration.zero;
    _ended = false;
    _error = null;
    _errorId = null;
    notifyListeners();
    final request = ++_request;
    try {
      var playable = await resolveSource(sourceUri);
      if (_request != request || _playingId != itemId) return;
      try {
        await backend.setSource(playable);
      } catch (_) {
        // 本地文件 URI 打不开（如父目录含非 ASCII）时回退网络地址重试。
        if (playable == sourceUri) rethrow;
        playable = sourceUri;
        await backend.setSource(playable);
      }
      if (_request != request || _playingId != itemId) return;
      // just_audio 的 play() Future 要等到播放结束、暂停或停止才完成；
      // 先订阅位置并启动计时器，再等待播放，否则 30 秒限制会被推迟
      // 到整首播完才开始（Android/macOS 上尤其明显），进度条也不动。
      _subscription = backend.positions.listen((position) {
        if (_playingId == itemId) {
          _position = position;
          notifyListeners();
        }
      });
      final stopwatch = _stopwatch = Timer(limit, () {
        if (_playingId != itemId) return;
        _ended = true;
        backend.pause();
        notifyListeners();
      });
      await backend.play();
      // 播放可能在计时器触发或用户切歌后才返回；此时保持状态即可。
      if (_request != request || _playingId != itemId) {
        stopwatch.cancel();
        return;
      }
    } catch (error) {
      if (_request == request && _playingId == itemId) {
        _stopwatch?.cancel();
        _stopwatch = null;
        _subscription?.cancel();
        _subscription = null;
        _error = '$error';
        _errorId = itemId;
        _playingId = null;
        notifyListeners();
      }
    }
  }

  Future<void> stop() async {
    _teardown(notify: true);
  }

  void _teardown({required bool notify}) {
    _request++;
    _stopwatch?.cancel();
    _stopwatch = null;
    _subscription?.cancel();
    _subscription = null;
    final active = _playingId != null;
    _playingId = null;
    _position = Duration.zero;
    _ended = false;
    final current = _backend;
    if (current != null) {
      try {
        current.pause();
      } catch (_) {
        // 后端异常不阻断界面；下一次播放重新 setSource。
      }
    }
    if (active && notify) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _stopwatch?.cancel();
    _subscription?.cancel();
    final current = _backend;
    _backend = null;
    if (current != null) {
      try {
        current.dispose();
      } catch (_) {}
    }
    super.dispose();
  }
}
