import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'cache_control.dart';
import 'file_cache.dart';

import 'playback_settings.dart';
import 'playback_progress.dart';

class AssetStore {
  AssetStore({http.Client? client, FileCache? cache})
    : _client = client ?? http.Client(),
      _cache = cache ?? FileCache();

  final http.Client _client;
  final FileCache _cache;
  final Map<Uri, Uint8List> _memory = {};
  final Map<(Uri, Object?), Future<Uint8List>> _pending = {};
  final Map<Uri, Object> _writeErrors = {};
  Future<void> _settingsWrite = Future.value();
  static final _settingsUri = Uri.parse(
    'https://local.invalid/story-cache-settings',
  );
  static final _playbackSettingsUri = Uri.parse(
    'https://local.invalid/story-playback-settings-v1',
  );
  PlaybackSettings playbackSettings = const PlaybackSettings();
  static final _playbackProgressUri = Uri.parse(
    'https://local.invalid/story-playback-progress-v1',
  );
  PlaybackProgress? playbackProgress;
  static final _cacheDownloadZone = Object();
  static final _cacheControlZone = Object();
  bool get isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  bool get isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  Future<T> runCacheDownload<T>(
    Future<T> Function() action, {
    CacheControl? control,
  }) => runZoned(
    action,
    zoneValues: {_cacheDownloadZone: true, _cacheControlZone: control},
  );

  Future<List<ConnectivityResult>> cacheConnections() =>
      Connectivity().checkConnectivity().timeout(const Duration(seconds: 5));

  Stream<List<ConnectivityResult>> get cacheConnectionChanges =>
      Connectivity().onConnectivityChanged;

  Future<void> clearCache({Set<Uri> keep = const {}}) async {
    if (_movingCache || _pending.isNotEmpty) throw StateError('请等待当前资源加载结束');
    _movingCache = true;
    try {
      await _settingsWrite.catchError((_) {});
      await _cache.clear(keep: {_settingsUri, _playbackSettingsUri, _playbackProgressUri, ...keep});
    } finally {
      releaseMemory();
      _movingCache = false;
    }
  }

  Future<String?> cacheLocation() => _cache.location();
  Future<int> cacheSize() => _cache.size();
  bool _movingCache = false;

  Future<void> moveCacheDirectory(String parentPath) async {
    if (_movingCache || _pending.isNotEmpty) throw StateError('请等待当前资源加载结束');
    _movingCache = true;
    try {
      await _settingsWrite.catchError((_) {});
      await _cache.setDirectory(parentPath);
      releaseMemory();
    } finally {
      _movingCache = false;
    }
  }

  Future<void> openCacheDirectory() => _cache.openDirectory();
  int _concurrency = 4;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue();
  int get concurrency => _concurrency;
  set concurrency(int value) {
    if (value < 1 || value > 8) throw RangeError.range(value, 1, 8);
    _concurrency = value;
    _drain();
  }

  void _drain() {
    while (_active < _concurrency && _waiting.isNotEmpty) {
      _active++;
      _waiting.removeFirst().complete();
    }
  }

  Future<http.Response> _get(Uri uri) async {
    final control = Zone.current[_cacheControlZone] as CacheControl?;
    while (true) {
      await control?.checkpoint();
      final turn = Completer<void>();
      _waiting.add(turn);
      _drain();
      await turn.future;
      final abort = Completer<void>();
      var interrupted = false;
      final subscription = control?.interruptions.listen((_) {
        interrupted = true;
        if (!abort.isCompleted) abort.complete();
      });
      try {
        if (control?.cancelled == true) throw const CacheCancelled();
        if (control?.blocked == true) continue;
        final request = http.AbortableRequest(
          'GET',
          uri,
          abortTrigger: abort.future,
        );
        try {
          final response = await _client
              .send(request)
              .then(http.Response.fromStream)
              .timeout(
                const Duration(seconds: 30),
                onTimeout: () {
                  if (!abort.isCompleted) abort.complete();
                  throw TimeoutException('请求超时：$uri');
                },
              );
          if (!interrupted) return response;
        } catch (_) {
          if (!interrupted) rethrow;
        }
      } finally {
        await subscription?.cancel();
        _active--;
        _drain();
      }
    }
  }

  Future<void> loadSettings() async {
    try {
      final data = await _cache.read(_settingsUri);
      final value = data == null ? null : int.tryParse(utf8.decode(data));
      if (value != null && value >= 1 && value <= 8) concurrency = value;
    } catch (_) {
      // 存储不可用时仍允许使用默认值播放。
    }
    try {
      final data = await _cache.read(_playbackSettingsUri);
      if (data != null) {
        playbackSettings = PlaybackSettings.fromJson(
          jsonDecode(utf8.decode(data)) as Map<String, dynamic>,
        );
      }
    } catch (_) {
      // Keep defaults if saved preferences cannot be read.
    }
    try {
      final data = await _cache.read(_playbackProgressUri);
      playbackProgress = data == null ? null : PlaybackProgress.fromJson(
        jsonDecode(utf8.decode(data)) as Map<String, dynamic>,
      );
    } catch (_) {
      // 损坏的观看记录不影响目录和播放设置加载。
      playbackProgress = null;
    }
  }

  Future<void> setConcurrency(int value) async {
    if (_movingCache) throw StateError('缓存目录迁移中');
    if (value < 1 || value > 8) throw RangeError.range(value, 1, 8);
    concurrency = value;
    final write = _settingsWrite
        .catchError((_) {})
        .then(
          (_) => _cache.write(
            _settingsUri,
            Uint8List.fromList(utf8.encode('$value')),
          ),
        );
    _settingsWrite = write;
    await write;
  }

