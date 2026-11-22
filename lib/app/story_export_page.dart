import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../story_player/data/asset_package.dart';
import '../story_player/data/asset_store.dart';
import '../story_player/data/media_catalog.dart';
import '../story_player/data/preview_cache.dart';
import '../story_player/data/story_repository.dart';
import 'app_theme.dart';
import 'audio_preview.dart';
import 'export_job.dart';

/// 素材导出对话框：加载清单 → 浏览/预览/勾选 → 导出 → 进度与结果。
/// 导出任务由宿主创建并持有，对话框关闭后任务继续在后台执行。
class StoryExportDialog extends StatefulWidget {
  const StoryExportDialog({
    super.key,
    required this.repository,
    required this.entry,
    required this.group,
    required this.parentPath,
    required this.cached,
    required this.appVersion,
    required this.onStartExport,
    this.existingJob,
  });

  final StoryRepository repository;
  final StoryEntry entry;
  final StoryGroup? group;
  final String parentPath;
  final bool cached;
  final String? appVersion;

  /// 由宿主创建导出任务并立即执行；返回共享任务实例用于界面监听。
  final ExportJob Function(
    AssetPackage package,
    List<AssetItem> items,
    String parentPath,
  )
  onStartExport;
  final ExportJob? existingJob;

  @override
  State<StoryExportDialog> createState() => _StoryExportDialogState();
}

class _StoryExportDialogState extends State<StoryExportDialog> {
  AssetPackage? _package;
  String? _loadError;
  PreviewCache? _previews;
  late final AudioPreviewController _audio;
  final Set<String> _selected = {};
  final Map<Uri, int?> _fileSizes = {};
  late String _parentPath;
  int _category = 0;
  int _imageFilter = 0;
  int _audioFilter = 0;
  ExportJob? _job;
  bool _opening = false;

  static const _imageCategories = [
    (Icons.image_outlined, '图片'),
    (Icons.person_outline, '立绘'),
    (Icons.music_note_outlined, '音频'),
    (Icons.description_outlined, '脚本'),
  ];

  static const _imageKinds = {
    AssetKind.background,
    AssetKind.cg,
    AssetKind.cutin,
    AssetKind.other,
  };

  AssetStore get _store => widget.repository.store;

  @override
  void initState() {
    super.initState();
    _parentPath = widget.parentPath;
    _audio = AudioPreviewController(
      resolveSource: (uri) => _store.playableUri(uri, story: widget.entry.path),
    );
    final existing = widget.existingJob;
    if (existing != null) {
      _package = existing.package;
      _job = existing;
      _selected.addAll(existing.items.map((item) => item.id));
      _previews = PreviewCache(
        (uri) => _store.loadTransient(uri, story: widget.entry.path),
      );
      _measureSizes();
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _audio.dispose();
    _previews?.clear();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final package = await widget.repository.packageEntry(
        widget.entry,
        group: widget.group,
      );
      if (!mounted) return;
      setState(() {
        _package = package;
        _selected.addAll(package.items.map((item) => item.id));
        _previews = PreviewCache(
          (uri) => _store.loadTransient(uri, story: widget.entry.path),
        );
        _loadError = null;
      });
      _measureSizes();
    } catch (error) {
      if (mounted) setState(() => _loadError = '$error');
    }
  }

  Future<void> _measureSizes() async {
    final package = _package;
    if (package == null) return;
    for (final item in package.items) {
      for (final file in item.files) {
        if (_fileSizes.containsKey(file.uri)) continue;
        final size = await _store.cachedSize(file.uri, story: package.storyPath);
        if (!mounted) return;
        setState(() => _fileSizes[file.uri] = size);
      }
    }
  }

  // ---------- 选择与统计 ----------

  bool _isSelected(AssetItem item) => _selected.contains(item.id);

  void _toggleItem(AssetItem item) => setState(() {
    if (!_selected.remove(item.id)) {
      _selected.add(item.id);
    }
  });

  int get _selectedFileCount => {
    for (final item in _package!.items)
      if (_isSelected(item))
        for (final file in item.files) '${file.uri}|${file.exportPath}',
  }.length;

