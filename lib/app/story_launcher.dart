import 'package:flutter/material.dart';
import '../story_player/story_player.dart';

class StoryLauncher extends StatefulWidget {
  const StoryLauncher({super.key});
  @override
  State<StoryLauncher> createState() => _StoryLauncherState();
}

class _StoryLauncherState extends State<StoryLauncher> {
  late final AssetStore _assets = AssetStore();
  late final StoryRepository _repository = StoryRepository(_assets);
  List<StoryGroup>? _groups;
  String? _indexError;
  String _filter = '';
  bool _busy = false;
  String? _error;
  int _done = 0, _total = 0;

  @override
  void initState() {
    super.initState();
    _loadIndex();
  }

  Future<void> _loadIndex() async {
    setState(() => _indexError = null);
    try {
      final groups = await _repository.loadIndex();
      if (mounted) setState(() => _groups = groups);
    } catch (e) {
      if (mounted) setState(() => _indexError = '剧情目录加载失败：$e');
    }
  }

  Future<void> _open(StoryEntry entry) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; _done = 0; _total = 0; });
    try {
      final document = await _repository.loadEntry(entry);
      if (!document.script.commands.any((c) => c.tag == 'dialogue' || c.text.isNotEmpty)) throw const FormatException('脚本中没有可播放内容');
      final prepared = await _repository.prepare(document, onProgress: (done, total) { if (mounted) setState(() { _done = done; _total = total; }); });
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StoryPlayer(story: prepared)));
    } catch (e) {
      if (mounted) setState(() => _error = '加载失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Object> get _rows {
    final filter = _filter.trim().toLowerCase();
    final rows = <Object>[];
    for (final group in _groups ?? const <StoryGroup>[]) {
      if (filter.isNotEmpty && group.name.toLowerCase().contains(filter)) {
        rows..add(group.name)..addAll(group.entries);
        continue;
      }
      final hits = group.entries.where((e) => filter.isEmpty || e.title.toLowerCase().contains(filter)).toList();
      if (hits.isNotEmpty) rows..add(group.name)..addAll(hits);
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: const Text('明日方舟剧情播放器')),
      body: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(24, 16, 24, 8), child: TextField(
          key: const Key('story-search'),
          onChanged: (value) => setState(() => _filter = value),
          decoration: InputDecoration(hintText: '搜索剧情，如 0-2 或 骑兵与猎人', prefixIcon: const Icon(Icons.search), border: const OutlineInputBorder(), isDense: true),
        )),
        Expanded(child: _body(rows)),
        if (_busy) Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
          const SizedBox(height: 8),
          Text(_total == 0 ? '正在读取脚本与资源配置…' : '已处理 $_done / $_total 个资源'),
        ])),
        if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: SelectableText(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      ])))),
    );
  }

  Widget _body(List<Object> rows) {
    if (_indexError != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        SelectableText(_indexError!, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: _loadIndex, icon: const Icon(Icons.refresh), label: const Text('重新加载目录')),
      ])));
    }
    if (_groups == null) return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 16), Text('正在从 PRTS 读取剧情目录…')]));
    if (rows.isEmpty) return const Center(child: Text('没有匹配的剧情'));
    return ListView.builder(itemCount: rows.length, itemBuilder: (context, index) {
      final row = rows[index];
      if (row is String) return Padding(padding: const EdgeInsets.fromLTRB(24, 20, 24, 4), child: Text(row, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary)));
      final entry = row as StoryEntry;
      return ListTile(
        key: ValueKey(entry.path),
        enabled: !_busy,
        contentPadding: const EdgeInsets.symmetric(horizontal: 24),
        title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.play_arrow),
        onTap: () => _open(entry),
      );
    });
  }

  @override
  void dispose() { _assets.close(); super.dispose(); }
}
