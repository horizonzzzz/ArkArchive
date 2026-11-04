import 'dart:typed_data';

class FileCache {
  Future<String?> location() async => null;
  Future<void> setDirectory(String parentPath) async => throw UnsupportedError('当前平台不支持选择缓存目录');
  Future<void> openDirectory() async => throw UnsupportedError('当前平台不支持打开缓存目录');
  Future<int> size() async => 0;
  Future<void> delete(Uri uri) async {}
  Future<Uint8List?> read(Uri uri) async => null;
  Future<void> write(Uri uri, Uint8List bytes) async {}
  Future<Uri> playableUri(Uri uri) async => uri;
}