  /// 已选条目的已知字节数；按来源 URI 去重，同一文件被多个条目引用
  /// 只计一次（导出也只下载一次）。返回 null 表示存在尚未统计的文件。
  (int, bool) get _selectedBytes {
    var bytes = 0;
    var unknown = false;
    final seen = <Uri>{};
    for (final item in _package!.items) {
      if (!_isSelected(item)) continue;
      for (final file in item.files) {
        if (!seen.add(file.uri)) continue;
        final size = _fileSizes[file.uri];
        if (size == null) {
          unknown = true;
        } else {
          bytes += size;
        }
      }
    }
    return (bytes, unknown);
  }

  void _selectAll() => setState(() {
    _selected
      ..clear()
      ..addAll(_package!.items.map((item) => item.id));
  });

  // ---------- 分类与筛选 ----------

  List<AssetItem> _categoryItems(int category) => switch (category) {
    // 视频与音频同属「音频」分类页（试听类媒体）。
    2 => _package!.itemsOfKinds({AssetKind.music, AssetKind.sfx, AssetKind.video}),
    0 => _package!.itemsOfKinds(_imageKinds),
    1 => _package!.itemsOfKinds({AssetKind.character}),
    _ => _package!.itemsOfKinds({AssetKind.script}),
  };

  List<AssetItem> _filteredItems() {
    final items = _categoryItems(_category);
    if (_category == 0 && _imageFilter > 0) {
      final kind = _imageKinds.elementAt(_imageFilter - 1);
      return items.where((item) => item.kind == kind).toList();
    }
    if (_category == 2 && _audioFilter > 0) {
      final kind = _audioFilter == 1 ? AssetKind.music : AssetKind.sfx;
      return items.where((item) => item.kind == kind).toList();
    }
    return items;
  }

  // ---------- 布局 ----------

