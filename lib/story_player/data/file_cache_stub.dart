import 'dart:typed_data';

class FileCache {
  Future<Uint8List?> read(Uri uri) async => null;
  Future<void> write(Uri uri, Uint8List bytes) async {}
  Future<Uri> playableUri(Uri uri) async => uri;
}
