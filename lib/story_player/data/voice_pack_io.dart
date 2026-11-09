import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'cache_control.dart';
import 'voice_pack.dart';
import 'voice_pack_stub.dart';

VoicePackStore createVoicePackStore() =>
    Platform.isAndroid || Platform.isWindows || Platform.isLinux
    ? LocalVoicePackStore()
    : UnsupportedVoicePackStore();

class LocalVoicePackStore extends VoicePackStore {
  LocalVoicePackStore({
    Future<Directory> Function()? supportDirectory,
    http.Client Function()? clientFactory,
    List<VoicePackFile> files = VoicePackStore.files,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _clientFactory = clientFactory ?? http.Client.new,
       _files = List.unmodifiable(files);
  final Future<Directory> Function() _supportDirectory;
  final http.Client Function() _clientFactory;
  final List<VoicePackFile> _files;
  @override
  VoicePackStatus status = VoicePackStatus.missing;
  @override
  final profile = VoiceProfile();
  @override
  String? directory;
  @override
  String? error;
  @override
  int receivedBytes = 0;
  @override
  int installedBytes = 0;
  Future<void>? _initializing;
  Future<void>? _installing;
  Directory? _root;
  CacheControl? _control;
  http.Client? _client;

  @override
  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    try {
      _root = Directory('${(await _supportDirectory()).path}/voice_packs');
      await _root!.create(recursive: true);
      final settings = File('${_root!.path}/bindings.json');
      if (await settings.exists()) {
        try {
          final json =
              jsonDecode(await settings.readAsString()) as Map<String, dynamic>;
          for (final entry in json.entries) {
            if (entry.value is int && entry.value >= 3 && entry.value <= 102) {
              profile.overrides[entry.key] = entry.value as int;
            }
          }
        } catch (_) {
          /* 损坏的映射回落内置值，不阻止模型使用。 */
        }
      }
      final path = '${_root!.path}/${VoicePackStore.id}';
      final files = _files;
      final size = await Isolate.run(() => validateVoicePack(path, files));
      if (size > 0) {
        directory = path;
        installedBytes = size;
        status = VoicePackStatus.installed;
      }
      final staging = Directory('${_root!.path}/.downloading');
      if (await staging.exists()) receivedBytes = await _receivedIn(staging);
    } catch (e) {
      status = VoicePackStatus.failed;
      error = '无法读取语音包：$e';
    }
    notifyListeners();
  }

  /// staging 内已就位文件与未完成 .part 的总字节数，用于恢复下载进度。
  Future<int> _receivedIn(Directory staging) async {
    var total = 0;
    final names = {for (final file in _files) file.name};
    final sizes = {for (final file in _files) file.name: file.size};
    for (final entry in await staging.list().toList()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      final done = names.contains(name);
      final partial = name.endsWith('.part') &&
          names.contains(name.substring(0, name.length - 5));
      if (done) {
        total += sizes[name] ?? 0;
      } else if (partial) {
        total += await entry.length();
      }
    }
    return total;
  }

  @override
  Future<void> install() =>
      _installing ??= _install().whenComplete(() => _installing = null);

  Future<void> _install() async {
    await initialize();
    if (installed) return;
    final root = _root;
    if (root == null) return;
    final control = _control = CacheControl();
    final staging = Directory('${root.path}/.downloading');
    error = null;
    status = VoicePackStatus.downloading;
    notifyListeners();
    try {
      await staging.create(recursive: true);
      var doneBytes = 0;
      final pending = _files
          .where(
            (file) => !File('${staging.path}/${file.name}').existsSync(),
          )
          .toList();
      doneBytes =
          _files.fold(0, (sum, file) => sum + file.size) -
          pending.fold(0, (sum, file) => sum + file.size);
      receivedBytes = doneBytes;
      for (final entry in await staging.list().toList()) {
        if (entry is File && entry.path.endsWith('.part')) {
          receivedBytes += await entry.length();
        }
      }
      notifyListeners();
      final client = _client = _clientFactory();
      try {
        for (final file in pending) {
          await _downloadFile(control, staging, file, doneBytes);
          doneBytes += file.size;
        }
      } finally {
        client.close();
        _client = null;
      }
      await control.checkpoint();
      status = VoicePackStatus.verifying;
      notifyListeners();
      final stagingPath = staging.path;
      final rootPath = root.path;
      final files = _files;
      installedBytes = await Isolate.run(
        () => installDownloadedFiles(stagingPath, rootPath, files),
      );
      await control.checkpoint();
      directory = '${root.path}/${VoicePackStore.id}';
      status = VoicePackStatus.installed;
      // staging 已原子改名为安装目录，无需再清理。
    } on CacheCancelled {
      status = VoicePackStatus.missing;
    } catch (e) {
      status = control.cancelled
          ? VoicePackStatus.missing
          : VoicePackStatus.failed;
      error = control.cancelled ? null : '$e';
    } finally {
      _control = null;
      notifyListeners();
    }
  }

  /// 单个文件：依次尝试镜像列表中的源，任一源成功即完成。
  Future<void> _downloadFile(
    CacheControl control,
    Directory staging,
    VoicePackFile file,
    int doneBytes,
  ) async {
    final target = File('${staging.path}/${file.name}');
    if (await target.exists()) return;
    Object? failure;
    for (final host in VoicePackStore.downloadHosts) {
      try {
        await _downloadFromHost(control, staging, file, host, doneBytes);
        return;
      } on CacheCancelled {
        rethrow;
      } catch (e) {
        failure = e;
        debugPrint('语音包 $host/${file.name} 下载失败，尝试下一个源：$e');
      }
    }
    throw HttpException('下载 ${file.name} 失败：$failure');
  }

  Future<void> _downloadFromHost(
    CacheControl control,
    Directory staging,
    VoicePackFile file,
    String host,
    int doneBytes,
  ) async {
    final part = File('${staging.path}/${file.name}.part');
    var start = await part.exists() ? await part.length() : 0;
    if (start > file.size) {
      await part.delete();
      start = 0;
    }
    final request = http.Request(
      'GET',
      Uri.parse(VoicePackStore.fileUrl(host, file.name)),
    );
    if (start > 0) request.headers['Range'] = 'bytes=$start-';
    final response = await _client!
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    if (response.statusCode == 206) {
      final expected =
          'bytes $start-${file.size - 1}/${file.size}';
      if (response.headers['content-range'] != expected) {
        throw const FormatException('服务器返回的续传范围不匹配');
      }
    }
    final mode = response.statusCode == 200 ? FileMode.write : FileMode.append;
    final sink = part.openWrite(mode: mode);
    var position = response.statusCode == 200 ? 0 : start;
    try {
      var lastReport = position;
      await for (final bytes in response.stream) {
        await control.checkpoint();
        position += bytes.length;
        if (position > file.size) {
          throw const FormatException('语音包文件超过预期大小');
        }
        sink.add(bytes);
        receivedBytes = doneBytes + position;
        if (position - lastReport >= 262144) {
          lastReport = position;
          notifyListeners();
          await sink.flush();
        }
      }
    } finally {
      await sink.close();
    }
    if (position != file.size) {
      throw const FormatException('下载不完整，请重试续传');
    }
    if ('${await sha256.bind(part.openRead()).first}' != file.sha256) {
      await part.delete();
      throw const FormatException('文件校验失败，已丢弃重新下载');
    }
    await part.rename('${staging.path}/${file.name}');
  }

  @override
  void pause() {
    if (status != VoicePackStatus.downloading) return;
    _control?.pause();
    status = VoicePackStatus.paused;
    notifyListeners();
  }

  @override
  void resume() {
    if (status != VoicePackStatus.paused) return;
    _control?.resume();
    status = VoicePackStatus.downloading;
    notifyListeners();
  }

  @override
  void cancel() {
    _control?.cancel();
    _client?.close();
  }

  @override
  Future<void> remove() async {
    if (busy) return;
    final path =
        directory ??
        (_root == null ? null : '${_root!.path}/${VoicePackStore.id}');
    directory = null;
    status = VoicePackStatus.verifying;
    notifyListeners();
    try {
      for (final release in releaseUsers.toList()) {
        await release();
      }
      if (path != null && await Directory(path).exists()) {
        await Directory(path).delete(recursive: true);
      }
      status = VoicePackStatus.missing;
      installedBytes = 0;
      receivedBytes = 0;
    } catch (e) {
      status = VoicePackStatus.failed;
      error = '删除语音包失败：$e';
    }
    notifyListeners();
  }
  @override
  Future<void> bind(String speaker, int? sid) async {
    await initialize();
    if (sid != null && (sid < 3 || sid > 102)) throw ArgumentError.value(sid);
    final next = Map<String, int>.of(profile.overrides);
    if (sid == null) {
      next.remove(speaker);
    } else {
      next[speaker] = sid;
    }
    final file = File('${_root!.path}/bindings.json');
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(next), flush: true);
    await temp.rename(file.path);
    profile.overrides
      ..clear()
      ..addAll(next);
    notifyListeners();
  }
}

