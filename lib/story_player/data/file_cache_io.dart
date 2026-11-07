import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// 磁盘缓存：资源按 URI 哈希命名，每个剧情独占一个子目录，互不共用。
///
/// ```text
/// story_assets/
///   _shared/<hash>.<ext>            —— 设置、剧情索引与解析表格等全局资源
///   stories/<storyKey>/<hash>.<ext>  —— 单个剧情的脚本与媒体素材
/// ```
///
/// 删除剧情缓存即整目录回收，无需统计素材被哪些剧情共用。
class FileCache {
  FileCache({
    Future<Directory> Function()? supportDirectory,
    Future<void> Function(String, List<String>)? startProcess,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _startProcess =
           startProcess ??
           ((executable, arguments) async {
             await Process.start(executable, arguments);
           });

  static final _hashFileName = RegExp(r'^[a-f0-9]{64}\.[a-zA-Z0-9]{1,8}$');

  /// 目录实体的 URI 带尾斜杠，末段为空；统一取真实的最后一段名字。
  static String _entryName(FileSystemEntity entity) =>
      entity.uri.pathSegments.where((segment) => segment.isNotEmpty).last;

  static String fileName(Uri uri) {
    final hash = sha256.convert(utf8.encode(uri.toString())).toString();
    final extension =
        RegExp(r'\.[a-zA-Z0-9]{1,8}$').firstMatch(uri.path)?.group(0) ?? '.bin';
    return '$hash$extension';
  }

  /// 剧情目录名：对剧情路径取哈希，避免原始路径中的斜杠与中文进入文件系统。
  static String storyKey(String story) =>
      sha256.convert(utf8.encode(story)).toString();

  final Future<Directory> Function() _supportDirectory;
  final Future<void> Function(String, List<String>) _startProcess;
  Future<Directory>? _directory;
  Future<Directory>? _activeFolder;
  final Map<(Uri, String?), Future<void>> _writes = {};

  Future<Directory> _root() => _directory ??= _supportDirectory();
  Future<File> _config() async => File(
    '${(await _root()).path}${Platform.pathSeparator}story_cache_directory.json',
  );

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
        await const MethodChannel('story_cache_directory')
            .invokeMethod<void>('restore', selected.parent.absolute.path);
      }
      if (!await selected.exists()) throw FileSystemException('缓存目录不存在', path);
      return selected;
    }
    final folder = Directory(
      '${(await _root()).path}${Platform.pathSeparator}story_assets',
    );
    await folder.create(recursive: true);
    return folder;
  }

  Future<Directory> _sharedFolder() async => Directory(
    '${(await _folder()).path}${Platform.pathSeparator}_shared',
  );

  Future<Directory> _storyFolder(String story) async => Directory(
    '${(await _folder()).path}'
    '${Platform.pathSeparator}stories'
    '${Platform.pathSeparator}${storyKey(story)}',
  );

  Future<File> _file(Uri uri, String? story) async => File(
    '${story == null ? (await _sharedFolder()).path : (await _storyFolder(story)).path}'
    '${Platform.pathSeparator}${fileName(uri)}',
  );

  Future<void> setDirectory(String parentPath) async {
    final parent = Directory(parentPath);
    if (!await parent.exists()) {
      throw FileSystemException('选择的目录不存在', parentPath);
    }
    final source = await _folder();
    final target = Directory(
      '${parent.absolute.path}${Platform.pathSeparator}story_assets',
    );
    if (await target.exists()) {
      final current = await source.resolveSymbolicLinks();
      final selected = await target.resolveSymbolicLinks();
      if (Platform.isWindows
          ? current.toLowerCase() == selected.toLowerCase()
          : current == selected) {
        return;
      }
      throw FileSystemException('目标已包含 story_assets 目录，未覆盖任何文件', target.path);
    }
    if (Platform.isMacOS) {
      await const MethodChannel('story_cache_directory')
          .invokeMethod<void>('save', parent.absolute.path);
    }
    final scratch = await parent.createTemp('.story_assets-');
    var copied = false;
    var switched = false;
    try {
      await _copyTree(source, scratch);
      await scratch.rename(target.path);
      copied = true;
      final config = await _config();
      await config.parent.create(recursive: true);
      final temp = File(
        '${config.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
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

  static Future<void> _copyTree(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final name = _entryName(entity);
      if (entity is File) {
        await entity.copy('${target.path}${Platform.pathSeparator}$name');
      } else if (entity is Directory) {
        await _copyTree(entity, Directory('${target.path}${Platform.pathSeparator}$name'));
      }
    }
  }

  Future<void> openDirectory() async {
    final directory = await _folder();
    if (!await directory.exists()) {
      throw FileSystemException('缓存目录不存在', directory.path);
    }
    final path = await directory.resolveSymbolicLinks();
    if (Platform.isWindows) {
      await _startProcess('explorer.exe', ['/n,', path]);
    } else if (Platform.isMacOS) {
      await _startProcess('open', [path]);
    } else if (Platform.isLinux) {
      await _startProcess('xdg-open', [path]);
    } else {
      throw UnsupportedError('当前平台不支持打开缓存目录');
    }
  }

  Future<String?> location() async => (await _folder()).path;

  Future<int> size() async {
    var bytes = 0;
    final folder = await _folder();
    await for (final entity in folder.list(followLinks: false)) {
      final name = _entryName(entity);
      if (entity is File && _hashFileName.hasMatch(name)) {
        bytes += await entity.length();
      } else if (entity is Directory) {
        if (name == '_shared' || name == 'stories') {
          bytes += await _directorySize(entity);
        }
      }
    }
    return bytes;
  }

  static Future<int> _directorySize(Directory directory) async {
    var bytes = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) {
        bytes += await entity.length();
      } else if (entity is Directory) {
        bytes += await _directorySize(entity);
      }
    }
    return bytes;
  }

  Future<void> clear({Set<Uri> keep = const {}}) async {
    final retained = {for (final uri in keep) fileName(uri)};
    final folder = await _folder();
    final stories = Directory(
      '${folder.path}${Platform.pathSeparator}stories',
    );
    if (await stories.exists()) await stories.delete(recursive: true);
    await for (final entity in folder.list(followLinks: false)) {
      final name = _entryName(entity);
      if (entity is File) {
        // 旧版平铺布局的残留文件随清空一并回收。
        if (_hashFileName.hasMatch(name) && !retained.contains(name)) {
          await entity.delete();
        }
      } else if (entity is Directory && name == '_shared') {
        await for (final shared in entity.list(followLinks: false)) {
          final sharedName = _entryName(shared);
          if (shared is File &&
              _hashFileName.hasMatch(sharedName) &&
              !retained.contains(sharedName)) {
            await shared.delete();
          }
        }
      }
    }
  }

  Future<void> delete(Uri uri, {String? story}) async {
    final file = await _file(uri, story);
    if (await file.exists()) await file.delete();
  }

  /// 删除单个剧情的整个缓存目录；目录不存在时静默完成。
  Future<void> deleteStory(String story) async {
    final folder = await _storyFolder(story);
    if (await folder.exists()) await folder.delete(recursive: true);
  }

  Future<Uint8List?> read(Uri uri, {String? story}) async {
    final file = await _file(uri, story);
    if (await file.exists()) return file.readAsBytes();
    // 剧情层未命中时回退共享层，保留历史隐性缓存。
    if (story != null) {
      final shared = await _file(uri, null);
      if (await shared.exists()) return shared.readAsBytes();
    }
    return null;
  }

  Future<void> write(Uri uri, Uint8List bytes, {String? story}) async {
    // Windows 不允许同时替换同一个文件，同一 (URI, 目录) 必须依次写入。
    final key = (uri, story);
    final previous = _writes[key] ?? Future<void>.value();
    final write = previous.catchError((_) {}).then((_) => _write(uri, bytes, story));
    _writes[key] = write;
    try {
      await write;
    } finally {
      if (identical(_writes[key], write)) _writes.remove(key);
    }
  }

  Future<void> _write(Uri uri, Uint8List bytes, String? story) async {
    final file = await _file(uri, story);
    await file.parent.create(recursive: true);
    final scratch = await file.parent.createTemp('.write-');
    try {
      final temporary = File('${scratch.path}/asset');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } finally {
      await scratch.delete(recursive: true);
    }
  }

  Future<Uri> playableUri(Uri uri, {String? story}) async {
    final file = await _file(uri, story);
    if (!await file.exists()) {
      // 剧情层未命中时回退共享层；两级都没有再交给播放器走网络。
      if (story != null) {
        final shared = await _file(uri, null);
        if (await shared.exists()) return shared.uri;
      }
      return uri;
    }
    return file.uri;
  }
}
