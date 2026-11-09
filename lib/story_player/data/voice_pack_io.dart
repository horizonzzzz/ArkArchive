import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
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
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _clientFactory = clientFactory ?? http.Client.new;
  final Future<Directory> Function() _supportDirectory;
  final http.Client Function() _clientFactory;
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
      final size = await Isolate.run(() => validateVoicePack(path));
      if (size > 0) {
        directory = path;
        installedBytes = size;
        status = VoicePackStatus.installed;
      }
      final partial = File('${_root!.path}/model.tar.bz2.part');
      if (await partial.exists()) receivedBytes = await partial.length();
    } catch (e) {
      status = VoicePackStatus.failed;
      error = '无法读取语音包：$e';
    }
    notifyListeners();
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
    final archive = File('${root.path}/model.tar.bz2.part');
    error = null;
    status = VoicePackStatus.downloading;
    notifyListeners();
    try {
      receivedBytes = await archive.exists() ? await archive.length() : 0;
      if (receivedBytes > VoicePackStore.downloadBytes) {
        await archive.delete();
        receivedBytes = 0;
      }
      if (receivedBytes < VoicePackStore.downloadBytes) {
        final client = _client = _clientFactory();
        try {
          final request = http.Request(
            'GET',
            Uri.parse(VoicePackStore.downloadUrl),
          );
          if (receivedBytes > 0)
            request.headers['Range'] = 'bytes=$receivedBytes-';
          http.StreamedResponse response;
          try {
            response = await client
                .send(request)
                .timeout(const Duration(seconds: 30));
            if (response.statusCode != 200 && response.statusCode != 206)
              throw HttpException('HTTP ${response.statusCode}');
          } catch (_) {
            await control.checkpoint();
            final fallback = http.Request(
              'GET',
              Uri.parse(VoicePackStore.assetApiUrl),
            );
            fallback.headers.addAll(request.headers);
            fallback.headers['Accept'] = 'application/octet-stream';
            response = await client
                .send(fallback)
                .timeout(const Duration(seconds: 30));
          }
          if (response.statusCode != 200 && response.statusCode != 206) {
            throw HttpException('下载失败：HTTP ${response.statusCode}');
          }
          if (response.statusCode == 206 &&
              response.headers['content-range'] !=
                  'bytes $receivedBytes-${VoicePackStore.downloadBytes - 1}/${VoicePackStore.downloadBytes}') {
            throw const FormatException('服务器返回的续传范围不匹配');
          }
          if (response.statusCode == 200) receivedBytes = 0;
          final sink = archive.openWrite(
            mode: receivedBytes == 0 ? FileMode.write : FileMode.append,
          );
          try {
            var lastReport = 0;
            await for (final bytes in response.stream) {
              await control.checkpoint();
              receivedBytes += bytes.length;
              if (receivedBytes > VoicePackStore.downloadBytes)
                throw const FormatException('语音包超过预期大小');
              sink.add(bytes);
              if (receivedBytes - lastReport >= 262144) {
                lastReport = receivedBytes;
                notifyListeners();
                await sink.flush();
              }
            }
          } finally {
            await sink.close();
          }
        } finally {
          client.close();
          _client = null;
        }
      }
      await control.checkpoint();
      if (receivedBytes != VoicePackStore.downloadBytes)
        throw const FormatException('语音包未下载完整，请重试续传');
      status = VoicePackStatus.verifying;
      notifyListeners();
      final archivePath = archive.path;
      final rootPath = root.path;
      installedBytes = await Isolate.run(
        () => installVoiceArchive(archivePath, rootPath),
      );
      await control.checkpoint();
      directory = '${root.path}/${VoicePackStore.id}';
      status = VoicePackStatus.installed;
      await archive.delete();
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
      if (path != null && await Directory(path).exists())
        await Directory(path).delete(recursive: true);
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

/// 每次启动校验安装记录，损坏或缺文件的模型不会交给 native 引擎。
Future<int> validateVoicePack(String path) async {
  try {
    final marker = File('$path/installed.json');
    if (!await marker.exists()) return 0;
    final manifest =
        jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
    if (manifest['archiveSha256'] != VoicePackStore.archiveSha256) return 0;
    var total = 0;
    final hashes = manifest['files'] as Map<String, dynamic>;
    if (!hashes.containsKey('model.int8.onnx') ||
        !hashes.containsKey('voices.bin') ||
        !hashes.containsKey('tokens.txt') ||
        !hashes.containsKey('lexicon-zh.txt') ||
        !hashes.containsKey('lexicon-us-en.txt')) {
      return 0;
    }
    for (final entry in hashes.entries) {
      if (!safeVoicePath(entry.key)) return 0;
      final file = File('$path/${entry.key}');
      if (!await file.exists() ||
          '${await sha256.bind(file.openRead()).first}' != entry.value)
        return 0;
      total += await file.length();
    }
    return total;
  } catch (_) {
    return 0;
  }
}

bool safeVoicePath(String name) =>
    name.isNotEmpty &&
    !name.startsWith('/') &&
    !name.contains('\\') &&
    !name.contains(':') &&
    !name.split('/').contains('..');

Future<int> installVoiceArchive(String archivePath, String rootPath) async {
  final packed = File(archivePath);
  if ('${await sha256.bind(packed.openRead()).first}' !=
      VoicePackStore.archiveSha256) {
    await packed.delete();
    throw const FormatException('语音包 SHA256 校验失败，请重新下载');
  }
  final staging = Directory('$rootPath/.installing');
  final tarPath = '$rootPath/model.tar';
  try {
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    final input = InputFileStream(archivePath);
    final output = OutputFileStream(tarPath);
    try {
      if (!BZip2Decoder().decodeStream(input, output, verify: true))
        throw const FormatException('语音包解压失败');
    } finally {
      input.closeSync();
      output.closeSync();
    }
    final tar = InputFileStream(tarPath);
    final hashes = <String, String>{};
    var total = 0;
    try {
      final archive = TarDecoder().decodeStream(tar);
      for (final entry in archive) {
        if (!safeVoicePath(entry.name) || entry.isSymbolicLink)
          throw const FormatException('语音包包含不安全路径');
        if (!entry.isFile) continue;
        final parts = entry.name.split('/');
        if (parts.first != VoicePackStore.id || parts.length < 2)
          throw const FormatException('语音包目录不匹配');
        final relative = parts.skip(1).join('/');
        total += entry.size;
        if (total > 700000000) throw const FormatException('语音包解压大小异常');
        final file = File('${staging.path}/$relative');
        await file.parent.create(recursive: true);
        final out = OutputFileStream(file.path);
        try {
          entry.writeContent(out);
        } finally {
          out.closeSync();
        }
        hashes[relative] = '${await sha256.bind(file.openRead()).first}';
      }
    } finally {
      tar.closeSync();
    }
    await File('${staging.path}/installed.json').writeAsString(
      jsonEncode({
        'version': 1,
        'archiveSha256': VoicePackStore.archiveSha256,
        'files': hashes,
      }),
      flush: true,
    );
    if (await validateVoicePack(staging.path) == 0)
      throw const FormatException('语音包缺少模型或词典文件');
    final target = Directory('$rootPath/${VoicePackStore.id}');
    if (await target.exists()) await target.delete(recursive: true);
    await staging.rename(target.path);
    return total;
  } finally {
    if (await File(tarPath).exists()) await File(tarPath).delete();
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}
