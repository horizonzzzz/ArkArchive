import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 人物 ID 保持可追溯；NPC 文件名使用定长哈希，避免 Flutter 转义后超出文件系统限制。
String characterDetailFilename(String id) {
  if (!RegExp(r'^(op:char_[a-zA-Z0-9_]+|npc:[a-zA-Z0-9_%.-]+)$').hasMatch(id)) {
    throw FormatException('不安全的人物 ID：$id');
  }
  final stem = id.startsWith('npc:')
      ? 'npc_${sha256.convert(utf8.encode(id))}'
      : id.replaceFirst(':', '_');
  return '$stem.json';
}
