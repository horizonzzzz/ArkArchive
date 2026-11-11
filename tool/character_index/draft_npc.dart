import 'dart:convert';
import 'dart:io';

/// 从构建报告起草 npc_extra.json 候选表（不直接参与构建）。
///
/// 输入：build/characters/report.json 的 unmatchedSpeakers（含共现立绘证据）。
/// 输出：build/characters/npc_extra.draft.json + npc_extra.candidates.csv。
///
/// 起草规则零猜测：
/// - 稳档案：台词达到阈值且立绘共现集中，直接给出 avg 建议字段；
/// - 抹块：台词达到阈值但没有稳定立绘证据，只建卡不给 avg；
/// - 人工待定：带引号的假名/借名、问号占位一律进 CSV 待人工判断，
///   绝不写入 draft.json。
Future<void> main(List<String> args) async {
  final values = <String, String>{};
  for (final arg in args) {
    final equals = arg.indexOf('=');
    if (arg.startsWith('--') && equals > 0) {
      values[arg.substring(0, equals)] = arg.substring(equals + 1);
    }
  }
  final reportPath = values['--report'] ?? 'build/characters/report.json';
  final outPath = values['--out'] ?? 'build/characters/npc_extra.draft.json';
  final csvPath =
      values['--csv'] ?? 'build/characters/npc_extra.candidates.csv';
  final minLines = int.tryParse(values['--min-lines'] ?? '30') ?? 30;
  final minStories = int.tryParse(values['--min-stories'] ?? '3') ?? 3;
  final avgRatio = double.tryParse(values['--avg-ratio'] ?? '0.6') ?? 0.6;
  final avgCounts = int.tryParse(values['--avg-counts'] ?? '5') ?? 5;
  final avgMaxReuse = int.tryParse(values['--avg-max-reuse'] ?? '2') ?? 2;

  final report = jsonDecode(await File(reportPath).readAsString());
  if (report is! Map<String, dynamic>) {
    throw const FormatException('报告必须是 JSON 对象');
  }
  final speakers = (report['unmatchedSpeakers'] as List? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  if (speakers.isEmpty) {
    stderr.writeln('报告里没有未归属说话人，无需起草。');
    return;
  }
  final current = jsonDecode(
    await File(values['--npc-extra'] ?? 'tool/data/npc_extra.json')
        .readAsString(),
  );
  final known = current is Map<String, dynamic>
      ? current.keys.map((key) => key.toString()).toSet()
      : const <String>{};
  final groupPatterns =
      (await File(
            values['--group-patterns'] ?? 'tool/data/npc_group_patterns.txt',
          ).readAsLines())
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .map(RegExp.new)
          .toList();

  final draft = <String, dynamic>{};
  final rows = <List<Object?>>[];
  // 模型复用度：同一 avg key 被多少个未归属说话人引用过。
  // 大量路人群演共用少数几套 AVG 模型，复用度高的 key 不能绑定给任何一个人。
  final modelSpeakers = <String, Set<String>>{};
  for (final speaker in speakers) {
    for (final key in (speaker['avgKeys'] as Map? ?? const {}).keys) {
      modelSpeakers
          .putIfAbsent(key.toString(), () => {})
          .add((speaker['name'] ?? '').toString());
    }
  }
  for (final speaker in speakers) {
    final name = (speaker['name'] ?? '').toString().trim();
    final lines = (speaker['lineCount'] as num?)?.toInt() ?? 0;
    final stories = ((speaker['stories'] as List?) ?? const []).length;
    final avgKeys =
        (speaker['avgKeys'] as Map? ?? const {})
            .cast<String, num>()
            .entries
            .toList()
          ..sort((a, b) {
            final byCount = b.value.compareTo(a.value);
            return byCount != 0 ? byCount : a.key.compareTo(b.key);
          });
    final sample = (speaker['sampleText'] ?? '').toString().replaceAll(
      '\n',
      ' ',
    );
    final sampleStory = (speaker['sampleStory'] ?? '').toString();
    final significant = lines >= minLines || stories >= minStories;
    final quoted =
        (name.startsWith('“') && name.endsWith('”')) ||
        (name.startsWith('"') && name.endsWith('"'));
    final suspicious =
        RegExp(r'^[？?]+$').hasMatch(name) ||
        // 结尾问号：脚本对占位或悬念伪称的标注，不能猜测身份。
        RegExp(r'[？?]$').hasMatch(name);
    final groupMatch = groupPatterns
        .where((regex) => regex.hasMatch(name))
        .firstOrNull;
    if (suspicious ||
        quoted ||
        !significant ||
        known.contains(name) ||
        groupMatch != null) {
      rows.add([
        name,
        lines,
        stories,
        sampleStory,
        sample,
        suspicious
            ? '问号标注（占位或悬念伪称），需人工判断'
            : quoted
            ? '疑似假名/借名，需人工判断（可用 mergeInto 归并真身）'
            : known.contains(name)
            ? '已收录'
            : groupMatch != null
            ? '疑似群体称呼（规则：${groupMatch.pattern}，可在 npc_group_patterns.txt 调整）'
            : '未达收录阈值',
      ]);
      continue;
    }
    final total = avgKeys.fold<int>(0, (sum, e) => sum + e.value.toInt());
    final top = avgKeys.firstOrNull;
    final exclusive =
        top != null && (modelSpeakers[top.key]?.length ?? 99) <= avgMaxReuse;
    final stable =
        top != null &&
        exclusive &&
        top.value.toInt() >= avgCounts &&
        (total == 0 || top.value / total >= avgRatio);
    draft[name] = stable
        ? {
            'avg': top.key,
            '_evidence': {
              'lineCount': lines,
              'stories': stories,
              'avgKey': '${top.key}x${top.value}/$total',
              'modelReuse': modelSpeakers[top.key]?.length ?? 0,
              'sampleStory': sampleStory,
            },
          }
        : {
            '_evidence': {
              'lineCount': lines,
              'stories': stories,
              'sampleStory': sampleStory,
              if (top != null && !exclusive)
                'topAvgKey':
                    '${top.key}（模型复用 ${modelSpeakers[top.key]?.length ?? 0} 人，不自动绑定）',
            },
          };
  }
  await File(outPath)
      .writeAsString('${const JsonEncoder.withIndent('  ').convert(draft)}\n');
  final csv = StringBuffer(
    'name,lineCount,stories,sampleStory,sample,action\r\n',
  );
  for (final row in rows) {
    csv.writeln(
      [
        for (final cell in row)
          ((cell ?? '').toString()).startsWith(RegExp(r'[=+@\-\t\r]'))
              ? "'${cell ?? ''}"
              : '${cell ?? ''}',
      ].map((cell) => '"${cell.replaceAll('"', '""')}"').join(','),
    );
  }
  await File(csvPath).writeAsString(csv.toString());
  final totalDraft = draft.length;
  final withAvg = draft.values
      .whereType<Map<String, dynamic>>()
      .where((v) => v.containsKey('avg'))
      .length;
  stdout.writeln(
    '起草完成：$totalDraft 位建卡候选（$withAvg 位带立绘建议）；'
    '${rows.length} 条待人工判断，见 $csvPath。',
  );
  stdout.writeln('复核提示：draft.json 中 _evidence 字段仅供人工参考，确认后需整段删除。');
}
