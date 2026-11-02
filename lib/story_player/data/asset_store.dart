import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'file_cache.dart';

/// 原生端落盘，Web 端保留内存缓存；失败的 Future 不进入缓存。
class AssetStore {
  AssetStore({http.Client? client, FileCache? cache})
    : _client = client ?? http.Client(),
      _cache = cache ?? FileCache();
  final http.Client _client;
  final FileCache _cache;
  final Map<Uri, Uint8List> _memory = {};
  final Map<Uri, Future<Uint8List>> _pending = {};

  Uint8List? peek(Uri uri) => _memory[uri];
  Future<Uint8List> load(Uri uri) async {
    if (!['http', 'https'].contains(uri.scheme)) {
      throw FormatException('仅支持 HTTP(S) 资源：$uri');
    }
    if (_memory.containsKey(uri)) return _memory[uri]!;
    if (_pending.containsKey(uri)) return _pending[uri]!;
    final future = _download(uri);
    _pending[uri] = future;
    try {
      return await future;
    } finally {
      _pending.remove(uri);
    }
  }

  Future<Uint8List> _download(Uri uri) async {
    var bytes = await _cache.read(uri);
    if (bytes == null) {
      final response = await _client
          .get(uri)
          .timeout(const Duration(minutes: 2));
      if (response.statusCode != 200) {
        throw http.ClientException('HTTP ${response.statusCode}：$uri', uri);
      }
      bytes = response.bodyBytes;
      if (bytes.isEmpty) throw FormatException('资源为空：$uri');
      await _cache.write(uri, bytes);
    }
    return _memory[uri] = bytes;
  }

  Future<Uri> playableUri(Uri uri) => _cache.playableUri(uri);
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
          await load(uri);
        } catch (e) {
          errors.add('$uri：$e');
        }
        onProgress?.call(++done, pending.length);
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    return errors;
  }

  void close() => _client.close();
}
