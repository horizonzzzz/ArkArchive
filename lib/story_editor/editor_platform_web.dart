import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../story_player/data/asset_package.dart';
import 'editor_file_picker.dart';
import 'editor_project.dart';

String _blob(Uint8List bytes, String mime) => web.URL.createObjectURL(
  web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime)),
);

class EditorStorage {
  static const _prefix = 'story-editor-v1';
  Future<web.Cache>? _cache;
  Future<web.Cache> get _drafts =>
      _cache ??= web.window.caches.open(_prefix).toDart;
  String _key(String id) => 'https://editor.invalid/$_prefix/$id';

  Future<List<EditorProject>> list() async {
    final cache = await _drafts;
    final result = <(EditorProject, int)>[];
    for (final request in (await cache.keys().toDart).toDart) {
      final response = await cache.match(request).toDart;
      if (response == null) continue;
      try {
        final bytes = (await response.arrayBuffer().toDart).toDart
            .asUint8List();
        result.add((
          EditorProject.decode(bytes),
          int.tryParse(response.headers.get('X-Edited-At') ?? '') ?? 0,
        ));
      } on FormatException {
        // 保留损坏的文件，不阻止读取其他草稿。
      }
    }
    result.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final item in result) item.$1];
  }

  Future<void> save(EditorProject project) async {
    final response = web.Response(project.export().toJS);
    response.headers.set(
      'X-Edited-At',
      '${DateTime.now().millisecondsSinceEpoch}',
    );
    await (await _drafts).put(_key(project.id).toJS, response).toDart;
  }

  Future<void> delete(String id) async {
    await (await _drafts).delete(_key(id).toJS).toDart;
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
    final url = _blob(
      bytes,
      extension == 'json' ? 'application/json' : 'text/plain;charset=utf-8',
    );
    (web.HTMLAnchorElement()
          ..href = url
          ..download = '${sanitizeFileName(title)}.$extension')
        .click();
    await Future<void>.delayed(const Duration(seconds: 1));
    web.URL.revokeObjectURL(url);
  }
}

class EditorAudioFiles {
  final _files = <Uri, Future<Uri>>{};
  bool _closed = false;

  Future<Uri> resolve(Uri source, Future<Uint8List> Function() load) {
    if (_closed) throw StateError('预览已关闭');
    return _files.putIfAbsent(source, () async {
      final bytes = await load();
      if (_closed) throw StateError('预览已关闭');
      return Uri.parse(
        _blob(bytes, audioFormats[source.path.split('.').last] ?? 'audio/mpeg'),
      );
    });
  }

  Future<void> dispose() async {
    _closed = true;
    for (final file in _files.values) {
      try {
        web.URL.revokeObjectURL((await file).toString());
      } catch (_) {
        /* 已由播放流程报告。 */
      }
    }
  }
}
