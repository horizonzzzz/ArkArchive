import 'dart:typed_data';

class FileCache {
  Future<String?> location() async => null;
  Future<void> setDirectory(String parentPath) async =>
      throw UnsupportedError('当前平台不支持选择缓存目录');
  Future<void> openDirectory() async => throw UnsupportedError('当前平台不支持打开缓存目录');
  Future<int> size() async => 0;
  Future<void> clear({Set<Uri> keep = const {}}) async {}
  Future<void> delete(Uri uri, {String? story}) async {}
  Future<void> deleteStory(String story) async {}
  Future<Uint8List?> read(Uri uri, {String? story}) async => null;
  Future<void> write(Uri uri, Uint8List bytes, {String? story}) async {}
  Future<Uri> playableUri(Uri uri, {String? story}) async => uri;
}
