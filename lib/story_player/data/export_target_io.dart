import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

import 'export_target_android.dart';
import 'export_target_backend.dart';
import 'export_target_desktop.dart';

/// 导出门面：按平台分发到具体后端。Android 把素材打进 zip 并通过
/// 系统分享保存，其余 io 平台写散文件目录；平台差异全部收敛在这里，
/// 界面与导出编排不感知。测试可注入 [backend] 固定后端。
class ExportTarget {
  ExportTarget({ExportTargetBackend? backend})
    : _backend = backend ?? _backendForPlatform();

  static ExportTargetBackend _backendForPlatform() =>
      defaultTargetPlatform == TargetPlatform.android
          ? AndroidExportBackend()
          : DesktopExportBackend();

  final ExportTargetBackend _backend;

  /// 导出结果的展示位置：桌面为目录路径，Android 为 zip 文件名。
  String? get rootPath => _backend.rootPath;

  /// 是否允许用户选择导出位置（底栏「更改」按钮）。
  bool get supportsDirectorySelection => _backend.supportsDirectorySelection;

  /// 底栏目的地提示；[rootName] 为「章节/标题」形式的导出根名。
  String destinationSummary(String parentPath, String rootName) =>
      _backend.destinationSummary(parentPath, rootName);

  /// 导出完成的提示文案。
  String describeCompletion(String rootPath) =>
      _backend.describeCompletion(rootPath);

  /// 完成后主操作的文案（打开文件夹 / 分享）。
  String get openActionLabel => _backend.openActionLabel;

  Future<String> createDirectory(String parentPath, String name) =>
      _backend.createDirectory(parentPath, name);

  Future<void> writeFile(String relativePath, List<int> bytes) =>
      _backend.writeFile(relativePath, bytes);

  /// 全部文件（含 manifest）写完后的收尾；无收尾工作的后端为空实现。
  Future<void> commit() => _backend.commit();

  Future<void> deleteDirectory() => _backend.deleteDirectory();

  /// 打开导出结果（文件管理器或系统分享面板）。
  Future<void> openResult() => _backend.openResult();
}
