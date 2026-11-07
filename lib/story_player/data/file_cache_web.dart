import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:web/web.dart' as web;

/// 浏览器缓存：共享资源放一个 Cache，每个剧情独占一个命名 Cache，
/// 删除剧情即整块 CacheStorage 条目回收，与原生端按目录隔离的语义一致。
class FileCache {
  static const _sharedCacheName = 'story-assets-v1';

  static String _storyCacheName(String story) =>
      'story-${sha256.convert(utf8.encode(story))}-v1';

  Future<web.Cache> get _shared =>
      web.window.caches.open(_sharedCacheName).toDart;

  Future<web.Cache> _story(String story) =>
      web.window.caches.open(_storyCacheName(story)).toDart;

  Future<List<String>> _cacheNames() async => [
    for (final name in (await web.window.caches.keys().toDart).toDart)
      name.toDart,
  ];

  Future<String?> location() async => null;
  Future<void> setDirectory(String parentPath) async =>
      throw UnsupportedError('浏览器不支持选择缓存目录');
  Future<void> openDirectory() async => throw UnsupportedError('浏览器不支持打开缓存目录');

  Future<int> size() async {
    var bytes = 0;
    for (final name in await _cacheNames()) {
      if (name != _sharedCacheName && !name.startsWith('story-')) continue;
      final cache = await web.window.caches.open(name).toDart;
      for (final key in (await cache.keys().toDart).toDart) {
        final response = await cache.match(key).toDart;
        if (response != null) {
          bytes += (await response.arrayBuffer().toDart).toDart.lengthInBytes;
        }
      }
    }
    return bytes;
  }

  Future<void> clear({Set<Uri> keep = const {}}) async {
    final retained = keep.map((uri) => uri.toString()).toSet();
    for (final name in await _cacheNames()) {
      if (name == _sharedCacheName) {
        final cache = await web.window.caches.open(name).toDart;
        for (final key in (await cache.keys().toDart).toDart) {
          if (!retained.contains(key.url)) await cache.delete(key).toDart;
        }
      } else if (name.startsWith('story-')) {
        await web.window.caches.delete(name).toDart;
      }
    }
  }

  Future<void> delete(Uri uri, {String? story}) async {
    final key = uri.toString().toJS;
    if (story == null) {
      await (await _shared).delete(key).toDart;
    } else {
      await (await _story(story)).delete(key).toDart;
    }
  }

  Future<void> deleteStory(String story) async {
    await web.window.caches.delete(_storyCacheName(story)).toDart;
  }

  Future<Uint8List?> read(
    Uri uri, {
    String? story,
    bool allowShared = true,
  }) async {
    final key = uri.toString().toJS;
    web.Response? response;
    if (story != null) {
      response = await (await _story(story)).match(key).toDart;
    }
    if (story == null || allowShared) {
      response ??= await (await _shared).match(key).toDart;
    }
    if (response == null) return null;
    return (await response.arrayBuffer().toDart).toDart.asUint8List();
  }

  Future<void> write(Uri uri, Uint8List bytes, {String? story}) async {
    final target = story == null ? await _shared : await _story(story);
    await target.put(uri.toString().toJS, web.Response(bytes.toJS)).toDart;
  }

  Future<Uri> playableUri(Uri uri, {String? story}) async {
    final bytes = await read(uri, story: story);
    return bytes == null
        ? uri
        : Uri.dataFromBytes(bytes, mimeType: 'audio/mpeg');
  }
}