  @override
  Widget build(BuildContext context) {
    final job = _job;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880, maxHeight: 660),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context),
            Flexible(
              child: job == null
                  ? _browseBody(context)
                  : _jobBody(context, job),
            ),
            _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final package = _package;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '导出《${widget.entry.title}》素材',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.of(context).text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  package == null
                      ? '正在读取剧情脚本与素材清单…'
                      : [
                        if (widget.group?.name case final group?)
                          group
                          else
                            '剧情素材',
                        '${package.items.length} 项 / ${package.fileCount} 个文件',
                        widget.cached ? '已离线缓存，无需联网' : '未缓存，预览与导出将从网络加载',
                      ].join(' · '),
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.of(context).subtext,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _browseBody(BuildContext context) {
    final package = _package;
    if (_loadError != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '无法读取素材清单：$_loadError',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.of(context).secondary,
                height: 1.6,
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
          ),
        ],
      );
    }
    if (package == null) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 176, child: _navPanel(context)),
        VerticalDivider(width: 1, color: AppColors.of(context).borderSubtle),
        Expanded(child: _itemsPanel(context)),
      ],
    );
  }

  Widget _navPanel(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < _imageCategories.length; i++)
          _navTile(context, i),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: _selected.length == _package!.items.length
                      ? null
                      : _selectAll,
                  child: const Text('全选'),
                ),
              ),
              Expanded(
                child: TextButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => setState(_selected.clear),
                  child: const Text('清空'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _navTile(BuildContext context, int index) {
    final (icon, label) = _imageCategories[index];
    final count = _categoryItems(index).length;
    final selected = _category == index;
    return Material(
      color: selected
          ? AppColors.of(context).surface
          : Colors.transparent,
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        selected: selected,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: Icon(
          icon,
          size: 18,
          color: selected
              ? AppColors.of(context).indicator
              : AppColors.of(context).subtext,
        ),
        title: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected
                ? AppColors.of(context).text
                : AppColors.of(context).secondary,
          ),
        ),
        trailing: Text(
          '$count',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.of(context).subtext,
          ),
        ),
        onTap: () => setState(() {
          _category = index;
          _imageFilter = 0;
          _audioFilter = 0;
        }),
      ),
    );
  }

  Widget _itemsPanel(BuildContext context) {
    final items = _filteredItems();
    final chips = _filterChips(context, items.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?chips,
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text(
                    '该剧情没有此类素材',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.of(context).subtext,
                    ),
                  ),
                )
              : switch (_category) {
                  2 => _audioList(context, items),
                  3 => _scriptRow(context, items.single),
                  _ => _assetGrid(context, items),
                },
        ),
      ],
    );
  }

  Widget? _filterChips(BuildContext context, int count) {
    final List<(String, int)> chips;
    if (_category == 0) {
      chips = [
        for (var i = 0; i <= _imageKinds.length; i++)
          (
            i == 0 ? '全部' : _kindLabel(_imageKinds.elementAt(i - 1)),
            _categoryItems(0)
                .where((item) =>
                    i == 0 || item.kind == _imageKinds.elementAt(i - 1))
                .length,
          ),
      ];
    } else if (_category == 2) {
      chips = [
        ('全部', _categoryItems(2).length),
        ('BGM', _categoryItems(2)
            .where((item) => item.kind == AssetKind.music)
            .length),
        ('音效', _categoryItems(2)
            .where((item) => item.kind == AssetKind.sfx)
            .length),
      ];
    } else {
      return null;
    }
    final active = _category == 0 ? _imageFilter : _audioFilter;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Wrap(
        spacing: 8,
        children: [
          for (var i = 0; i < chips.length; i++)
            ChoiceChip(
              label: Text('${chips[i].$1} ${chips[i].$2}'),
              selected: active == i,
              onSelected: (value) => setState(() {
                if (_category == 0) {
                  _imageFilter = i;
                } else {
                  _audioFilter = i;
                }
              }),
            ),
        ],
      ),
    );
  }

  Widget _assetGrid(BuildContext context, List<AssetItem> items) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 176,
        childAspectRatio: 0.92,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _AssetTile(
          item: item,
          selected: _isSelected(item),
          bytes: _itemBytes(item),
          previews: _previews!,
          onToggle: () => _toggleItem(item),
          onOpen: () => _openViewer(context, items, index),
        );
      },
    );
  }

  int? _itemBytes(AssetItem item) {
    var bytes = 0;
    for (final file in item.files) {
      final size = _fileSizes[file.uri];
      if (size == null) return null;
      bytes += size;
    }
    return bytes;
  }

  Widget _audioList(BuildContext context, List<AssetItem> items) {
    return Scrollbar(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return _AudioTile(
            item: item,
            selected: _isSelected(item),
            bytes: _itemBytes(item),
            audio: _audio,
            onToggle: () => _toggleItem(item),
          );
        },
      ),
    );
  }

  Widget _scriptRow(BuildContext context, AssetItem item) {
    final bytes = _itemBytes(item);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListTile(
        shape: RoundedRectangleBorder(
          side: BorderSide(color: AppColors.of(context).borderSubtle),
        ),
        leading: Icon(Icons.description_outlined, color: AppColors.of(context).subtext),
        title: Text(item.title),
        subtitle: Text(
          '原始剧情脚本${bytes == null ? '' : ' · ${_formatBytes(bytes)}'}',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.of(context).subtext,
          ),
        ),
        trailing: Checkbox(
          value: _isSelected(item),
          onChanged: (_) => _toggleItem(item),
        ),
        onTap: () => _toggleItem(item),
      ),
    );
  }

  Future<void> _openViewer(
    BuildContext context,
    List<AssetItem> items,
    int index,
  ) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => _AssetImageViewer(
        items: items,
        initialIndex: index,
        previews: _previews!,
        bytes: (item) => _itemBytes(item),
        isSelected: _isSelected,
        onSelect: (item, value) => setState(() {
          if (value) {
            _selected.add(item.id);
          } else {
            _selected.remove(item.id);
          }
        }),
      ),
    );
  }

  // ---------- 导出任务视图 ----------

  Widget _jobBody(BuildContext context, ExportJob job) {
    return AnimatedBuilder(
      animation: job,
      builder: (context, _) {
        switch (job.status) {
          case ExportJobStatus.running:
            return _jobRunning(context, job);
          case ExportJobStatus.completed:
            return _jobCompleted(context, job);
          case ExportJobStatus.failed:
            return _jobFailed(context, job);
          case ExportJobStatus.cancelled:
            return _jobCancelled(context);
        }
      },
    );
  }

  Widget _jobRunning(BuildContext context, ExportJob job) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('正在导出素材…', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 20),
          // 任务刚建立时 total 为 0，用有界值代替 indeterminate，避免无
          // 限转圈的持续动画干扰界面与测试。
          LinearProgressIndicator(
            value: job.total == 0 ? 0 : job.progress,
            minHeight: 4,
          ),
          const SizedBox(height: 12),
          Text(
            '${job.done} / ${job.total} 个文件 · ${_formatBytes(job.bytes)}',
            style: TextStyle(fontSize: 12, color: AppColors.of(context).subtext),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('后台继续'),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () => job.control.cancel(),
                child: const Text('取消导出'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _jobCompleted(BuildContext context, ExportJob job) {
    final result = job.result!;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle_outline,
                  size: 22, color: AppColors.of(context).green),
              const SizedBox(width: 8),
              Text(
                result.completed ? '素材已导出' : '导出完成，${result.failures.length} 个文件失败',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '${result.fileCount} 个文件 · ${_formatBytes(result.totalBytes)}\n${result.rootPath}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: AppColors.of(context).subtext,
              height: 1.6,
            ),
          ),
          if (result.failures.isNotEmpty) ...[
            const SizedBox(height: 16),
            Flexible(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 120),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: AppColors.of(context).surface),
                child: ListView(
                  children: [
                    for (final failure in result.failures.take(12))
                      Text(
                        failure.toString(),
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.of(context).danger,
                          height: 1.5,
                        ),
                      ),
                    if (result.failures.length > 12)
                      Text(
                        '……等 ${result.failures.length} 个文件失败，详见 manifest.json',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.of(context).danger,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _opening ? null : () => _openExportFolder(job),
                icon: _opening
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.folder_open, size: 18),
                label: const Text('打开文件夹'),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _jobFailed(BuildContext context, ExportJob job) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('导出失败', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Text(
            job.error ?? '未知错误',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: AppColors.of(context).danger,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 24),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _jobCancelled(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('已取消导出', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(
            '未完成的文件已清理。',
            style: TextStyle(fontSize: 12, color: AppColors.of(context).subtext),
          ),
          const SizedBox(height: 24),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _openExportFolder(ExportJob job) async {
    setState(() => _opening = true);
    try {
      await job.target.openInFileManager();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开导出目录：$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  // ---------- 底栏 ----------

  Widget _footer(BuildContext context) {
    final package = _package;
    final job = _job;
    final exporting = job != null;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.of(context).borderSubtle)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.folder_outlined,
                  size: 16, color: AppColors.of(context).subtext),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '保存到 $_parentPath${_parentPath.isEmpty ? '' : '/'}${exportDirectoryName(groupName: widget.group?.name ?? '', title: widget.entry.title)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: AppColors.of(context).secondary),
                ),
              ),
              TextButton(
                onPressed: exporting ? null : _pickDirectory,
                child: const Text('更改'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '素材版权归鹰角网络所有，仅供个人收藏与学习使用，请勿用于商业用途。',
            style: TextStyle(
              fontSize: 11,
              color: AppColors.of(context).muted,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: package == null
                    ? const SizedBox.shrink()
                    : Text(
                        _selectionSummary(),
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.of(context).subtext,
                        ),
                      ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: !exporting && package != null && _selected.isNotEmpty && _parentPath.isNotEmpty
                    ? _startExport
                    : null,
                child: Text(_exportButtonLabel()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _selectionSummary() {
    final (bytes, unknown) = _selectedBytes;
    final files = _selectedFileCount;
    if (_selected.isEmpty) return '未选择素材';
    final known = unknown
        ? bytes > 0 ? '已选 ${_selected.length} 项 · 已统计 ${_formatBytes(bytes)}' : '已选 ${_selected.length} 项'
        : '已选 ${_selected.length} 项 · ${_formatBytes(bytes)}';
    return '$known / $files 个文件';
  }

  String _exportButtonLabel() {
    if (_job != null) return '正在导出…';
    if (_selected.isEmpty) return '导出';
    return '导出 ${_selected.length} 项';
  }

  Future<void> _pickDirectory() async {
    final path = await getDirectoryPath(
      confirmButtonText: '选择此目录',
      initialDirectory: _parentPath.isEmpty ? null : _parentPath,
    );
    if (path != null) setState(() => _parentPath = path);
  }

  void _startExport() {
    final package = _package!;
    final items = [
      for (final item in package.items)
        if (_isSelected(item)) item,
    ];
    final job = widget.onStartExport(package, items, _parentPath);
    setState(() => _job = job);
  }
}

// ---------- 缩略图卡片 ----------

class _AssetTile extends StatefulWidget {
  const _AssetTile({
    required this.item,
    required this.selected,
    required this.bytes,
    required this.previews,
    required this.onToggle,
    required this.onOpen,
  });

  final AssetItem item;
  final bool selected;
  final int? bytes;
  final PreviewCache previews;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  @override
  State<_AssetTile> createState() => _AssetTileState();
}

class _AssetTileState extends State<_AssetTile> {
  Uint8List? _bytes;
  Object? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_AssetTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.preview != widget.item.preview) {
      _bytes = null;
      _error = null;
      _load();
    }
  }

  /// 加载在 build 外完成并回写状态；预览字节有 LRU 缓存，滚动回来不重下。
  void _load() {
    if (_loading) return;
    _loading = true;
    widget.previews.load(widget.item.preview).then((bytes) {
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _error = null;
        _loading = false;
      });
    }).catchError((Object error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final colors = AppColors.of(context);
    return Material(
      color: colors.panel,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: widget.selected ? colors.indicator : colors.borderSubtle,
          width: widget.selected ? 1.6 : 1,
        ),
      ),
      child: InkWell(
        onTap: widget.onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 96,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: Container(
                      color: colors.surface,
                      child: _thumbnail(context),
                    ),
                  ),
                  if (item.kind == AssetKind.character && item.files.length > 1)
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        color: colors.canvas.withValues(alpha: .78),
                        child: Text(
                          '差分 ${item.files.length - 1}',
                          style: TextStyle(
                            fontSize: 10,
                            color: colors.subtext,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.text,
                        height: 1.2,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: Checkbox(
                      value: widget.selected,
 onChanged: (_) => widget.onToggle(),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                widget.bytes == null ? '大小待统计' : _formatBytes(widget.bytes!),
                style: TextStyle(fontSize: 11, color: colors.subtext),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumbnail(BuildContext context) {
    final colors = AppColors.of(context);
    if (_error != null) {
      return TextButton.icon(
        onPressed: () => setState(() {
          _error = null;
          _bytes = null;
          _load();
        }),
        icon: const Icon(Icons.refresh, size: 14),
        label: const Text('加载失败，重试'),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: const TextStyle(fontSize: 11),
        ),
      );
    }
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        cacheWidth: 320,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        // 解码失败在 errorBuilder 里静默降级；不在 build 中回写状态。
        errorBuilder: (_, _, _) => const Icon(
          Icons.broken_image_outlined,
          size: 26,
          color: Color(0x66ffffff),
        ),
      );
    }
    if (!_loading) _load();
    return Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: colors.subtext),
      ),
    );
  }
}

// ---------- 音频行 ----------

class _AudioTile extends StatelessWidget {
  const _AudioTile({
    required this.item,
    required this.selected,
    required this.bytes,
    required this.audio,
    required this.onToggle,
  });

  final AssetItem item;
  final bool selected;
  final int? bytes;
  final AudioPreviewController audio;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // 视频素材不支持 30 秒音频试听：按钮置灰，条目只提供勾选导出。
    final isVideo = item.kind == AssetKind.video;
    return AnimatedBuilder(
      animation: audio,
      builder: (context, _) {
        final playing = audio.isPlaying(item.id);
        final ended = audio.playingId == item.id && audio.ended;
        final error = audio.errorOf(item.id);
        return ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          leading: IconButton(
            tooltip: isVideo ? '视频素材不支持试听' : (playing ? '停止试听' : '试听 30 秒'),
            onPressed: isVideo ? null : () => audio.toggle(item.id, item.preview),
            icon: Icon(
              isVideo
                  ? Icons.movie_outlined
                  : playing
                  ? Icons.stop_circle_outlined
                  : Icons.play_circle_outline,
              size: 26,
              color: playing ? colors.indicator : colors.secondary,
            ),
          ),
          title: Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: playing
              ? Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: (audio.position.inMilliseconds /
                                AudioPreviewController.limit.inMilliseconds)
                            .clamp(0.0, 1.0),
                        minHeight: 2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_clock(audio.position)} / 0:30',
                      style: TextStyle(fontSize: 11, color: colors.subtext),
                    ),
                  ],
                )
                  : Text(
                  ended
                      ? '试听结束，点击重新播放'
                      : error != null
                      ? '无法试听'
                      : [
                          _kindLabel(item.kind),
                          if (item.files.length > 1) '含 ${item.files.length} 个文件',
                          if (bytes != null) _formatBytes(bytes!),
                        ].join(' · '),
                  style: TextStyle(fontSize: 11, color: colors.subtext),
                ),
          trailing: Checkbox(value: selected, onChanged: (_) => onToggle()),
          onTap: isVideo ? null : () => audio.toggle(item.id, item.preview),
        );
      },
    );
  }

  static String _clock(Duration duration) {
    final seconds = duration.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

// ---------- 大图预览 ----------

class _AssetImageViewer extends StatefulWidget {
  const _AssetImageViewer({
    required this.items,
    required this.initialIndex,
    required this.previews,
    required this.bytes,
    required this.isSelected,
    required this.onSelect,
  });

  final List<AssetItem> items;
  final int initialIndex;
  final PreviewCache previews;
  final int? Function(AssetItem item) bytes;
  final bool Function(AssetItem item) isSelected;
  final void Function(AssetItem item, bool value) onSelect;

  @override
  State<_AssetImageViewer> createState() => _AssetImageViewerState();
}

class _AssetImageViewerState extends State<_AssetImageViewer> {
  late final PageController _controller;
  late int _index;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_index];
    final colors = AppColors.of(context);
    return KeyboardListener(
      autofocus: true,
      focusNode: _focusNode,
      onKeyEvent: (event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) _move(-1);
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) _move(1);
        }
      },
      child: Dialog(
        backgroundColor: const Color(0xe6101014),
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: double.infinity,
          height: double.infinity,
          child: Stack(
            children: [
              PageView.builder(
                controller: _controller,
                itemCount: widget.items.length,
                onPageChanged: (index) => setState(() => _index = index),
                itemBuilder: (context, index) => _ViewerImage(
                  item: widget.items[index],
                  previews: widget.previews,
                ),
              ),
              if (widget.items.length > 1) ...[
                Positioned(
                  left: 8,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: IconButton(
                      tooltip: '上一项',
                      onPressed: () => _move(-1),
                      icon: const Icon(Icons.chevron_left, size: 30, color: Colors.white70),
                    ),
                  ),
                ),
                Positioned(
                  right: 8,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: IconButton(
                      tooltip: '下一项',
                      onPressed: () => _move(1),
                      icon: const Icon(Icons.chevron_right, size: 30, color: Colors.white70),
                    ),
                  ),
                ),
              ],
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  tooltip: '关闭预览',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: Colors.white70),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: const Color(0xcc101014),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [
                                '${_index + 1} / ${widget.items.length}',
                                if (widget.bytes(item) case final bytes?)
                                  _formatBytes(bytes),
                                item.files.first.uri.host,
                              ].join(' · '),
                              style: TextStyle(
                                color: colors.onActive.withValues(alpha: .7),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        children: [
                          Text(
                            '包含在导出中',
                            style: TextStyle(color: colors.onActive, fontSize: 12),
                          ),
                          Checkbox(
                            value: widget.isSelected(item),
                            onChanged: (value) {
                              widget.onSelect(item, value ?? false);
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _move(int delta) {
    final target = (_index + delta).clamp(0, widget.items.length - 1);
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }
}

class _ViewerImage extends StatefulWidget {
  const _ViewerImage({required this.item, required this.previews});

  final AssetItem item;
  final PreviewCache previews;

  @override
  State<_ViewerImage> createState() => _ViewerImageState();
}

class _ViewerImageState extends State<_ViewerImage> {
  Uint8List? _bytes;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.previews.load(widget.item.preview);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const Icon(
              Icons.broken_image_outlined,
              size: 48,
              color: Colors.white38,
            ),
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: TextButton.icon(
          onPressed: () => setState(() {
            _error = null;
            _load();
          }),
          icon: const Icon(Icons.refresh, size: 18, color: Colors.white70),
          label: const Text(
            '加载失败，点击重试',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      );
    }
    return const Center(
      child: SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
      ),
    );
  }
}

// ---------- 公共 ----------

String _kindLabel(AssetKind kind) => switch (kind) {
      AssetKind.background => '背景',
      AssetKind.cg => 'CG',
      AssetKind.cutin => '切入图',
      AssetKind.other => '道具图',
      AssetKind.character => '立绘',
      AssetKind.music => 'BGM',
      AssetKind.sfx => '音效',
      AssetKind.script => '脚本',
      AssetKind.video => '视频',
    };

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
