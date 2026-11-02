import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class FileCache {
  Future<Directory>? _directory;
  Future<File> _file(Uri uri) async {
    final root = await (_directory ??= getApplicationSupportDirectory());
    final folder = Directory('${root.path}/story_assets');
    await folder.create(recursive: true);
    final name = sha256.convert(utf8.encode(uri.toString()));
    final extension = RegExp(r'\.[a-zA-Z0-9]{1,8}$').firstMatch(uri.path)?.group(0) ?? '.bin';
    return File('${folder.path}/$name$extension');
  }
  Future<Uint8List?> read(Uri uri) async {
    final file = await _file(uri);
    return await file.exists() ? file.readAsBytes() : null;
  }
  Future<void> write(Uri uri, Uint8List bytes) async {
    final file = await _file(uri);
    final temporary = File('${file.path}.part');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }
  Future<Uri> playableUri(Uri uri) async {
    final file = await _file(uri);
    return await file.exists() ? file.uri : uri;
  }
}