/// 安装前校验 staging 内全部文件并对齐安装记录，然后原子替换目标目录。
/// staging 中残留的 .part 不会进入安装目录。
Future<int> installDownloadedFiles(
  String stagingPath,
  String rootPath, [
  List<VoicePackFile> files = VoicePackStore.files,
]) async {
  final staging = Directory(stagingPath);
  var total = 0;
  for (final file in files) {
    final target = File('${staging.path}/${file.name}');
    if (!await target.exists() || await target.length() != file.size) {
      throw FormatException('语音包文件缺失或大小异常：${file.name}');
    }
    if ('${await sha256.bind(target.openRead()).first}' != file.sha256) {
      throw FormatException('语音包文件校验失败：${file.name}');
    }
    total += file.size;
  }
  for (final entry in await staging.list().toList()) {
    if (entry is File && entry.path.endsWith('.part')) await entry.delete();
  }
  await File('${staging.path}/installed.json').writeAsString(
    jsonEncode({
      'version': 1,
      'files': {for (final file in files) file.name: file.sha256},
    }),
    flush: true,
  );
  if (await validateVoicePack(stagingPath, files) == 0) {
    throw const FormatException('语音包安装校验失败');
  }
  final targetDir = Directory('$rootPath/${VoicePackStore.id}');
  if (await targetDir.exists()) await targetDir.delete(recursive: true);
  await staging.rename(targetDir.path);
  return total;
}

/// 每次启动校验安装记录，损坏或缺文件的模型不会交给 native 引擎。
Future<int> validateVoicePack(
  String path, [
  List<VoicePackFile> files = VoicePackStore.files,
]) async {
  try {
    final marker = File('$path/installed.json');
    if (!await marker.exists()) return 0;
    final manifest =
        jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
    if (manifest['version'] != 1) return 0;
    final hashes = manifest['files'] as Map<String, dynamic>;
    if (hashes.length != files.length) return 0;
    var total = 0;
    for (final file in files) {
      if (hashes[file.name] != file.sha256) return 0;
      final target = File('$path/${file.name}');
      if (!await target.exists() ||
          '${await sha256.bind(target.openRead()).first}' != file.sha256) {
        return 0;
      }
      total += await target.length();
    }
    return total;
  } catch (_) {
    return 0;
  }
}
