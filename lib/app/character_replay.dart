import '../story_player/data/story_repository.dart';
import 'character_archive_data.dart';

class CharacterReplayLocation {
  const CharacterReplayLocation(this.commandIndex, this.notice);
  final int? commandIndex;
  final String notice;
}

/// 只有内容与说话人吻合才使用指令位置，避免数据更新后跳到无关对白。
CharacterReplayLocation locateCharacterReplay(
  StoryDocument document,
  CharacterStory story,
  CharacterSnippet snippet,
) {
  final commands = document.script.commands;
  bool matches(int index) {
    if (index < 0 || index >= commands.length) return false;
    final command = commands[index];
    return command.tag == 'dialogue' &&
        command.text.trim() == snippet.text.trim() &&
        (command.args['name'] ?? '')
                .trim()
                .replaceAll('（', '(')
                .replaceAll('）', ')') ==
            snippet.speaker.trim();
  }

  if (document.sourceHash == story.scriptHash &&
      matches(snippet.commandIndex)) {
    return CharacterReplayLocation(snippet.commandIndex, '已定位到所选台词。');
  }
  final candidates = [
    for (var i = 0; i < commands.length; i++)
      if (matches(i)) i,
  ];
  final sameLine = candidates
      .where((i) => commands[i].line == snippet.line)
      .toList();
  final target = sameLine.length == 1
      ? sameLine.single
      : candidates.length == 1
      ? candidates.single
      : null;
  return target == null
      ? const CharacterReplayLocation(null, '脚本已变化或台词位置不明确，未自动定位。请从头观看。')
      : CharacterReplayLocation(target, '脚本版本有变化，已按说话人和台词重新定位。');
}
