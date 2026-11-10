import 'package:flutter/material.dart';

import '../story_player/data/asset_store.dart';
import 'app_theme.dart';
import 'archive_widgets.dart';
import 'character_archive_data.dart';
import 'character_archive_widgets.dart';
import 'character_detail_page.dart';

class CharacterArchivePage extends StatefulWidget {
  const CharacterArchivePage({
    super.key,
    required this.store,
    this.repository,
    this.active = true,
    this.onBrowse,
    this.onReplay,
  });
  final AssetStore store;
  final CharacterRepository? repository;
  final bool active;
  final VoidCallback? onBrowse;
  final CharacterReplay? onReplay;
  @override
  State<CharacterArchivePage> createState() => _CharacterArchivePageState();
}

class _CharacterArchivePageState extends State<CharacterArchivePage> {
  late final _repository = widget.repository ?? CharacterRepository();
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Future<CharacterIndex>? _future;
  String _kind = '', _profession = '', _faction = '';
  int? _rarity;
  CharacterOrder _order = CharacterOrder.appearances;
  bool _protect = true;

  @override
  void initState() {
    super.initState();
    if (widget.active) _future = _repository.loadIndex();
  }

  @override
  void didUpdateWidget(CharacterArchivePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && _future == null) _future = _repository.loadIndex();
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _change(VoidCallback change) {
    setState(change);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _clear() => _change(() {
    _search.clear();
    _kind = '';
    _profession = '';
    _faction = '';
    _rarity = null;
  });

  Future<void> _toggleProtection() async {
    if (_protect && !await confirmCharacterSpoilers(context)) return;
    if (mounted) setState(() => _protect = !_protect);
  }

  Future<void> _filters(CharacterIndex index) async {
    var profession = _profession, faction = _faction;
    var rarity = _rarity;
    final factions =
        index.people
            .where((p) => p.isOperator)
            .map((p) => p.faction)
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final classes =
        index.people
            .expand((p) => p.forms)
            .map((p) => p.profession)
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final applied = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '筛选干员',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                initialValue: profession,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '职业（包含各形态）'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部职业')),
                  ...classes.map(
                    (c) => DropdownMenuItem(value: c, child: Text(c)),
                  ),
                ],
                onChanged: (v) => update(() => profession = v ?? ''),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: faction,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '阵营'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部阵营')),
                  ...factions.map(
                    (f) => DropdownMenuItem(
                      value: f,
                      child: Text(f, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
                onChanged: (v) => update(() => faction = v ?? ''),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: rarity ?? 0,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '星级（包含各形态）'),
                items: [
                  const DropdownMenuItem(value: 0, child: Text('全部星级')),
                  for (var i = 1; i <= 6; i++)
                    DropdownMenuItem(value: i, child: Text('$i 星')),
                ],
                onChanged: (v) => update(() => rarity = v == 0 ? null : v),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('应用筛选'),
              ),
              TextButton(
                onPressed: () {
                  profession = '';
                  faction = '';
                  rarity = null;
                  Navigator.pop(context, true);
                },
                child: const Text('重置筛选'),
              ),
            ],
          ),
        ),
      ),
    );
    if (applied == true && mounted) {
      _change(() {
        _profession = profession;
        _faction = faction;
        _rarity = rarity;
        if (profession.isNotEmpty || faction.isNotEmpty || rarity != null) {
          _kind = 'operator';
        }
      });
    }
  }

  Future<void> _open(CharacterIndex index, CharacterSummary person) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CharacterDetailPage(
          person: person,
          index: index,
          repository: _repository,
          store: widget.store,
          protectSpoilers: _protect,
          onReplay: widget.onReplay,
        ),
      ),
    );
  }

  Widget _header(CharacterIndex index, int count) {
    final date =
        index.generatedAt?.toIso8601String().split('T').first ?? '随应用更新';
    final filtered =
        _profession.isNotEmpty || _faction.isNotEmpty || _rarity != null;
    return ArchivePageHeader(
      title: '人物档案',
      subtitle: '收录 ${index.people.length} 位人物 · 数据 $date',
      maxWidth: 1440,
      bottom: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _search,
              onChanged: (_) => _change(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索人物、代号或英文名',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除搜索',
                        onPressed: () => _change(_search.clear),
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final (value, label) in [
                  ('', '全部'),
                  ('operator', '干员'),
                  ('npc', '剧情角色'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _kind == value,
                    onSelected: (_) => _change(() {
                      _kind = value;
                      if (value != 'operator') {
                        _profession = '';
                        _faction = '';
                        _rarity = null;
                      }
                    }),
                  ),
                OutlinedButton.icon(
                  onPressed: () => _filters(index),
                  icon: Icon(
                    filtered ? Icons.filter_alt : Icons.filter_alt_outlined,
                    size: 18,
                  ),
                  label: Text(filtered ? '已筛选' : '筛选'),
                ),
                PopupMenuButton<CharacterOrder>(
                  tooltip: '排序',
                  initialValue: _order,
                  onSelected: (value) => _change(() => _order = value),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: CharacterOrder.appearances,
                      child: Text('出场次数'),
                    ),
                    PopupMenuItem(
                      value: CharacterOrder.firstAppearance,
                      child: Text('首次出场'),
                    ),
                    PopupMenuItem(
                      value: CharacterOrder.name,
                      child: Text('人物名字'),
                    ),
                    PopupMenuItem(
                      value: CharacterOrder.rarity,
                      child: Text('星级'),
                    ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.sort, size: 18),
                        const SizedBox(width: 6),
                        Text(switch (_order) {
                          CharacterOrder.appearances => '出场次数',
                          CharacterOrder.firstAppearance => '首次出场',
                          CharacterOrder.name => '人物名字',
                          CharacterOrder.rarity => '星级',
                        }),
                      ],
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _toggleProtection,
                  icon: Icon(
                    _protect
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                  ),
                  label: Text(_protect ? '剧透保护：开' : '剧透保护：关'),
                ),
              ],
            ),
            if (filtered)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  [
                    _profession,
                    _faction,
                    if (_rarity != null) '$_rarity 星',
                  ].where((s) => s.isNotEmpty).join(' · '),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              '显示 $count 位 · 出场统计仅包含已识别台词',
              style: const TextStyle(color: AppColors.subtext, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(CharacterIndex index, CharacterSummary person) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => _open(index, person),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: CharacterPortrait(
              store: widget.store,
              url: person.thumbnailUrl,
              name: person.name,
              fit: BoxFit.cover,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  person.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  person.isOperator
                      ? '${person.profession} · ${person.rarity} 星'
                      : '剧情角色',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.subtext,
                    fontSize: 12,
                  ),
                ),
                if (person.faction.isNotEmpty)
                  Text(
                    person.faction,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.subtext,
                      fontSize: 12,
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  '${person.storyCount} 幕 · ${person.lineCount} 句',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_future == null) return const SizedBox.shrink();
    return FutureBuilder<CharacterIndex>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return CharacterLoadError(
            onRetry: () => setState(() {
              _future = _repository.loadIndex(reload: true);
            }),
            onBrowse: widget.onBrowse,
          );
        }
        final index = snapshot.data;
        if (index == null) {
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const ArchiveHeading('人物档案', subtitle: '正在读取本地档案…'),
              const SizedBox(height: 24),
              for (var i = 0; i < 6; i++)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: SizedBox(
                    height: 72,
                    child: ColoredBox(color: AppColors.panel),
                  ),
                ),
            ],
          );
        }
        final people = index.search(
          query: _search.text,
          kind: _kind,
          profession: _profession,
          faction: _faction,
          rarity: _rarity,
          order: _order,
        );
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1440),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                final width = constraints.maxWidth - 40;
                final columns = width < 600 && scale <= 1.5
                    ? 2
                    : (width / (210 * scale.clamp(1, 1.6))).floor().clamp(1, 6);
                return CustomScrollView(
                  controller: _scroll,
                  key: const PageStorageKey('character-archive-list'),
                  slivers: [
                    SliverToBoxAdapter(child: _header(index, people.length)),
                    if (people.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text(
                                '没有找到匹配的人物',
                                style: TextStyle(fontSize: 18),
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton(
                                onPressed: _clear,
                                child: const Text('清除筛选'),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 104),
                        sliver: SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                                mainAxisExtent: 160 + 100 * scale,
                              ),
                          delegate: SliverChildBuilderDelegate(
                            (context, i) => _card(index, people[i]),
                            childCount: people.length,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}
