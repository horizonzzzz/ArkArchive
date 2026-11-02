import 'dart:convert';

/// 保留原始行和未知命令，运行时负责分发而不是提前压平成台词。
class StoryCommand {
  const StoryCommand(this.tag, this.args, this.text, this.line, this.raw);
  final String tag;
  final Map<String, String> args;
  final String text;
  final int line;
  final String raw;

  String value(String key, [String fallback = '']) =>
      args[key.toLowerCase()] ?? fallback;
  double number(String key, [double fallback = 0]) {
    final n = double.tryParse(value(key));
    return n != null && n.isFinite ? n : fallback;
  }

  bool flag(String key, [bool fallback = false]) =>
      value(key).isEmpty ? fallback : value(key).toLowerCase() == 'true';
}

class StoryScript {
  StoryScript(this.commands);
  final List<StoryCommand> commands;

  factory StoryScript.parse(String source) {
    final commands = <StoryCommand>[];
    final lines = const LineSplitter().convert(
      source.replaceFirst('\uFEFF', ''),
    );
    for (var i = 0; i < lines.length; i++) {
      final line = i + 1;
      var raw = lines[i];
      while (raw.endsWith('\\') && i + 1 < lines.length) {
        raw = raw.substring(0, raw.length - 1) + lines[++i];
      }
      final text = raw.trim();
      if (text.isEmpty || text.startsWith('//')) continue;
      if (!text.startsWith('[')) {
        commands.add(StoryCommand('dialogue', const {}, text, line, raw));
        continue;
      }
      final end = _closingBracket(text);
      if (end < 0) throw FormatException('第 $line 行指令缺少 ]', raw);
      final header = text.substring(1, end).trim();
      final tail = text.substring(end + 1).trim();
      if (RegExp(r'^name\s*=', caseSensitive: false).hasMatch(header)) {
        commands.add(
          StoryCommand('dialogue', _arguments(header), tail, line, raw),
        );
        continue;
      }
      final open = header.indexOf('(');
      final tag = (open < 0 ? header : header.substring(0, open))
          .trim()
          .toLowerCase();
      if (open >= 0 && !header.endsWith(')')) {
        throw FormatException('第 $line 行指令缺少 )', raw);
      }
      final args = open < 0
          ? <String, String>{}
          : _arguments(header.substring(open + 1, header.length - 1));
      commands.add(StoryCommand(tag, args, tail, line, raw));
    }
    return StoryScript(List.unmodifiable(commands));
  }
}

int _closingBracket(String text) {
  String? quote;
  var escaped = false;
  for (var i = 1; i < text.length; i++) {
    final c = text[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (c == '\\' && quote != null) {
      escaped = true;
      continue;
    }
    if (quote != null) {
      if (c == quote) quote = null;
    } else if (c == '"' || c == "'") {
      quote = c;
    } else if (c == ']') {
      return i;
    }
  }
  return -1;
}

Map<String, String> _arguments(String input) {
  final result = <String, String>{};
  String? quote;
  var escaped = false;
  var start = 0;
  void add(String part) {
    final equals = part.indexOf('=');
    if (equals < 0) return;
    final key = part.substring(0, equals).trim().toLowerCase();
    var value = part.substring(equals + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value
          .substring(1, value.length - 1)
          .replaceAllMapped(
            RegExp(r'\\(.)'),
            (m) => switch (m[1]) {
              'n' => '\n',
              'r' => '\r',
              't' => '\t',
              '"' => '"',
              "'" => "'",
              '\\' => '\\',
              _ => m[0]!,
            },
          );
    }
    if (key.isNotEmpty) result[key] = value;
  }

  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (c == '\\' && quote != null) {
      escaped = true;
      continue;
    }
    if (quote != null) {
      if (c == quote) quote = null;
    } else if (c == '"' || c == "'") {
      quote = c;
    } else if (c == ',') {
      add(input.substring(start, i));
      start = i + 1;
    }
  }
  add(input.substring(start));
  return result;
}
