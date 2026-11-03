import 'package:flutter/material.dart';

import '../story_player/story_player.dart';
import 'app_theme.dart';
import 'archive_widgets.dart';
import 'cache_page.dart';
import 'settings_page.dart';

class StoryLauncher extends StatefulWidget {
  const StoryLauncher({super.key, this.repository});
  final StoryRepository? repository;

  @override
  State<StoryLauncher> createState() => _StoryLauncherState();
}

class _StoryLauncherState extends State<StoryLauncher> {
  late final AssetStore? _ownedAssets = widget.repository == null
      ? AssetStore()
      : null;
  late final StoryRepository _repository =
      widget.repository ?? StoryRepository(_ownedAssets!);
  final _search = TextEditingController();
  final _selected = <String>{};
  final _expanded = <String>{};
  List<StoryGroup>? _groups;
  StoryGroup? _activeGroup;
  String? _indexError;
  String? _playError;
  StoryEntry? _opening;
  String _filter = '';
  int _category = 0;
  int _page = 0;
  bool _selectMode = false;
  bool _busy = false;
  int _done = 0, _total = 0;

  static const _categories = ['全部', '主线篇章', '支线活动', '微型故事集', '玩法衍生篇', '其他档案'];
  static const _navigation = [
    (Icons.library_books_outlined, '剧情馆', '01'),
    (Icons.download_outlined, '离线与缓存', '02'),
    (Icons.tune, '系统设置', '03'),
  ];

  @override
  void initState() {
    super.initState();
    _loadIndex();
  }

