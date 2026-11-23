import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'asset_package.dart';
import 'export_target_backend.dart';

/// Android 导出后端：素材逐文件流式写入应用缓存目录下的 zip，
/// 完成后通过系统分享面板交给用户保存到文件、网盘或发送给其他应用。
///
/// - 没有用户可选的目录概念：`parentPath` 一律忽略，不写公共存储、
///   不申请存储权限；zip 位于 `<临时目录>/方舟档案室导出/<章节_标题>.zip`。
/// - 展示名 `章节_标题.zip` 是压缩包文件名，也是结果页与完成提示里
///   用户唯一需要看到的位置；同名已存在时追加 ` (2)` 序号，不覆盖。
/// - 图片、音频与视频已是压缩格式，按后缀直接存储，不再二次压缩。
/// - zip 由 `story_export/share` 通道交给 MainActivity 拉起分享面板，
///   结果页可反复分享，直到系统清理应用缓存。
class AndroidExportBackend implements ExportTargetBackend {
  AndroidExportBackend({
    Future<Directory> Function()? cacheDirectory,
    Future<void> Function(String path, String displayName)? share,
  }) : _cacheDirectory = cacheDirectory ?? getTemporaryDirectory,
       _share = share ?? _shareViaSystem;

  final Future<Directory> Function() _cacheDirectory;
  final Future<void> Function(String, String) _share;

  static const _exportFolder = '方舟档案室导出';

  static const _channel = MethodChannel('story_export/share');

  /// 这些后缀的素材直接存储，跳过 deflate，节省移动端 CPU。
  static const _storedExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.gif',
    '.mp3',
    '.ogg',
    '.opus',
    '.mp4',
    '.m4a',
  };

  ZipFileEncoder? _encoder;
  File? _zip;
  String? _rootName;

  @override
  String? get rootPath => _rootName;

  @override
  bool get supportsDirectorySelection => false;

  @override
  String destinationSummary(String parentPath, String rootName) =>
      '打包为 ${rootName.replaceAll('/', '_')}.zip，完成后通过系统分享保存';

  @override
  String describeCompletion(String rootPath) => '素材已打包为 $rootPath';

  @override
  String get openActionLabel => '分享';

  @override
  Future<String> createDirectory(String parentPath, String name) async {
    final folder = Directory(
      _join((await _cacheDirectory()).path, _exportFolder),
    );
    await folder.create(recursive: true);
    final stem = name
        .split('/')
        .where((segment) => segment.trim().isNotEmpty)
        .map(sanitizeFileName)
        .join('_');
    if (stem.isEmpty) throw ArgumentError('导出目录名为空');
    var candidate = stem;
    var index = 1;
    File zip;
    while (true) {
      zip = File(_join(folder.path, '$candidate.zip'));
      try {
        await zip.create(exclusive: true);
        break;
      } on FileSystemException {
        if (!await zip.exists()) rethrow;
        index++;
        candidate = '$stem ($index)';
      }
    }
    try {
      _encoder = ZipFileEncoder()..create(zip.path);
    } catch (_) {
      await zip.delete();
      rethrow;
    }
    _zip = zip;
    return _rootName = '$candidate.zip';
  }

  @override
  Future<void> writeFile(String relativePath, List<int> bytes) async {
    final encoder = _encoder;
    if (encoder == null) throw StateError('尚未创建导出目录');
    final segments = relativePath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(sanitizeFileName)
        .toList();
    if (segments.isEmpty) throw ArgumentError('导出文件路径为空');
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final entry = ArchiveFile(segments.join('/'), data.length, data);
    entry.compress = !_storedExtensions.contains(_extensionOf(entry.name));
    encoder.addArchiveFile(entry);
  }

  @override
  Future<void> commit() async {
    final encoder = _encoder;
    if (encoder == null) return;
    _encoder = null;
    // close 写入中央目录并落盘；此后 zip 才是完整可解压的文件。
    await encoder.close();
  }

  @override
  Future<void> deleteDirectory() async {
    final encoder = _encoder;
    final zip = _zip;
    _encoder = null;
    _zip = null;
    _rootName = null;
    try {
      encoder?.closeSync();
    } catch (_) {
      // 关闭失败也要继续删除半成品文件。
    }
    if (zip != null && await zip.exists()) {
      await zip.delete();
    }
  }

  @override
  Future<void> openResult() async {
    final zip = _zip;
    if (zip == null) throw StateError('尚未创建导出目录');
    await _share(zip.path, _rootName ?? '素材.zip');
  }

  static Future<void> _shareViaSystem(String path, String displayName) async {
    await _channel.invokeMethod<void>('shareZip', <String, Object?>{
      'path': path,
      'displayName': displayName,
    });
  }
}

String _join(String a, String b) => '$a${Platform.pathSeparator}$b';

String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}
