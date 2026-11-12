import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 读取当前设备的 Android ABI（如 `arm64-v8a`、`x86_64`）；
/// 非 Android 或无法读取时返回 null。
Future<String?> detectAndroidAbi() async {
  if (!Platform.isAndroid) return null;
  try {
    final result = await Process.run('getprop', ['ro.product.cpu.abilist']);
    if (result.exitCode != 0) return null;
    for (final token in result.stdout.toString().trim().split(',')) {
      final abi = token.trim();
      if (const ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'].contains(abi)) {
        return abi;
      }
    }
  } catch (_) {
    // 读取失败时由调用方回退到 universal。
  }
  return null;
}

/// 应用内更新下载的文件系统后端；仅在提供 dart:io 的平台上可用。
/// Web 平台使用同名实现 app_update_stub.dart，接口形状保持一致。
class UpdateFileStore {
  const UpdateFileStore();

  static const MethodChannel _installChannel = MethodChannel(
    'app_update/install',
  );

  /// 更新包保存目录。桌面为系统「下载」目录；Android 没有可直接写入的
  /// 公共下载目录，改用应用专属外部目录（无需存储权限，卸载时清除）；
  /// iOS 没有可用目录，返回 null 交回系统浏览器流程。
  Future<String?> downloadDirectory() async {
    try {
      if (Platform.isAndroid) {
        return (await getExternalStorageDirectory() ??
                await getApplicationSupportDirectory())
            .path;
      }
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
      await sink.close().catchError((_) {});
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

  /// 计算文件 sha256 十六进制摘要，用于安装包完整性校验。
  Future<String> sha256Of(String path) async =>
      (await File(path).openRead().transform(sha256).first).toString();

  /// Android：通过系统安装器安装下载完成的 APK；由 MainActivity 的
  /// `app_update/install` 通道实现。
  Future<void> installApk(String path) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('仅 Android 支持安装更新包。');
    }
    await _installChannel.invokeMethod<void>('installApk', <String, Object?>{
      'path': path,
    });
  }

  /// 运行或打开已下载的文件；Windows 下用于启动安装器。
  Future<void> openFile(String path) async {
    if (Platform.isWindows) {
      await Process.start(
        path,
        const <String>[],
        mode: ProcessStartMode.detached,
      );
    } else if (Platform.isMacOS) {
      await Process.start('open', [path]);
    } else {
      await Process.start('xdg-open', [path]);
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