  Future<void> _loadIndex() async {
    setState(() => _indexError = null);
    try {
      final groups = await _repository.loadIndex();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _activeGroup = groups.firstOrNull;
        if (groups.isNotEmpty) _expanded.add(groups.first.name);
      });
    } catch (e) {
      if (mounted) setState(() => _indexError = '剧情目录加载失败：$e');
    }
  }

  Future<void> _open(StoryEntry entry) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _playError = null;
      _opening = entry;
      _done = 0;
      _total = 0;
    });
    try {
      final document = await _repository.loadEntry(entry);
      if (!document.script.commands.any(
        (c) => c.tag == 'dialogue' || c.text.isNotEmpty,
      )) {
        throw const FormatException('脚本中没有可播放内容');
      }
      final prepared = await _repository.prepare(
        document,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _done = done;
              _total = total;
            });
          }
        },
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => StoryPlayer(story: prepared)),
      );
    } catch (e) {
      if (mounted) setState(() => _playError = '加载失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  int _categoryOf(StoryGroup group) => switch (group.entryType) {
    'MAINLINE' => 1,
    'ACTIVITY' => 2,
    'MINI_ACTIVITY' => 3,
    _ => 5,
  };

  List<StoryEntry> _entries(StoryGroup group) {
    final query = _filter.trim().toLowerCase();
    if (query.isEmpty || group.name.toLowerCase().contains(query)) {
      return group.entries;
    }
    return group.entries
        .where((entry) => entry.title.toLowerCase().contains(query))
        .toList();
  }

  List<StoryGroup> get _visibleGroups => (_groups ?? const <StoryGroup>[])
      .where(
        (group) =>
            (_category == 0 || _categoryOf(group) == _category) &&
            _entries(group).isNotEmpty,
      )
      .toList();

  List<StoryEntry> get _selectedEntries => [
    for (final group in _groups ?? const <StoryGroup>[])
      ...group.entries.where((entry) => _selected.contains(entry.path)),
  ];

  void _toggle(StoryEntry entry, bool selected) => setState(() {
    if (selected) {
      _selected.add(entry.path);
    } else {
      _selected.remove(entry.path);
    }
  });

  void _selectAll(List<StoryEntry> entries) => setState(() {
    if (entries.every((entry) => _selected.contains(entry.path))) {
      _selected.removeAll(entries.map((entry) => entry.path));
    } else {
      _selected.addAll(entries.map((entry) => entry.path));
    }
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 1100;
      return PopScope(
        canPop: !_busy,
        child: Scaffold(
          body: SafeArea(
            child: Stack(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (desktop) _sidebar(),
                    Expanded(
                      child: Column(
                        children: [
                          if (desktop) _topbar(),
                          Expanded(
                            child: IndexedStack(
                              index: _page,
                              children: [
                                _library(desktop),
                                CachePage(
                                  selected: _selectedEntries,
                                  onBrowse: () => setState(() {
                                    _page = 0;
                                    _selectMode = true;
                                  }),
                                ),
                                const SettingsPage(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_busy) ...[
                  const ModalBarrier(
                    dismissible: false,
                    color: Color(0xdd0a0d12),
                  ),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 430),
                        child: ArchivePanel(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Icon(
                                Icons.radar,
                                size: 48,
                                color: AppColors.muted,
                              ),
                              const SizedBox(height: 20),
                              const Text(
                                '正在准备演出',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 21,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                _opening?.title ?? '',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.secondary,
                                ),
                              ),
                              const SizedBox(height: 24),
                              LinearProgressIndicator(
                                value: _total == 0 ? null : _done / _total,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _total == 0
                                    ? '正在读取脚本与资源配置…'
                                    : '已处理 $_done / $_total 个资源',
                                style: const TextStyle(
                                  color: AppColors.secondary,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          bottomNavigationBar: desktop
              ? null
              : AbsorbPointer(
                  absorbing: _busy,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_page == 0 && _selected.isNotEmpty) _batchBar(),
                      NavigationBar(
                        selectedIndex: _page,
                        onDestinationSelected: (value) =>
                            setState(() => _page = value),
                        destinations: [
                          for (final item in _navigation)
                            NavigationDestination(
                              icon: Icon(item.$1),
                              label: item.$2,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
      );
    },
  );

  Widget _sidebar() => Container(
    key: const Key('desktop-sidebar'),
    width: 220,
    decoration: const BoxDecoration(
      color: AppColors.surface,
      border: Border(right: BorderSide(color: AppColors.border)),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 16, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Image.asset(
                            'assets/images/logo_rhodes.png',
                            width: 22,
                            height: 22,
                            fit: BoxFit.contain,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'PRTS',
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: AppTypography.bender,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 2,
                              color: AppColors.terminalWhite,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                      Text(
                        '明日方舟',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                          color: AppColors.text,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '剧情档案库',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.subtext,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                const SizedBox(height: 14),
                for (var i = 0; i < _navigation.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    child: Semantics(
                      selected: _page == i,
                      child: Material(
                        color: _page == i
                            ? AppColors.raised
                            : Colors.transparent,
                        child: InkWell(
                          onTap: () => setState(() => _page = i),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  color: _page == i
                                      ? AppColors.indicator
                                      : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _navigation[i].$1,
                                  size: 18,
                                  color: _page == i
                                      ? AppColors.text
                                      : AppColors.subtext,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _navigation[i].$2,
                                    style: TextStyle(
                                      color: _page == i
                                          ? AppColors.text
                                          : AppColors.subtext,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  _navigation[i].$3,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontFamily: AppTypography.bender,
                                    color: _page == i
                                        ? AppColors.terminalWhite
                                        : AppColors.muted,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.circle, size: 8, color: AppColors.green),
                          SizedBox(width: 6),
                          Text(
                            'PRTS-OS v4.1',
                            style: TextStyle(
                              fontSize: 10,
                              letterSpacing: 1.5,
                              color: AppColors.subtext,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 8),
                      Text(
                        '罗德岛中央情报处理系统',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.muted,
                          height: 1.5,
                        ),
                      ),
                      SizedBox(height: 10),
                      Text(
                        'SYS // ONLINE',
                        style: TextStyle(
                          fontSize: 9,
                          fontFamily: AppTypography.bender,
                          letterSpacing: 1.5,
                          color: AppColors.muted,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _topbar() => Container(
    height: 48,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    decoration: const BoxDecoration(
      color: AppColors.surface,
      border: Border(bottom: BorderSide(color: AppColors.border)),
    ),
    child: Row(
      children: [
        const Text(
          '终端系统',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.subtext,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Text('/', style: TextStyle(color: AppColors.border)),
        ),
        Text(
          _navigation[_page].$2,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.text,
          ),
        ),
        const Spacer(),
        const Text(
          'RHODES ISLAND TERMINAL',
          style: TextStyle(
            fontSize: 9,
            color: AppColors.muted,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );

  Widget _library(bool desktop) {
    final groups = _visibleGroups;
    final active = groups.contains(_activeGroup)
        ? _activeGroup
        : groups.firstOrNull;
    final catalog = CustomScrollView(
      key: PageStorageKey(desktop ? 'desktop-chapters' : 'mobile-chapters'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ArchiveHeading(
                  '剧情馆',
                  trailing: desktop
                      ? null
                      : TextButton(
                          onPressed: () => setState(() {
                            _selectMode = !_selectMode;
                          }),
                          child: Text(_selectMode ? '完成选择' : '批量管理'),
                        ),
                ),
                const SizedBox(height: 20),
                TextField(
                  key: const Key('story-search'),
                  controller: _search,
                  onChanged: (value) => setState(() => _filter = value),
                  decoration: InputDecoration(
                    hintText: '搜索篇章、关卡或剧情标题',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _filter.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            onPressed: () {
                              _search.clear();
                              setState(() => _filter = '');
                            },
                            icon: const Icon(Icons.close, size: 18),
                          ),
                  ),
                ),
                const SizedBox(height: 14),
                if (desktop)
                  Wrap(spacing: 6, runSpacing: 6, children: _categoryButtons())
                else
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(spacing: 8, children: _categoryButtons()),
                  ),
                const SizedBox(height: 14),
                Text(
                  _groups == null
                      ? 'PRTS / 剧情档案索引'
                      : '${groups.length} 个篇章 · ${groups.fold<int>(0, (sum, group) => sum + _entries(group).length)} 幕',
                  style: const TextStyle(color: AppColors.muted, fontSize: 11),
                ),
                const SizedBox(height: 14),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: Divider(height: 1)),
        _catalogBody(groups, desktop),
      ],
    );
    return Column(
      children: [
        if (_playError != null)
          Container(
            color: AppColors.danger.withValues(alpha: .08),
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _playError!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.danger,
                      fontSize: 12,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => _open(_opening!),
                  child: const Text('重试'),
                ),
                IconButton(
                  tooltip: '关闭错误提示',
                  onPressed: () => setState(() => _playError = null),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
        Expanded(
          child: desktop
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 314, child: catalog),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: active == null
                          ? const ArchiveEmpty(
                              icon: Icons.menu_book_outlined,
                              title: '等待选择篇章',
                              message: '从左侧目录选择一个篇章，查看剧情关卡。',
                            )
                          : _chapterDetail(active),
                    ),
                  ],
                )
              : catalog,
        ),
      ],
    );
  }

  List<Widget> _categoryButtons() => [
    for (var i = 0; i < _categories.length; i++)
      ChoiceChip(
        key: ValueKey('category-$i'),
        label: SizedBox(
          width:
              MediaQuery.textScalerOf(context).scale(12) *
              _categories[i].length,
          child: Text(_categories[i], textAlign: TextAlign.center),
        ),
        selected: _category == i,
        onSelected: (_) => setState(() => _category = i),
        showCheckmark: false,
        labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: _category == i ? FontWeight.w700 : FontWeight.w400,
          color: _category == i ? AppColors.onActive : AppColors.secondary,
        ),
        materialTapTargetSize: MaterialTapTargetSize.padded,
      ),
  ];

  Widget _catalogBody(List<StoryGroup> groups, bool desktop) {
    Widget? status;
    if (_indexError != null) {
      status = ArchiveEmpty(
        icon: Icons.wifi_off,
        title: '暂时无法读取目录',
        message: _indexError!,
        action: OutlinedButton.icon(
          onPressed: _loadIndex,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('重新加载目录'),
        ),
      );
    } else if (_groups == null) {
      status = const ArchiveEmpty(
        icon: Icons.hourglass_empty,
        title: '正在从 PRTS 读取剧情目录…',
        message: '首次加载需要网络连接。',
        action: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (groups.isEmpty) {
      status = ArchiveEmpty(
        icon: Icons.search_off,
        title: _category == 4 ? '玩法衍生档案待接入' : '没有匹配的剧情',
        message: _category == 4
            ? '当前索引未提供完整的玩法衍生目录，后续将在这里接入。'
            : '试试其他关键词或切换分类。',
        action: TextButton(
          onPressed: () {
            _search.clear();
            setState(() {
              _filter = '';
              _category = 0;
            });
          },
          child: const Text('查看全部剧情'),
        ),
      );
    }
    if (status != null) {
      return SliverFillRemaining(hasScrollBody: false, child: status);
    }
    return SliverPadding(
      padding: const EdgeInsets.all(14),
      sliver: SliverList.builder(
        itemCount: groups.length,
        itemBuilder: (context, index) => desktop
            ? _chapterCard(
                groups[index],
                groups[index] ==
                    (_activeGroup != null && groups.contains(_activeGroup)
                        ? _activeGroup
                        : groups.first),
              )
            : _accordion(groups[index]),
      ),
    );
  }

  Widget _chapterCard(StoryGroup group, bool active) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Material(
      color: active ? AppColors.surface : AppColors.panel,
      child: InkWell(
        onTap: () => setState(() => _activeGroup = group),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: active ? AppColors.indicator : Colors.transparent,
                width: 3,
              ),
              top: BorderSide(color: active ? AppColors.borderLight : AppColors.border),
              right: BorderSide(color: active ? AppColors.borderLight : AppColors.border),
              bottom: BorderSide(color: active ? AppColors.borderLight : AppColors.border),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _categories[_categoryOf(group)],
                style: TextStyle(
                  color: active ? AppColors.terminalWhite : AppColors.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                group.name,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: active ? AppColors.text : AppColors.secondary,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${group.entries.length} 幕',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: active ? AppColors.text : AppColors.muted,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _accordion(StoryGroup group) {
    final expanded =
        _expanded.contains(group.name) || _filter.trim().isNotEmpty;
    final entries = _entries(group);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ArchivePanel(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            Semantics(
              expanded: expanded,
              button: true,
              child: InkWell(
                key: ValueKey('chapter-${group.name}'),
                onTap: () => setState(() {
                  if (!_expanded.add(group.name)) _expanded.remove(group.name);
                }),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _categories[_categoryOf(group)],
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.8,
                                color: AppColors.terminalWhite,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              group.name,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '共 ${group.entries.length} 幕',
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.subtext,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                        color: AppColors.subtext,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (expanded) ...[
              const Divider(height: 1),
              if (_selectMode)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: _selectAllControl(entries),
                ),
              for (final entry in entries) _stageRow(entry, _selectMode),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chapterDetail(StoryGroup group) {
    final entries = _entries(group);
    return CustomScrollView(
      key: PageStorageKey('stages-${group.name}'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ArchiveTag(
                      _categories[_categoryOf(group)],
                      color: AppColors.terminalWhite,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${entries.length} 幕',
                      style: const TextStyle(
                        color: AppColors.subtext,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'SECTOR // ${group.entryType.isNotEmpty ? group.entryType : "ARCHIVE"}',
                      style: const TextStyle(
                        color: AppColors.muted,
                        letterSpacing: 1.5,
                        fontSize: 10,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  group.name,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _selectAllControl(entries),
                    FilledButton.icon(
                      onPressed: _selected.isEmpty
                          ? null
                          : () => showPreviewMessage(context, '批量缓存'),
                      icon: const Icon(Icons.download_outlined, size: 17),
                      label: Text('缓存选中项 (${_selected.length})'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _selected.isEmpty
                          ? null
                          : () => showCachePreviewConfirmation(context),
                      icon: const Icon(Icons.delete_outline, size: 17),
                      label: const Text('删除缓存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: Divider(height: 1)),
        SliverPadding(
          padding: const EdgeInsets.all(18),
          sliver: SliverList.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: ArchivePanel(
                padding: EdgeInsets.zero,
                child: _stageRow(entries[index], true),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _selectAllControl(List<StoryEntry> entries) {
    final count = entries
        .where((entry) => _selected.contains(entry.path))
        .length;
    return MergeSemantics(
      child: InkWell(
        onTap: () => _selectAll(entries),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: count == 0
                  ? false
                  : count == entries.length
                  ? true
                  : null,
              tristate: true,
              onChanged: (_) => _selectAll(entries),
            ),
            const Text(
              '全选本章',
              style: TextStyle(fontSize: 12, color: AppColors.secondary),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Widget _stageRow(StoryEntry entry, bool selecting) => Material(
    key: ValueKey(entry.path),
    color: _selected.contains(entry.path)
        ? AppColors.surface
        : Colors.transparent,
    child: InkWell(
      onTap: () {
        if (selecting) {
          _toggle(entry, !_selected.contains(entry.path));
        } else {
          _open(entry);
        }
      },
      onLongPress: () => setState(() {
        _selectMode = true;
        _selected.add(entry.path);
      }),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: _selected.contains(entry.path)
                  ? AppColors.indicator
                  : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        padding: EdgeInsets.fromLTRB(selecting ? 6 : 14, 12, 12, 12),
        child: Row(
          children: [
            if (selecting)
              Checkbox(
                value: _selected.contains(entry.path),
                semanticLabel: '选择 ${entry.title}',
                onChanged: (value) => _toggle(entry, value ?? false),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (entry.code.isNotEmpty)
                        Text(
                          entry.code,
                          style: const TextStyle(
                            fontFamily: AppTypography.bender,
                            color: AppColors.terminalWhite,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            letterSpacing: 1.0,
                          ),
                        ),
                      if (entry.tag.isNotEmpty)
                        ArchiveTag(entry.tag, color: AppColors.subtext),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    entry.name.isEmpty ? entry.title : entry.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '播放 ${entry.title}',
              onPressed: () => _open(entry),
              icon: const Icon(
                Icons.play_arrow,
                color: AppColors.terminalWhite,
                size: 22,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _batchBar() => Container(
    key: const Key('mobile-batch-bar'),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: const BoxDecoration(
      color: AppColors.surface,
      border: Border(top: BorderSide(color: AppColors.active, width: 2)),
    ),
    child: Row(
      children: [
        IconButton(
          tooltip: '取消选择',
          onPressed: () => setState(() {
            _selected.clear();
            _selectMode = false;
          }),
          icon: const Icon(Icons.close, size: 18),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            '已选 ${_selected.length} 幕',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.text,
            ),
          ),
        ),
        FilledButton.icon(
          onPressed: () => showPreviewMessage(context, '批量缓存'),
          icon: const Icon(Icons.download_outlined, size: 16),
          label: const Text('缓存（预览）'),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _search.dispose();
    _ownedAssets?.close();
    super.dispose();
  }
}
