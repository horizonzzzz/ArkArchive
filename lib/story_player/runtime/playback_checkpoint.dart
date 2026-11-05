import '../script.dart';

/// 重建场景所需的执行路径；不保存逐帧动画或音频时间。
class PlaybackCheckpoint {
  PlaybackCheckpoint({required this.cursor, required List<int> trace})
      : trace = List.unmodifiable(trace);

  final int cursor;
  // 非负数为命令索引，-1 为跳过节点，-2-index 为选项索引。
  final List<int> trace;

  bool isValidFor(StoryScript script) => script.commands.isNotEmpty && (
      cursor == 0 && trace.isEmpty ||
      cursor > 0 && cursor <= script.commands.length &&
      trace.isNotEmpty && trace.length <= 100000 &&
      trace.any((step) => step >= 0) &&
      trace.every((step) => step < script.commands.length));

  Map<String, dynamic> toJson() => {'cursor': cursor, 'trace': trace};

  factory PlaybackCheckpoint.fromJson(Map<String, dynamic> json) {
    final cursor = json['cursor'];
    final trace = json['trace'];
    if (cursor is! int || cursor < 0 || trace is! List ||
        (trace.isEmpty && cursor != 0) || (trace.isNotEmpty && cursor == 0) ||
        trace.length > 100000 || trace.any((v) => v is! int)) {
      throw const FormatException('观看断点格式无效');
    }
    return PlaybackCheckpoint(cursor: cursor, trace: trace.cast<int>());
  }
}
