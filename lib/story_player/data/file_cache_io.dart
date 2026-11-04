import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class FileCache {
  FileCache({Future<Directory> Function()? supportDirectory})
      : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;
  Future<Directory>? _directory;
  Future<Directory>? _activeFolder;

  Future<Directory> _root() => _directory ??= _supportDirectory();
  Future<File> _config() async => File('${(await _root()).path}/story_cache_directory.json');

  Future<Directory> _folder() async {
    final folder = _activeFolder ??= _resolveFolder();
    try {
      return await folder;
    } catch (_) {
      if (identical(_activeFolder, folder)) _activeFolder = null;
      rethrow;
    }
  }

  Future<Directory> _resolveFolder() async {
    final config = await _config();
    if (await config.exists()) {
      final path = jsonDecode(await config.readAsString()) as String;
      final selected = Directory(path);
      if (Platform.isMacOS) {
        await const MethodChannel('story_cache_directory').invokeMethod<void>('restore', selected.parent.absolute.path);
      }
      if (!await selected.exists()) throw FileSystemException('缓存目录不存在', path);
      return selected;
    }
    final folder = Directory('${(await _root()).path}/story_assets');
    await folder.create(recursive: true);
    return folder;
  }

  Future<void> setDirectory(String parentPath) async {
    final parent = Directory(parentPath);
    if (!await parent.exists()) throw FileSystemException('选择的目录不存在', parentPath);
    final source = await _folder();
    final target = Directory('${parent.absolute.path}${Platform.pathSeparator}story_assets');
    if (await target.exists()) {
      final current = await source.resolveSymbolicLinks();
      final selected = await target.resolveSymbolicLinks();
      if (Platform.isWindows ? current.toLowerCase() == selected.toLowerCase() : current == selected) return;
      throw FileSystemException('目标已包含 story_assets 目录，未覆盖任何文件', target.path);
    }
    if (Platform.isMacOS) {
      await const MethodChannel('story_cache_directory').invokeMethod<void>('save', parent.absolute.path);
    }
    final scratch = await parent.createTemp('.story_assets-');
    var copied = false;
    var switched = false;
    try {
      await for (final entity in source.list(followLinks: false)) {
        if (entity is File) {
          final name = entity.uri.pathSegments.last;
          await entity.copy('${scratch.path}${Platform.pathSeparator}$name');
        }
      }
      await scratch.rename(target.path);
      copied = true;
      final config = await _config();
      await config.parent.create(recursive: true);
      final temp = File('${config.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      try {
        await temp.writeAsString(jsonEncode(target.absolute.path), flush: true);
        await temp.rename(config.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
      _activeFolder = Future.value(target);
      switched = true;
    } finally {
      if (copied && !switched) await target.delete(recursive: true);
      if (await scratch.exists()) await scratch.delete(recursive: true);
    }
  }

  Future<void> openDirectory() async {
    final path = (await _folder()).path;
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [path]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [path]);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [path]);
    } else {
      throw UnsupportedError('当前平台不支持打开缓存目录');
    }
  }

  Future<String?> location() async => (await _folder()).path;

  Future<int> size() async {
    var bytes = 0;
    await for (final entity in (await _folder()).list(followLinks: false)) {
      if (entity is File) bytes += await entity.length();
    }
    return bytes;
  }

  Future<void> delete(Uri uri) async {
    final file = await _file(uri);
    if (await file.exists()) await file.delete();
  }

  Future<File> _file(Uri uri) async {
    final folder = await _folder();
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
    final scratch = await file.parent.createTemp('.write-');
    try {
      final temporary = File('${scratch.path}/asset');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } finally {
      await scratch.delete(recursive: true);
    }
  }
  Future<Uri> playableUri(Uri uri) async {
    final file = await _file(uri);
    return await file.exists() ? file.uri : uri;
  }
}
