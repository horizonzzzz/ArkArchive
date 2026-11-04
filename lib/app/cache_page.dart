import 'package:flutter/material.dart';

import '../story_player/data/story_repository.dart';
import 'app_theme.dart';
import 'archive_widgets.dart';
import 'cache_job.dart';

class CachePage extends StatefulWidget {
  const CachePage({
    super.key,
    this.groups = const [],
    this.active = true,
    required this.selected,
    required this.cached,
    required this.onBrowse,
    required this.onCache,
    required this.onOpen,
    required this.jobs,
    required this.onToggleJob,
    required this.onRemoveJob,
    required this.onDeleteCached,
    required this.deleting,
    required this.caching,
    required this.done,
    required this.total,
    this.message,
  });
  final List<StoryGroup> groups;
  final bool active;
  final List<StoryEntry> selected;
  final List<StoryEntry> cached;
  final VoidCallback onBrowse;
  final VoidCallback onCache;
  final ValueChanged<StoryEntry> onOpen;
  final Map<String, CacheJob> jobs;
  final ValueChanged<CacheJob> onToggleJob;
  final ValueChanged<CacheJob> onRemoveJob;
  final ValueChanged<List<StoryEntry>> onDeleteCached;
  final bool deleting;
  final bool caching;
  final int done;
  final int total;
  final String? message;

  @override
  State<CachePage> createState() => _CachePageState();
}

class _CachePageState extends State<CachePage> {
  int _tab = 0;
  bool _managing = false;
  final _selectedOffline = <String>{};
  StoryGroup? _activity;

  void _leaveActivity() => setState(() {
    _activity = null;
    _managing = false;
    _selectedOffline.clear();
  });