  Future<void> setPlaybackSettings(PlaybackSettings value) async {
    playbackSettings = value;
    if (_movingCache) throw StateError('缓存目录迁移中');
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(value.toJson())));
    final write = _settingsWrite
        .catchError((_) {})
        .then((_) => _cache.write(_playbackSettingsUri, bytes));
    _settingsWrite = write;
    await write;
  }

  Future<void> setPlaybackProgress(PlaybackProgress? value) async {
    if (_movingCache) throw StateError('缓存目录迁移中');
    final bytes = value == null ? null
        : Uint8List.fromList(utf8.encode(jsonEncode(value.toJson())));
    final write = _settingsWrite.catchError((_) {}).then((_) async {
      if (bytes == null) {
        await _cache.delete(_playbackProgressUri);
      } else {
        await _cache.write(_playbackProgressUri, bytes);
      }
      playbackProgress = value;
    });
    _settingsWrite = write;
    await write;
  }

  Future<bool> probe(Uri uri) async {
    final abort = Completer<void>();
    try {
      final response = await _client
          .send(http.AbortableRequest('GET', uri, abortTrigger: abort.future))
          .timeout(const Duration(seconds: 10));
      await response.stream.listen((_) {}).cancel();
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<Uint8List?> readCache(Uri uri) async {
    if (_movingCache) throw StateError('缓存目录迁移中');
    return _cache.read(uri);
  }

  Future<void> writeCache(Uri uri, Uint8List bytes) async {
    if (_movingCache) throw StateError('缓存目录迁移中');
    return _cache.write(uri, bytes);
  }

  Future<void> deleteCache(Uri uri) async {
    if (_movingCache) throw StateError('缓存目录迁移中');
    if (_pending.keys.any((key) => key.$1 == uri)) {
      throw StateError('资源正在使用：$uri');
    }
    await _cache.delete(uri);
    _memory.remove(uri);
    _writeErrors.remove(uri);
  }

  void releaseMemory() {
    _memory.clear();
    _writeErrors.clear();
  }

  Uint8List? peek(Uri uri) => _memory[uri];
  Future<Uint8List> load(Uri uri) async {
    await (Zone.current[_cacheControlZone] as CacheControl?)?.checkpoint();
    if (_movingCache) throw StateError('缓存目录迁移中');
    if (!['http', 'https'].contains(uri.scheme)) {
      throw FormatException('仅支持 HTTP(S) 资源：$uri');
    }
    if (_memory.containsKey(uri)) return _memory[uri]!;
    final key = (
      uri,
      Zone.current[_cacheControlZone] ?? Zone.current[_cacheDownloadZone],
    );
    if (_pending.containsKey(key)) return _pending[key]!;
    final future = _download(uri);
    _pending[key] = future;
    try {
      return await future;
    } finally {
      _pending.remove(key);
    }
  }

  Future<Uint8List> _download(Uri uri) async {
    Uint8List? bytes;
    try {
      bytes = await _cache.read(uri);
      if (bytes != null && bytes.isEmpty) bytes = null;
    } catch (_) {
      // 缓存不可读时继续尝试网络，写入失败会在预加载结果中报告。
    }
    if (bytes == null) {
      for (var attempt = 0; ; attempt++) {
        try {
          final response = await _get(uri);
          if (response.statusCode != 200) {
            if (attempt == 0 &&
                (response.statusCode == 429 || response.statusCode >= 500)) {
              await Future<void>.delayed(const Duration(milliseconds: 300));
              continue;
            }
            throw http.ClientException('HTTP ${response.statusCode}：$uri', uri);
          }
          final contentType =
              response.headers['content-type']?.toLowerCase() ?? '';
          if (contentType.contains('text/html') &&
              RegExp(
                r'\.(png|mp3|json|txt)$',
                caseSensitive: false,
              ).hasMatch(uri.path)) {
            throw FormatException('资源地址返回了 HTML 页面：$uri');
          }
          bytes = response.bodyBytes;
          if (bytes.isEmpty) throw FormatException('资源为空：$uri');
          break;
        } on TimeoutException {
          if (attempt > 0) rethrow;
        } on http.ClientException catch (error) {
          if (attempt > 0 || error.message.startsWith('HTTP ')) rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      try {
        await _cache.write(uri, bytes);
        _writeErrors.remove(uri);
      } catch (error) {
        _writeErrors[uri] = error;
      }
    }
    return _memory[uri] = bytes;
  }

  Future<Uri> playableUri(Uri uri) async {
    try {
      return await _cache.playableUri(uri);
    } catch (_) {
      return uri;
    }
  }

  Future<List<String>> preload(
    Set<Uri> assets, {
    void Function(int done, int total)? onProgress,
  }) async {
    final pending = assets.toList();
    final errors = <String>[];
    var next = 0;
    var done = 0;
    Future<void> worker() async {
      while (next < pending.length) {
        final uri = pending[next++];
        try {
          final bytes = await load(uri);
          if (_writeErrors.containsKey(uri)) {
            await _cache.write(uri, bytes);
            _writeErrors.remove(uri);
          }
        } on CacheCancelled {
          rethrow;
        } catch (e) {
          errors.add('$uri：$e');
        }
        if (Zone.current[_cacheControlZone] != null) _memory.remove(uri);
        onProgress?.call(++done, pending.length);
      }
    }

    await Future.wait(
      List.generate(
        Zone.current[_cacheControlZone] == null ? concurrency : 1,
        (_) => worker(),
      ),
    );
    return errors;
  }

  void close() => _client.close();
}
