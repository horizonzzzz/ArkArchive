import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 应用内更新下载的文件系统后端；仅在提供 dart:io 的平台上可用。
/// Web 平台使用同名实现 app_update_stub.dart，接口形状保持一致。
class UpdateFileStore {
  const UpdateFileStore();

  /// 系统「下载」目录；Android/iOS 没有可直接写入的公共下载目录，返回 null。
  Future<String?> downloadDirectory() async {
    try {
      return (await getDownloadsDirectory())?.path;
    } catch (_) {
      return null;
    }
  }

  String join(String directory, String name) =>
      '$directory${Platform.pathSeparator}$name';

  /// 把响应流写入 [path]；中断时关闭文件句柄，由调用方清理残留文件。
  Future<void> write(String path, Stream<List<int>> stream) async {
    final sink = File(path).openWrite();
    try {
      await sink.addStream(stream);
    } catch (_) {
      unawaited(sink.close().catchError((_) {}));
      rethrow;
    }
    await sink.close();
  }

  Future<void> move(String from, String to) => File(from).rename(to);

  Future<void> remove(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 清理失败不掩盖原始错误。
    }
  }

  /// 在系统文件管理器中显示文件所在目录。
  Future<void> reveal(String path) async {
    final directory = File(path).parent.path;
    if (Platform.isWindows) {
      await Process.start('explorer.exe', ['/n,', directory]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [directory]);
    } else {
      await Process.start('xdg-open', [directory]);
    }
  }
}
