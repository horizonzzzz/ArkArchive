import 'dart:convert';

class VoiceProfile {
  VoiceProfile([Map<String, int> overrides = const {}])
    : overrides = Map.of(overrides);

  final Map<String, int> overrides;
  static const defaults = <String, int>{'': 58, '阿米娅': 3, '凯尔希': 10, '博士': 58, '杜宾': 20, '陈': 25, '能天使': 30, '德克萨斯': 35};

  int resolve(String speaker) {
    final selected = overrides[speaker] ?? defaults[speaker];
    if (selected != null && selected >= 3 && selected <= 102) return selected;
    // Dart String.hashCode 不保证跨运行时一致，使用 UTF-8 FNV-1a。
    var hash = 2166136261;
    for (final byte in utf8.encode(speaker)) {
      hash = ((hash ^ byte) * 16777619) & 0xffffffff;
    }
    return 3 + hash % 100;
  }

  static String label(int sid) => sid < 58
      ? '中文女声 ${(sid - 2).toString().padLeft(2, '0')}'
      : '中文男声 ${(sid - 57).toString().padLeft(2, '0')}';
}
