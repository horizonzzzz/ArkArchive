import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../story_player/data/asset_package.dart';
import 'editor_file_picker.dart';
import 'editor_project.dart';

class EditorStorage {
  Future<Directory> get _root async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/story-editor-v1').create(recursive: true);
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
          result.add(EditorProject.decode(await file.readAsBytes()));
        }
      } on FormatException {
        // 保留损坏的文件，不阻止读取其他草稿。
      }
    }
    return result;
  }

  Future<void> save(EditorProject project) async {
    final bytes = project.export();
    final file = File('${(await _root).path}/${project.id}.json');
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  Future<void> delete(String id) async {
    final file = File('${(await _root).path}/$id.json');
    if (await file.exists()) await file.delete();
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
