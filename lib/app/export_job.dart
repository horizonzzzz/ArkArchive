import 'package:flutter/foundation.dart';

import '../story_player/data/asset_package.dart';
import '../story_player/data/cache_control.dart';
import '../story_player/data/export_target.dart';
import '../story_player/data/story_export.dart';

enum ExportJobStatus { running, completed, failed, cancelled }

/// 一次素材导出任务的可观察状态；导出对话框与剧情行菜单共享同一实例。
class ExportJob extends ChangeNotifier {
  ExportJob({
    required this.package,
    required this.items,
    required this.parentPath,
    ExportTarget? target,
  }) : target = target ?? ExportTarget();

  final AssetPackage package;
  final List<AssetItem> items;
  final String parentPath;
  final control = CacheControl();

  ExportJobStatus status = ExportJobStatus.running;
  int done = 0;
  int total = 0;
  int bytes = 0;
  ExportResult? result;
  String? error;

  /// 完成后用于「打开文件夹」或「分享」；失败或取消后仍保留，
  /// 可打开已写入的部分。测试可注入固定后端。
  final ExportTarget target;

  double get progress =>
      total == 0 ? 0 : (done / total).clamp(0.0, 1.0);

  void apply({
    ExportJobStatus? status,
    int? done,
    int? total,
    int? bytes,
    ExportResult? result,
    String? error,
  }) {
    if (status != null) this.status = status;
    if (done != null) this.done = done;
    if (total != null) this.total = total;
    if (bytes != null) this.bytes = bytes;
    if (result != null) this.result = result;
    if (error != null) this.error = error;
    notifyListeners();
  }
}
