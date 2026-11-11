import 'package:flutter/material.dart';

import '../story_player/data/story_repository.dart';
import 'app_theme.dart';
import 'archive_motion.dart';
import 'archive_widgets.dart';
import 'cache_job.dart';

class CachePage extends StatefulWidget {
  const CachePage({
    super.key,
    this.groups = const [],
    this.active = true,
    required this.cached,
    this.loading = false,
    this.progressPaths = const <String>{},
    required this.onBrowse,
    required this.onRetry,
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
  final List<StoryEntry> cached;
  final bool loading;

  /// 存有观看进度的条目路径，行内以「继续观看」标识提示。
  final Set<String> progressPaths;
  final VoidCallback onBrowse;
  final ValueChanged<CacheJob> onRetry;
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
  Widget build(BuildContext context) {
    final cachedPaths = widget.cached.map((entry) => entry.path).toSet();
    final pending = widget.jobs.values
        .where(
          (job) =>
              job.status != CacheJobStatus.completed &&
              job.status != CacheJobStatus.cancelled &&
              !cachedPaths.contains(job.entry.path),
        )
        .toList();
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
    final entries = _activity == null
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
      canPop: !widget.active || _activity == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && widget.active && _activity != null) _leaveActivity();
      },
      child: ArchivePageTransition(
        transitionKey: (_activity?.name, _activity?.entryType),
        depth: _activity == null ? 0 : 1,
        child: Column(
          children: [
            ArchivePageHeader(
              key: const Key('cache-header'),
              title: _activity?.name ?? '离线与缓存',
              subtitle: _activity == null
                  ? '${widget.cached.length} 幕已缓存${pending.isEmpty ? '' : ' · ${pending.length} 项下载任务'}'
                  : '已缓存 ${entries.length} 幕',
              leading: _activity == null
                  ? null
                  : IconButton(
                      tooltip: '返回离线与缓存',
                      onPressed: _leaveActivity,
                      icon: const Icon(Icons.arrow_back, size: 22),
                    ),
              trailing: _activity == null || entries.isEmpty
                  ? null
                  : TextButton(
                      onPressed: widget.deleting
                          ? null
                          : () => setState(() {
                              _managing = !_managing;
                              _selectedOffline.clear();
                            }),
                      child: Text(_managing ? '取消选择' : '批量管理'),
                    ),
              bottom: _managing && entries.isNotEmpty
                  ? Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        TextButton(
                          onPressed: widget.deleting
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
                          onPressed: widget.deleting || _selectedOffline.isEmpty
                              ? null
                              : () => widget.onDeleteCached(
                                  entries
                                      .where(
                                        (entry) => _selectedOffline.contains(
                                          entry.path,
                                        ),
                                      )
                                      .toList(),
                                ),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: Text('删除选中 (${_selectedOffline.length})'),
                        ),
                      ],
                    )
                  : null,
            ),
            Expanded(
              child: CustomScrollView(
                key: PageStorageKey('offline-${_activity?.name ?? 'groups'}'),
                slivers: [
                  if (_activity == null &&
                      (widget.caching || widget.message?.isNotEmpty == true))
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (widget.caching) ...[
                              ArchiveProgressIndicator(
                                value: widget.total == 0
                                    ? null
                                    : (progress / widget.total).clamp(0, 1),
                                semanticsLabel: '缓存总进度',
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '已处理 ${widget.done} / ${widget.total} 幕',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.subtext,
                                ),
                              ),
                            ],
                            if (widget.message?.isNotEmpty == true)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: SelectableText(
                                  widget.message!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.secondary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (_activity == null && pending.isNotEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                      sliver: SliverList.builder(
                        itemCount: pending.length,
                        itemBuilder: (context, index) =>
                            _jobTile(pending[index]),
                      ),
                    ),
                  if (entries.isEmpty && (_activity != null || pending.isEmpty))
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: ArchiveEmpty(
                        icon: Icons.download_for_offline_outlined,
                        title: widget.loading ? '正在读取离线档案' : '暂无离线档案',
                        message: widget.loading
                            ? '正在读取本地缓存记录。'
                            : _activity == null
                            ? '在剧情馆进入篇章，选择需要离线阅读的剧情。'
                            : '这个篇章的缓存已全部删除。',
                        action: _activity != null
                            ? null
                            : OutlinedButton.icon(
                                onPressed: widget.onBrowse,
                                icon: const Icon(
                                  Icons.library_books_outlined,
                                  size: 18,
                                ),
                                label: const Text('前往剧情馆'),
                              ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.all(20),
                      sliver: SliverList.builder(
                        itemCount: _activity == null
                            ? offlineGroups.length
                            : entries.length,
                        itemBuilder: (context, index) => _activity == null
                            ? _groupTile(offlineGroups[index])
                            : _offlineTile(entries[index]),
                      ),
                    ),
                  const SliverToBoxAdapter(
                    child: SafeArea(
                      top: false,
                      left: false,
                      right: false,
                      child: SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupTile(StoryGroup group) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: ArchivePanel(
      padding: EdgeInsets.zero,
      child: ListTile(
        key: ValueKey('offline-${group.name}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Text(group.name, style: const TextStyle(fontSize: 15)),
        subtitle: Text(
          '已缓存 ${group.entries.length} 幕',
          style: const TextStyle(fontSize: 12, color: AppColors.subtext),
        ),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: () => setState(() {
          _activity = group;
          _managing = false;
          _selectedOffline.clear();
        }),
      ),
    ),
  );

  Widget _jobTile(CacheJob job) {
    final entry = job.entry;
    final active =
        job.status == CacheJobStatus.waiting ||
        job.status == CacheJobStatus.downloading ||
        job.status == CacheJobStatus.paused;
    final status = switch (job.status) {
      CacheJobStatus.waiting => '等待中',
      CacheJobStatus.paused => '已暂停',
      CacheJobStatus.failed => '下载失败：${job.error ?? '请重试'}',
      _ => job.total == 0 ? '准备中' : '${job.done} / ${job.total}',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ArchivePanel(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.title,
                    style: const TextStyle(fontSize: 14, height: 1.5),
                  ),
                ),
                if (active)
                  IconButton(
                    tooltip:
                        '${job.control.paused ? '恢复' : '暂停'} ${entry.title}',
                    onPressed: () => widget.onToggleJob(job),
                    icon: Icon(
                      job.control.paused ? Icons.play_arrow : Icons.pause,
                    ),
                  ),
                if (job.status == CacheJobStatus.failed)
                  IconButton(
                    tooltip: '重试失败任务',
                    onPressed: () => widget.onRetry(job),
                    icon: const Icon(Icons.refresh),
                  ),
                IconButton(
                  tooltip: '删除任务 ${entry.title}',
                  onPressed: () => widget.onRemoveJob(job),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ArchiveProgressIndicator(
              value: job.total == 0
                  ? (job.status == CacheJobStatus.downloading ? null : 0)
                  : (job.done / job.total).clamp(0, 1),
              semanticsLabel: '${entry.title} 缓存进度',
            ),
            const SizedBox(height: 8),
            AnimatedDefaultTextStyle(
              duration: ArchiveMotion.duration(
                context,
                ArchiveMotion.stateDuration,
              ),
              style: DefaultTextStyle.of(context).style.copyWith(
                fontSize: 12,
                color: job.status == CacheJobStatus.failed
                    ? AppColors.danger
                    : AppColors.subtext,
              ),
              child: Text(status),
            ),
          ],
        ),
      ),
    );
  }

  Widget _offlineTile(StoryEntry entry) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: ArchivePanel(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      child: Row(
        children: [
          if (_managing)
            Checkbox(
              value: _selectedOffline.contains(entry.path),
              semanticLabel: '选择离线剧情 ${entry.title}',
              onChanged: widget.deleting
                  ? null
                  : (selected) => setState(() {
                      if (selected == true) {
                        _selectedOffline.add(entry.path);
                      } else {
                        _selectedOffline.remove(entry.path);
                      }
                    }),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.progressPaths.contains(entry.path)) ...[
                    ArchiveTag(
                      '继续观看',
                      key: ValueKey('continue-${entry.path}'),
                      color: AppColors.yellow,
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    entry.title,
                    style: const TextStyle(fontSize: 14, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
          if (!_managing) ...[
            IconButton(
              tooltip: '播放 ${entry.title}',
              // 下载任务在后台继续执行，已缓存剧情随时可以播放。
              onPressed: widget.deleting ? null : () => widget.onOpen(entry),
              icon: const Icon(Icons.play_arrow),
            ),
            IconButton(
              tooltip: '删除缓存 ${entry.title}',
              onPressed: widget.deleting
                  ? null
                  : () => widget.onDeleteCached([entry]),
              icon: const Icon(Icons.delete_outline, size: 20),
            ),
          ],
        ],
      ),
    ),
  );
}
