import 'package:material_ui/material_ui.dart';

import 'editor_project.dart';

/// 剧本台：对白表格与批量改词/替换说话人（P1-6，桌面端优先）。
class EditorScriptView extends StatefulWidget {
  const EditorScriptView({
    super.key,
    required this.project,
    required this.activeScene,
    required this.compact,
    required this.formVersion,
    required this.onEditRow,
    required this.onBatchReplaceSpeaker,
    required this.onJumpToRow,
    required this.onExportScript,
  });

  final EditorProject project;
  final int activeScene;
  final bool compact;
  final int formVersion;
  final void Function(ScriptRowRef row, {String? speaker, String? text})
  onEditRow;
  final void Function(List<ScriptRowRef> rows, String speaker)
  onBatchReplaceSpeaker;
  final void Function(ScriptRowRef row) onJumpToRow;
  final void Function(String format) onExportScript;

  @override
  State<EditorScriptView> createState() => _EditorScriptViewState();
}

class _EditorScriptViewState extends State<EditorScriptView> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _batchSpeaker = TextEditingController();
  bool _onlyCurrentScene = false;
  final Set<String> _selectedKeys = {};

  @override
  void dispose() {
    _search.dispose();
    _batchSpeaker.dispose();
    super.dispose();
  }

  String _rowId(ScriptRowRef row) =>
      '${row.sceneIndex}:${row.beatIndex}:${row.commandIndex}';

  List<ScriptRowRef> _filteredRows() {
    final all = collectScriptRows(
      widget.project,
      sceneIndex: _onlyCurrentScene ? widget.activeScene : null,
    );
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return all;
    return [
      for (final row in all)
        if (row.speaker.toLowerCase().contains(q) ||
            row.text.toLowerCase().contains(q) ||
            row.sceneTitle.toLowerCase().contains(q) ||
            row.beatTitle.toLowerCase().contains(q))
          row,
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (widget.compact) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.table_rows_outlined, size: 36),
              const SizedBox(height: 10),
              Text(
                '剧本表格仅在桌面宽屏提供',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                '移动端请在演出台直接编辑对白，或在桌面端使用批量改词与导出台本。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }

    final rows = _filteredRows();
    final validIds = {for (final r in rows) _rowId(r)};
    _selectedKeys.removeWhere((id) => !validIds.contains(id));
    final allSelected =
        rows.isNotEmpty && _selectedKeys.length == rows.length;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 剧本台工具栏（对齐原型 #view-script）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 240,
                child: TextField(
                  key: const ValueKey('script-search'),
                  controller: _search,
                  decoration: InputDecoration(
                    hintText: '搜索台词 / 说话人 / 分镜',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () {
                              _search.clear();
                              setState(() {});
                            },
                          ),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              FilterChip(
                label: const Text('仅当前幕'),
                selected: _onlyCurrentScene,
                onSelected: (v) => setState(() => _onlyCurrentScene = v),
              ),
              Text(
                '已选 ${_selectedKeys.length} / ${rows.length} 条',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              SizedBox(
                width: 170,
                child: TextField(
                  key: const ValueKey('script-batch-speaker'),
                  controller: _batchSpeaker,
                  decoration: const InputDecoration(
                    hintText: '批量替换说话人',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              FilledButton.tonal(
                key: const ValueKey('script-batch-apply'),
                onPressed: _selectedKeys.isEmpty
                    ? null
                    : () {
                        final target = [
                          for (final r in rows)
                            if (_selectedKeys.contains(_rowId(r))) r,
                        ];
                        widget.onBatchReplaceSpeaker(
                          target,
                          _batchSpeaker.text.trim(),
                        );
                      },
                child: const Text('批量替换说话人'),
              ),
              PopupMenuButton<String>(
                tooltip: '导出台本',
                onSelected: widget.onExportScript,
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'txt', child: Text('导出台本 (.txt)')),
                  PopupMenuItem(value: 'csv', child: Text('导出对白表 (.csv)')),
                  PopupMenuItem(value: 'srt', child: Text('导出字幕 (.srt)')),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.download_outlined, size: 16),
                      SizedBox(width: 6),
                      Text('导出台本'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // 表头
        Container(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                child: Checkbox(
                  key: const ValueKey('script-select-all'),
                  value: allSelected,
                  tristate: true,
                  onChanged: rows.isEmpty
                      ? null
                      : (_) => setState(() {
                          if (allSelected) {
                            _selectedKeys.clear();
                          } else {
                            _selectedKeys
                              ..clear()
                              ..addAll(validIds);
                          }
                        }),
                ),
              ),
              const SizedBox(
                width: 165,
                child: Text(
                  '位置（幕 / 分镜）',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              const SizedBox(
                width: 150,
                child: Text(
                  '说话人',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '台词 / 舞台文字（行内即改 · 双击定位演出台）',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                ),
              ),
              const SizedBox(width: 68, child: Text('类型', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
            ],
          ),
        ),
        // 表格主体
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    '没有匹配的台词',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: scheme.outlineVariant),
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    final id = _rowId(row);
                    final checked = _selectedKeys.contains(id);
                    final beat = widget
                        .project
                        .scenes[row.sceneIndex]
                        .beats[row.beatIndex];
                    return GestureDetector(
                      onDoubleTap: () => widget.onJumpToRow(row),
                      child: Container(
                        color: checked
                            ? scheme.primaryContainer.withValues(alpha: 0.16)
                            : null,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 36,
                              child: Checkbox(
                                value: checked,
                                onChanged: (v) => setState(() {
                                  if (v == true) {
                                    _selectedKeys.add(id);
                                  } else {
                                    _selectedKeys.remove(id);
                                  }
                                }),
                              ),
                            ),
                            SizedBox(
                              width: 165,
                              child: InkWell(
                                onTap: () => widget.onJumpToRow(row),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          width: 8,
                                          height: 8,
                                          margin: const EdgeInsets.only(
                                            right: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Color(
                                              editorMarkerColors[beat
                                                      .marker
                                                      .color] ??
                                                  0xFFA5C7D5,
                                            ),
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            '${row.sceneTitle} / ${row.beatTitle}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          ),
                                        ),
                                      ],
                                    ),
                                    Text(
                                      '指令 #${row.commandIndex + 1}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 150,
                              child: row.isDialogue
                                  ? TextFormField(
                                      key: ValueKey((
                                        'script-speaker',
                                        widget.formVersion,
                                        id,
                                      )),
                                      initialValue: row.speaker,
                                      decoration: const InputDecoration(
                                        hintText: '旁白',
                                        isDense: true,
                                        border: OutlineInputBorder(),
                                      ),
                                      onChanged: (v) => widget.onEditRow(
                                        row,
                                        speaker: v,
                                      ),
                                    )
                                  : Text(
                                      '舞台文字',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextFormField(
                                key: ValueKey((
                                  'script-text',
                                  widget.formVersion,
                                  id,
                                )),
                                initialValue: row.text,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (v) =>
                                    widget.onEditRow(row, text: v),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 60,
                              child: Row(
                                children: [
                                  IconButton(
                                    tooltip: '定位到演出台',
                                    visualDensity: VisualDensity.compact,
                                    iconSize: 18,
                                    onPressed: () => widget.onJumpToRow(row),
                                    icon: const Icon(Icons.open_in_new),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
