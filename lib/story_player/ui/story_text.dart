import 'package:flutter/material.dart';

TextStyle storyDialogueStyle(String fontFamily) => TextStyle(
  fontFamily: fontFamily,
  fontSize: 24,
  fontWeight: FontWeight.w500,
  color: Colors.white,
  shadows: const [Shadow(color: Color(0xe6404040), blurRadius: 4)],
);

/// 未显示的字仍参与排版，避免打字机输出时整行跳动。
List<InlineSpan> storyTextSpans(String text, int revealed, TextStyle base) {
  final result = <InlineSpan>[];
  final styles = <TextStyle>[base];
  var left = revealed;
  void append(String value) {
    final chars = value.runes.toList();
    final count = left.clamp(0, chars.length);
    if (count > 0) {
      result.add(
        TextSpan(
          text: String.fromCharCodes(chars.take(count)),
          style: styles.last,
        ),
      );
    }
    if (count < chars.length) {
      result.add(
        TextSpan(
          text: String.fromCharCodes(chars.skip(count)),
          style: styles.last.copyWith(
            color: Colors.transparent,
            shadows: const [],
          ),
        ),
      );
    }
    left -= count;
  }

  var start = 0;
  for (final match in RegExp(
    r'</?(?:color|b|i|size)(?:=[^>]*)?>',
    caseSensitive: false,
  ).allMatches(text)) {
    append(text.substring(start, match.start));
    final tag = match[0]!;
    if (tag.startsWith('</')) {
      if (styles.length > 1) styles.removeLast();
    } else {
      var style = styles.last;
      final lower = tag.toLowerCase();
      if (lower == '<b>') style = style.copyWith(fontWeight: FontWeight.bold);
      if (lower == '<i>') style = style.copyWith(fontStyle: FontStyle.italic);
      if (lower.startsWith('<color=')) {
        var hex = tag.substring(7, tag.length - 1).replaceFirst('#', '');
        if (hex.length == 6) hex = 'ff$hex';
        final value = int.tryParse(hex, radix: 16);
        if (value != null && hex.length == 8) {
          style = style.copyWith(color: Color(value));
        }
      }
      if (lower.startsWith('<size=')) {
        final size = double.tryParse(tag.substring(6, tag.length - 1));
        if (size != null && size.isFinite) {
          style = style.copyWith(fontSize: size.clamp(8, 100));
        }
      }
      styles.add(style);
    }
    start = match.end;
  }
  append(text.substring(start));
  return result;
}