  @override
  void didUpdateWidget(covariant CachePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selectedOffline.retainAll(widget.cached.map((entry) => entry.path));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final padding = constraints.maxWidth < 600 ? 16.0 : 28.0;
      final cachedPaths = widget.cached.map((entry) => entry.path).toSet();
      final pending = <String, StoryEntry>{
        for (final entry in widget.selected) entry.path: entry,
        for (final job in widget.jobs.values)
          if (job.status != CacheJobStatus.completed &&
              job.status != CacheJobStatus.cancelled)
            job.entry.path: job.entry,
      }.values.where((entry) => !cachedPaths.contains(entry.path)).toList();
      final offlineGroups = <StoryGroup>[];
      final ungrouped = {for (final entry in widget.cached) entry.path: entry};
      for (final group in widget.groups) {
        final entries = <StoryEntry>[
          for (final entry in group.entries) ?ungrouped.remove(entry.path),
        ];
        if (entries.isNotEmpty) {
          offlineGroups.add(
            StoryGroup(group.name, entries, entryType: group.entryType),
          );
        }
      }
      if (ungrouped.isNotEmpty) {
        offlineGroups.add(StoryGroup('其他离线剧情', ungrouped.values.toList()));
      }
      final entries = _tab == 0
          ? pending
          : _activity == null
          ? widget.cached
          : offlineGroups
                    .where(
                      (group) =>
                          group.name == _activity!.name &&
                          group.entryType == _activity!.entryType,
                    )
                    .firstOrNull
                    ?.entries ??
                const <StoryEntry>[];
      final locked = widget.deleting;
      final progress = widget.jobs.values.fold<double>(
        0,
        (sum, job) =>
            sum +
            (job.status == CacheJobStatus.completed
                ? 1
                : job.total == 0
                ? 0
                : job.done / job.total),
      );
      return PopScope(
        canPop: !widget.active || _tab != 1 || _activity == null,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && widget.active && _tab == 1 && _activity != null) {
            _leaveActivity();
          }
        },
        child: CustomScrollView(
          key: PageStorageKey(
            _tab == 0
                ? 'cache-scroll'
                : 'offline-${_activity?.name ?? 'groups'}',
          ),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(padding, padding, padding, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const ArchiveHeading('离线与缓存'),
                    const SizedBox(height: 20),
                    if (widget.caching) ...[
                      LinearProgressIndicator(
                        value: widget.total == 0
                            ? null
                            : (progress / widget.total).clamp(0, 1),
                        semanticsLabel: '缓存总进度',
                      ),
                      const SizedBox(height: 8),
                      Text('已处理 ${widget.done} / ${widget.total} 幕'),
                      const SizedBox(height: 16),
                    ],
                    if (widget.message != null) ...[
                      SelectableText(widget.message!),
                      const SizedBox(height: 16),
                    ],
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: Text('待缓存 (${pending.length})'),
                          selected: _tab == 0,
                          onSelected: (_) => setState(() => _tab = 0),
                        ),
                        ChoiceChip(
                          label: const Text('已离线'),
                          selected: _tab == 1,
                          onSelected: (_) => setState(() => _tab = 1),
                        ),
                      ],
                    ),
                    if (_tab == 1 && _activity != null) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _leaveActivity,
                          icon: const Icon(Icons.arrow_back),
                          label: const Text('返回已离线'),
                        ),
                      ),
                      ArchiveHeading(
                        _activity!.name,
                        subtitle: '已离线 · ${entries.length} 幕',
                      ),
                    ],
                    if (_tab == 1 &&
                        _activity != null &&
                        entries.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          TextButton(
                            onPressed: locked
                                ? null
                                : () => setState(() {
                                    _managing = !_managing;
                                    _selectedOffline.clear();
                                  }),
                            child: Text(_managing ? '取消选择' : '批量管理'),
                          ),
                          if (_managing) ...[
                            TextButton(
                              onPressed: locked
                                  ? null
                                  : () => setState(() {
                                      if (_selectedOffline.length ==
                                          entries.length) {
                                        _selectedOffline.clear();
                                      } else {
                                        _selectedOffline.addAll(
                                          entries.map((entry) => entry.path),
                                        );
                                      }
                                    }),
                              child: Text(
                                _selectedOffline.length == entries.length
                                    ? '取消全选'
                                    : '全选',
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: locked || _selectedOffline.isEmpty
                                  ? null
                                  : () => widget.onDeleteCached(
                                      entries
                                          .where(
                                            (entry) => _selectedOffline
                                                .contains(entry.path),
                                          )
                                          .toList(),
                                    ),
                              icon: const Icon(Icons.delete_outline),
                              label: Text('删除选中 (${_selectedOffline.length})'),
                            ),
                          ],
                        ],
                      ),
                    ],
                    const SizedBox(height: 14),
                  ],
                ),
              ),
            ),
            if (entries.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _tab == 1
                    ? const ArchiveEmpty(
                        icon: Icons.cloud_off_outlined,
                        title: '暂无离线档案',
                        message: '已下载完成的剧情剧目将在此归档呈现。',
                      )
                    : ArchiveEmpty(
                        icon: Icons.download_for_offline_outlined,
                        title: '待缓存清单为空',
                        message: '在剧情馆选择关卡后，可以在此统一发起离线存储。',
                        action: FilledButton.icon(
                          onPressed: widget.onBrowse,
                          icon: const Icon(
                            Icons.library_books_outlined,
                            size: 18,
                          ),
                          label: const Text('前往剧情馆'),
                        ),
                      ),
              )
            else if (_tab == 1 && _activity == null)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: padding),
                sliver: SliverList.builder(
                  itemCount: offlineGroups.length,
                  itemBuilder: (context, index) {
                    final group = offlineGroups[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: ArchivePanel(
                        padding: EdgeInsets.zero,
                        child: Material(
                          color: Colors.transparent,
                          child: ListTile(
                            key: ValueKey('offline-${group.name}'),
                            title: Text(group.name),
                            subtitle: Text('已离线 ${group.entries.length} 幕'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => setState(() {
                              _activity = group;
                              _managing = false;
                              _selectedOffline.clear();
                            }),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              )
            else ...[
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: padding),
                sliver: SliverList.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final job = _tab == 0 ? widget.jobs[entry.path] : null;
                    final managing = _tab == 1 && _managing;
                    final status = switch (job?.status) {
                      CacheJobStatus.waiting => '等待中',
                      CacheJobStatus.paused => '已暂停',
                      CacheJobStatus.failed => '失败：${job!.error}',
                      _ =>
                        job?.total == 0
                            ? '准备中'
                            : '${job?.done} / ${job?.total}',
                    };
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: ArchivePanel(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            if (managing)
                              Checkbox(
                                value: _selectedOffline.contains(entry.path),
                                semanticLabel: '选择离线剧情 ${entry.title}',
                                onChanged: locked
                                    ? null
                                    : (selected) => setState(() {
                                        if (selected == true) {
                                          _selectedOffline.add(entry.path);
                                        } else {
                                          _selectedOffline.remove(entry.path);
                                        }
                                      }),
                              )
                            else
                              const Icon(
                                Icons.description_outlined,
                                color: AppColors.subtext,
                                size: 18,
                              ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.title,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.text,
                                    ),
                                  ),
                                  if (job != null) ...[
                                    const SizedBox(height: 6),
                                    LinearProgressIndicator(
                                      value: job.total == 0
                                          ? (job.status ==
                                                    CacheJobStatus.downloading
                                                ? null
                                                : 0)
                                          : job.done / job.total,
                                      semanticsLabel: '${entry.title} 缓存进度',
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      status,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.subtext,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (job == null && !managing)
                              ArchiveTag(
                                _tab == 1 ? '已缓存' : '待缓存',
                                color: _tab == 1
                                    ? AppColors.terminalWhite
                                    : AppColors.yellow,
                              ),
                            if (widget.caching &&
                                job != null &&
                                (job.status == CacheJobStatus.waiting ||
                                    job.status == CacheJobStatus.downloading ||
                                    job.status == CacheJobStatus.paused))
                              IconButton(
                                tooltip:
                                    '${job.control.paused ? '恢复' : '暂停'} ${entry.title}',
                                onPressed: () => widget.onToggleJob(job),
                                icon: Icon(
                                  job.control.paused
                                      ? Icons.play_arrow
                                      : Icons.pause,
                                ),
                              ),
                            if (job != null)
                              IconButton(
                                tooltip: '删除任务 ${entry.title}',
                                onPressed: () => widget.onRemoveJob(job),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            if (_tab == 1 && !managing) ...[
                              IconButton(
                                tooltip: '播放 ${entry.title}',
                                onPressed: locked || widget.caching
                                    ? null
                                    : () => widget.onOpen(entry),
                                icon: const Icon(Icons.play_arrow),
                              ),
                              IconButton(
                                tooltip: '删除缓存 ${entry.title}',
                                onPressed: locked
                                    ? null
                                    : () => widget.onDeleteCached([entry]),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_tab == 0)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(padding, 8, padding, 16),
                    child: FilledButton.icon(
                      onPressed:
                          locked || widget.caching || widget.selected.isEmpty
                          ? null
                          : widget.onCache,
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: Text('缓存 ${widget.selected.length} 幕'),
                    ),
                  ),
                ),
            ],
          ],
        ),
      );
    },
  );
}
