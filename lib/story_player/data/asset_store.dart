import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'cache_control.dart';
import 'file_cache.dart';

class AssetStore {
  AssetStore({http.Client? client, FileCache? cache})
    : _client = client ?? http.Client(),
      _cache = cache ?? FileCache();

  final http.Client _client;
  final FileCache _cache;
  final Map<Uri, Uint8List> _memory = {};
  final Map<(Uri, bool), Future<Uint8List>> _pending = {};
  final Map<Uri, Object> _writeErrors = {};
  Future<void> _settingsWrite = Future.value();
  static final _settingsUri = Uri.parse('https://local.invalid/story-cache-settings');
  static final _wifiUri = Uri.parse('https://local.invalid/story-cache-wifi-only');
  static final _cacheDownloadZone = Object();
  static final _cacheControlZone = Object();
  bool wifiOnly = false;
  bool get isMobile => !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
  bool get isDesktop => !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
       defaultTargetPlatform == TargetPlatform.macOS ||
       defaultTargetPlatform == TargetPlatform.linux);

  Future<T> runCacheDownload<T>(Future<T> Function() action, {CacheControl? control}) =>
      runZoned(action, zoneValues: {_cacheDownloadZone: true, _cacheControlZone: control});

  bool _wifiAllowed(List<ConnectivityResult> connections) =>
      connections.contains(ConnectivityResult.wifi) &&
      !connections.contains(ConnectivityResult.mobile);

  Future<void> setWifiOnly(bool value) async {
    if (_movingCache) throw StateError('缓存目录迁移中');
    wifiOnly = value;
    final write = _settingsWrite.catchError((_) {}).then((_) => _cache.write(_wifiUri, Uint8List.fromList(utf8.encode(value ? '1' : '0'))));
    _settingsWrite = write;
    await write;
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
    final turn = Completer<void>();
    _waiting.add(turn);
    _drain();
    await turn.future;
    final abort = Completer<void>();
    StreamSubscription<List<ConnectivityResult>>? subscription;
    var networkBlocked = false;
    final restricted = isMobile && wifiOnly && Zone.current[_cacheDownloadZone] == true;
    try {
      if (restricted) {
        final connectivity = Connectivity();
        subscription = connectivity.onConnectivityChanged.listen((connections) {
          if (wifiOnly && !_wifiAllowed(connections)) {
            networkBlocked = true;
            if (!abort.isCompleted) abort.complete();
          }
        }, onError: (Object _) {
          networkBlocked = true;
          if (!abort.isCompleted) abort.complete();
        });
        if (!_wifiAllowed(await connectivity.checkConnectivity().timeout(const Duration(seconds: 5))) || networkBlocked) {
          throw StateError('仅允许 Wi-Fi 下载，当前网络不可用');
        }
      }
      final request = http.AbortableRequest('GET', uri, abortTrigger: abort.future);
      try {
        final response = await _client.send(request).then(http.Response.fromStream).timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            if (!abort.isCompleted) abort.complete();
            throw TimeoutException('请求超时：$uri');
          },
        );
        if (networkBlocked) throw StateError('Wi-Fi 已断开，下载已停止');
        return response;
      } catch (_) {
        if (networkBlocked) throw StateError('Wi-Fi 已断开，下载已停止');
        rethrow;
      }
    } finally {
      try {
        await subscription?.cancel();
      } finally {
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
      final data = await _cache.read(_wifiUri);
      if (data != null) wifiOnly = utf8.decode(data) == '1';
    } catch (_) {
      // 存储不可用时保留当前设置。
    }
  }

  Future<void> setConcurrency(int value) async {
    if (_movingCache) throw StateError('缓存目录迁移中');
    if (value < 1 || value > 8) throw RangeError.range(value, 1, 8);
    concurrency = value;
    final write = _settingsWrite.catchError((_) {}).then((_) => _cache.write(_settingsUri, Uint8List.fromList(utf8.encode('$value'))));
    _settingsWrite = write;
    await write;
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
    if (_pending.keys.any((key) => key.$1 == uri)) throw StateError('资源正在使用：$uri');
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
    final key = (uri, isMobile && Zone.current[_cacheDownloadZone] == true);
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
            if (attempt == 0 && (response.statusCode == 429 || response.statusCode >= 500)) {
              await Future<void>.delayed(const Duration(milliseconds: 300));
              continue;
            }
            throw http.ClientException('HTTP ${response.statusCode}：$uri', uri);
          }
          final contentType = response.headers['content-type']?.toLowerCase() ?? '';
          if (contentType.contains('text/html') && RegExp(r'\.(png|mp3|json|txt)$', caseSensitive: false).hasMatch(uri.path)) {
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

    await Future.wait(List.generate(Zone.current[_cacheControlZone] == null ? concurrency : 1, (_) => worker()));
    return errors;
  }

  void close() => _client.close();
}
