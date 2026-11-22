import 'dart:typed_data';

/// 预览字节缓存：已加载的资源字节驻留内存供缩略图/大图/导出复用，
/// 按 LRU 淘汰；对话框关闭时整体释放。加载器由调用方注入，
/// 生产环境绑定 AssetStore.loadTransient，测试注入假实现。
class PreviewCache {
  PreviewCache(this._loader, {this.maxBytes = 48 << 20});

  final Future<Uint8List> Function(Uri uri) _loader;
  final int maxBytes;

  final _pending = {};
  final _entries = <Uri, Uint8List>{};
  int _bytes = 0;

  Future<Uint8List> load(Uri uri) {
    final cached = _entries.remove(uri);
    if (cached != null) {
      // 重新插入保持 LRU 顺序，同时复用同一字节实例命中图片解码缓存。
      _entries[uri] = cached;
      return Future.value(cached);
    }
    final pending = _pending[uri];
    if (pending != null) return pending;
    final future = _load(uri);
    _pending[uri] = future;
    return future.whenComplete(() => _pending.remove(uri));
  }

  Future<Uint8List> _load(Uri uri) async {
    final bytes = await _loader(uri);
    _entries[uri] = bytes;
    _bytes += bytes.length;
    while (_bytes > maxBytes && _entries.length > 1) {
      final evicted = _entries.remove(_entries.keys.first);
      _bytes -= evicted!.length;
    }
    return bytes;
  }

  /// 对话框关闭时整体释放；在途请求的结果不再保留。
  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}
