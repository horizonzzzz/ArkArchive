import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../story_player/data/asset_package.dart';
import 'editor_file_picker.dart';
import 'editor_project.dart';

Future<Uint8List> _encodeDraft(Map<String, Object> metadata) =>
    Isolate.run(() => utf8.encode(jsonEncode(metadata)));

class EditorStorage {
  static final _validId = RegExp(r'^[a-f0-9]{32}$');
  final _savedAssetKeys = <String>{};
  Future<Directory> get _root async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/story-editor-v1').create(recursive: true);
  }

  Future<Directory> _assetsRoot(String id) async {
    if (!_validId.hasMatch(id)) {
      throw const FormatException('作品标识无效');
    }
    return Directory('${(await _root).path}/assets/$id')
        .create(recursive: true);
  }

  Future<Uint8List?> _loadAsset(String key) async {
    final parts = key.split('/');
    if (parts.length != 2 ||
        !_validId.hasMatch(parts.first) ||
        !RegExp(r'^local_[a-f0-9]{64}$').hasMatch(parts.last)) {
      return null;
    }
    final file = File('${(await _assetsRoot(parts.first)).path}/${parts.last}');
    return await file.exists() ? file.readAsBytes() : null;
  }

  Future<List<EditorProject>> list() async {
    final files = await (await _root)
        .list()
        .where((f) => f is File && f.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final dated = await Future.wait(
      files.map((f) async => (f, await f.lastModified())),
    );
    dated.sort((a, b) => b.$2.compareTo(a.$2));
    final result = <EditorProject>[];
    for (final (file, _) in dated) {
      try {
        if (await file.length() <= maxProjectBytes) {
          final project = await EditorProject.decodeDraft(
            await file.readAsBytes(),
            _loadAsset,
          );
          result.add(await _restorePosition(project));
        }
      } on FormatException {
        // 保留损坏的文件，不阻止读取其他草稿。
      }
    }
    return result;
  }

  Future<EditorProject> _restorePosition(EditorProject project) async {
    final file = File('${(await _root).path}/${project.id}.position');
    try {
      if (!await file.exists() || await file.length() > 1024) return project;
      final data = jsonDecode(await file.readAsString());
      if (data is Map &&
          data['revision'] == project.updatedAt.toIso8601String()) {
        return project.copyWith(
          lastPosition: EditorPosition.fromJson(data['position']),
          updatedAt: project.updatedAt,
        );
      }
    } on FormatException {
      // 忽略损坏的位置记录，仍可打开草稿。
    } on FileSystemException {
      // 游标是可选记录，读取失败不影响草稿。
    }
    return project;
  }

  Future<void> savePosition(
    String id,
    DateTime revision,
    EditorPosition position,
  ) async {
    if (!_validId.hasMatch(id)) throw const FormatException('作品标识无效');
    final file = File('${(await _root).path}/$id.position');
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'revision': revision.toIso8601String(),
        'position': position.toJson(),
      }),
    );
    await temp.rename(file.path);
  }

  Future<void> save(EditorProject project) async {
    final assets = await _assetsRoot(project.id);
    for (final asset in project.assets.values) {
      final cacheKey = '${project.id}/${asset.key}';
      if (_savedAssetKeys.contains(cacheKey)) continue;
      final file = File('${assets.path}/${asset.key}');
      await file.writeAsBytes(asset.bytes, flush: true);
      _savedAssetKeys.add(cacheKey);
    }
    final metadata = project.toJson(inlineAssets: false);
    final bytes = await _encodeDraft(metadata);
    final file = File('${(await _root).path}/${project.id}.json');
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  Future<void> delete(String id) async {
    if (!_validId.hasMatch(id)) throw const FormatException('作品标识无效');
    final root = await _root;
    final file = File('${root.path}/$id.json');
    if (await file.exists()) await file.delete();
    final position = File('${root.path}/$id.position');
    if (await position.exists()) await position.delete();
    final assets = Directory('${root.path}/assets/$id');
    if (await assets.exists()) await assets.delete(recursive: true);
    _savedAssetKeys.removeWhere((key) => key.startsWith('$id/'));
  }

  Future<EditorProject?> importProject() async {
    final file = await pickEditorFile();
    if (file == null) return null;
    return EditorProject.decode(file.$2);
  }

  Future<(String, Uint8List)?> pickMedia({required bool image}) =>
      pickEditorFile(image: image);

  Future<void> exportFile(
    String title,
    String extension,
    Uint8List bytes,
  ) async {
    final filename = '${sanitizeFileName(title)}.$extension';
    if (Platform.isAndroid || Platform.isIOS) {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes)],
          fileNameOverrides: [filename],
        ),
      );
      return;
    }
    final location = await getSaveLocation(suggestedName: filename);
    if (location != null) {
      await File(location.path).writeAsBytes(bytes, flush: true);
    }
  }
}

class EditorAudioFiles {
  Future<Directory>? _root;
  final _files = <Uri, Future<Uri>>{};
  bool _closed = false;

  Future<Uri> resolve(Uri source, Future<Uint8List> Function() load) {
    if (_closed) throw StateError('预览已关闭');
    return _files.putIfAbsent(source, () async {
      final folder = await (_root ??= Directory.systemTemp.createTemp(
        'arkarchive-preview-',
      ));
      if (_closed) throw StateError('预览已关闭');
      final extension = source.path.split('.').last.toLowerCase();
      final file = File(
        '${folder.path}/${newProjectId()}.${audioFormats.containsKey(extension) ? extension : 'mp3'}',
      );
      await file.writeAsBytes(await load());
      return file.uri;
    });
  }

  Future<void> dispose() async {
    _closed = true;
    for (final file in _files.values) {
      try {
        await file;
      } catch (_) {
        /* 已由播放流程报告。 */
      }
    }
    final root = _root;
    if (root != null) {
      try {
        await (await root).delete(recursive: true);
      } on FileSystemException {
        /* 系统可回收临时文件。 */
      }
    }
  }
}
