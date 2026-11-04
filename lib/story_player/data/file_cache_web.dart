import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

class FileCache {
  Future<web.Cache> get _cache =>
      web.window.caches.open('story-assets-v1').toDart;


  Future<String?> location() async => null;
  Future<void> setDirectory(String parentPath) async => throw UnsupportedError('浏览器不支持选择缓存目录');
  Future<void> openDirectory() async => throw UnsupportedError('浏览器不支持打开缓存目录');

  Future<int> size() async {
    final cache = await _cache;
    final keys = (await cache.keys().toDart).toDart;
    var bytes = 0;
    for (final key in keys) {
      final response = await cache.match(key).toDart;
      if (response != null) bytes += (await response.arrayBuffer().toDart).toDart.lengthInBytes;
    }
    return bytes;
  }

  Future<void> delete(Uri uri) async {
    await (await _cache).delete(uri.toString().toJS).toDart;
  }
  Future<Uint8List?> read(Uri uri) async {
    final response = await (await _cache).match(uri.toString().toJS).toDart;
    if (response == null) return null;
    return (await response.arrayBuffer().toDart).toDart.asUint8List();
  }

  Future<void> write(Uri uri, Uint8List bytes) async {
    await (await _cache)
        .put(uri.toString().toJS, web.Response(bytes.toJS))
        .toDart;
  }

  Future<Uri> playableUri(Uri uri) async {
    final bytes = await read(uri);
    return bytes == null
        ? uri
        : Uri.dataFromBytes(bytes, mimeType: 'audio/mpeg');
  }
}
