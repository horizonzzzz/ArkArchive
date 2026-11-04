import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../story_player/story_player.dart';
import 'app_theme.dart';
import 'archive_widgets.dart';
import 'cache_page.dart';
import 'cache_job.dart';
import '../story_player/data/cache_control.dart';
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
  List<StoryGroup>? _groups;
  StoryGroup? _activeGroup;
  String? _indexError;
  String? _playError;
  StoryEntry? _opening;
  String _filter = '';
  int _category = 0;
  int _page = 0;
  bool _busy = false;
  int _done = 0, _total = 0;
  Set<String> _cached = {};
  bool _caching = false;
  int _cachedDone = 0;
  int _cachedTotal = 0;
  String? _cacheMessage;
  final Map<String, CacheJob> _cacheJobs = {};
  bool _networkPaused = false;
  bool _mobileApproved = false;
  bool _networkStopped = false;
  Future<bool>? _networkConfirmation;
  StreamSubscription<List<ConnectivityResult>>? _cacheNetworkSubscription;

  void _syncCacheJobs() {
    var available = _repository.store.concurrency;
    for (final job in _cacheJobs.values) {
      if (job.control.cancelled ||
          job.status == CacheJobStatus.completed ||
          job.status == CacheJobStatus.failed ||
          job.status == CacheJobStatus.cancelled) {
        continue;
      }
      final admitted = !_networkPaused && !job.control.paused && available > 0;
      if (admitted) available--;
      job.control.setScheduled(admitted);
      job.status = job.control.paused
          ? CacheJobStatus.paused
          : admitted && job.started
          ? CacheJobStatus.downloading
          : CacheJobStatus.waiting;
    }
  }

  bool _deletingCache = false;
  bool _movingDirectory = false;

  int? _cacheBytes;
  String? _cacheLocation;
  static const _categories = ['全部', '主线篇章', '支线活动', '微型故事集', '玩法衍生篇', '其他档案'];
  static const _navigation = [
    (Icons.library_books_outlined, '剧情馆', '01'),
    (Icons.download_outlined, '离线与缓存', '02'),
    (Icons.tune, '系统设置', '03'),
  ];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _repository.store.loadSettings();
    unawaited(_refreshCacheInfo());
    try {
      final cached = await _repository.cachedStories();
      if (mounted) setState(() => _cached = cached);
    } catch (_) {
      if (mounted) setState(() => _cacheMessage = '无法读取离线记录，请检查存储权限或空间。');
    }
    if (mounted) {
      setState(() {});
      await _loadIndex();
    }
  }

  Future<void> _refreshCacheInfo() async {
    try {
      final size = await _repository.store.cacheSize();
      final location = _repository.store.isDesktop
          ? await _repository.store.cacheLocation()
          : null;
      if (mounted) {
        setState(() {
          _cacheBytes = size;
          _cacheLocation = location;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _cacheBytes = null;
          _cacheLocation = null;
        });
      }
    }
  }

  Future<void> _openCacheDirectory() async {
    try {
      await _repository.store.openCacheDirectory();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法打开缓存目录：$error')));
      }
    }
  }

  Future<void> _moveCacheDirectory() async {
    if (_busy || _caching || _deletingCache || _movingDirectory) return;
    setState(() => _movingDirectory = true);
    try {
      final path = await getDirectoryPath(confirmButtonText: '选择缓存目录');
      if (path == null || !mounted) return;
      await _repository.store.moveCacheDirectory(path);
      await _refreshCacheInfo();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('缓存目录已切换，原目录文件仍然保留。')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法切换缓存目录：$error')));
      }
    } finally {
      if (mounted) setState(() => _movingDirectory = false);
    }
  }

  Future<void> _changeConcurrency(int value) async {
    setState(() => _repository.store.concurrency = value);
    _syncCacheJobs();
    try {
      await _repository.store.setConcurrency(value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('并发设置无法保存，当前值仅在本次运行中生效。')));
      }
    }
  }

  Future<bool> _checkCacheNetwork([
    List<ConnectivityResult>? connections,
  ]) async {
    if (!_caching || _networkStopped) return false;
    if (!_repository.store.isMobile || _mobileApproved) return true;
    if (connections == null) {
      try {
        connections = await _repository.store.cacheConnections();
      } catch (_) {
        connections = [];
      }
    }
    if (!connections.contains(ConnectivityResult.mobile) &&
        (connections.contains(ConnectivityResult.wifi) ||
            connections.contains(ConnectivityResult.ethernet))) {
      return true;
    }
    if (_networkConfirmation != null) return _networkConfirmation!;
    if (!mounted) return false;
    setState(() {
      _networkPaused = true;
      _syncCacheJobs();
    });
    final confirmation = showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('使用移动数据缓存？'),
        content: const Text('当前网络可能使用移动数据。剧情图片和音频可能消耗较多流量，是否继续本次缓存？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('停止缓存'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续缓存'),
          ),
        ],
      ),
    ).then((value) => value == true);
    _networkConfirmation = confirmation;
    try {
      final allowed = await confirmation;
      _mobileApproved = allowed;
      _networkStopped = !allowed;
      if (mounted) {
        setState(() {
          _networkPaused = false;
          if (!allowed) {
            for (final job in _cacheJobs.values) {
              if (job.status == CacheJobStatus.waiting ||
                  job.status == CacheJobStatus.downloading ||
                  job.status == CacheJobStatus.paused) {
                job.control.cancel();
                job.status = CacheJobStatus.cancelled;
              }
            }
          }
          _syncCacheJobs();
        });
      }
      return allowed;
    } finally {
      _networkConfirmation = null;
    }
  }

  Future<void> _cacheSelected() async {
    if (_busy ||
        _caching ||
        _deletingCache ||
        _movingDirectory ||
        _selectedEntries.isEmpty) {
      return;
    }
    setState(() {
      _caching = true;
      _mobileApproved = false;
      _networkStopped = false;
    });
    final jobs = <CacheJob>[];
    try {
      if (_repository.store.isMobile) {
        _cacheNetworkSubscription = _repository.store.cacheConnectionChanges
            .listen(
              (connections) {
                unawaited(_checkCacheNetwork(connections));
              },
              onError: (Object _) {
                unawaited(_checkCacheNetwork([]));
              },
            );
      }
      if (!await _checkCacheNetwork() || _networkStopped || !mounted) return;
      jobs.addAll(
        {for (final entry in _selectedEntries) entry.path: CacheJob(entry)}
            .values,
      );
      setState(() {
        _cacheJobs
          ..clear()
          ..addEntries(jobs.map((job) => MapEntry(job.entry.path, job)));
        _cachedDone = 0;
        _cachedTotal = jobs.length;
        _cacheMessage = null;
        _page = 1;
        _syncCacheJobs();
      });
      Future<void> worker(CacheJob job) async {
        try {
          await job.control.checkpoint();
          job.started = true;
          job.status = CacheJobStatus.downloading;
          if (mounted) setState(() {});
          final errors = await _repository.cacheEntry(
            job.entry,
            control: job.control,
            onProgress: (done, total) {
              job.done = done;
              job.total = total;
              if (mounted) setState(() {});
            },
          );
          await job.control.checkpoint();
          if (errors.isEmpty) {
            job.status = CacheJobStatus.completed;
            _cached.add(job.entry.path);
            _selected.remove(job.entry.path);
          } else {
            job.status = CacheJobStatus.failed;
            job.error = errors.join('；');
          }
        } on CacheCancelled {
          job.status = CacheJobStatus.cancelled;
          if (job.started) {
            try {
              await _repository.forgetCachedStory(job.entry);
            } catch (error) {
              job.error = '无法删除离线记录：$error';
              job.status = CacheJobStatus.failed;
            }
          }
        } catch (error) {
          job.status = CacheJobStatus.failed;
          job.error = '$error';
        } finally {
          _syncCacheJobs();
          if (mounted) setState(() => _cachedDone++);
        }
      }

      await Future.wait(jobs.map(worker));
      _repository.store.releaseMemory();
      await _refreshCacheInfo();
    } catch (error) {
      if (mounted) setState(() => _cacheMessage = '缓存无法继续：$error');
    } finally {
      final subscription = _cacheNetworkSubscription;
      _cacheNetworkSubscription = null;
      // 取消监听立即生效，界面收尾不等待平台释放订阅。
      unawaited(subscription?.cancel());
      if (mounted) {
        final failures = jobs.where(
          (job) => job.status == CacheJobStatus.failed,
        );
        setState(() {
          _caching = false;
          _networkPaused = false;
          _cacheMessage = [
            if (_networkStopped) '已停止缓存，未继续使用移动数据。',
            if (jobs.isNotEmpty)
              '缓存完成，共 ${jobs.where((job) => job.status == CacheJobStatus.completed).length} 幕。',
            if (failures.isNotEmpty)
              '部分剧情缓存失败：\n${failures.map((job) => '${job.entry.title}：${job.error}').join('\n')}',
            if (jobs.isEmpty && !_networkStopped && _cacheMessage != null)
              _cacheMessage!,
          ].join('\n');
        });
      }
    }
  }

  void _toggleCacheJob(CacheJob job) {
    setState(() {
      if (job.control.paused) {
        job.control.resume();
      } else {
        job.control.pause();
      }
      _syncCacheJobs();
    });
  }

  void _removeCacheJob(CacheJob job) {
    setState(() {
      job.control.cancel();
      job.status = CacheJobStatus.cancelled;
      _cacheJobs.remove(job.entry.path);
      _selected.remove(job.entry.path);
      _syncCacheJobs();
    });
  }

  Future<void> _deleteCached(List<StoryEntry> entries) async {
    if (_busy || _deletingCache || _movingDirectory) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除离线剧情？'),
        content: Text('删除选中的 ${entries.length} 幕剧情的离线记录和独占素材，共用素材将保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true ||
        !mounted ||
        _busy ||
        _deletingCache ||
        _movingDirectory) {
      return;
    }
    setState(() => _deletingCache = true);
    try {
      var reclaimed = true;
      for (final entry in entries) {
        if (!await _repository.deleteCachedStory(entry)) reclaimed = false;
        _cacheJobs.remove(entry.path);
      }
      final cached = await _repository.cachedStories();
      if (!mounted) return;
      setState(() {
        _cached.removeAll(entries.map((entry) => entry.path));
        _cached.addAll(cached);
      });
      if (!reclaimed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('离线记录已删除；素材正在使用或缺少清单，相关文件已保留。')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除未完全完成：$error')));
      }
      try {
        final cached = await _repository.cachedStories();
        if (mounted) {
          setState(() {
            for (final entry in entries) {
              if (!cached.contains(entry.path)) _cached.remove(entry.path);
            }
            _cached.addAll(cached);
          });
        }
      } catch (_) {}
    } finally {
      if (mounted) setState(() => _deletingCache = false);
      await _refreshCacheInfo();
    }
  }

  Future<void> _clearCache() async {
    if (_caching || _busy || _deletingCache || _movingDirectory) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空素材缓存？'),
        content: const Text(
          '删除所有已下载的剧情脚本、图片和音频，并清除离线记录。保留剧情目录和下载设置，之后播放需要重新下载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              '清空缓存',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirm != true ||
        !mounted ||
        _caching ||
        _busy ||
        _deletingCache ||
        _movingDirectory) {
      return;
    }
    setState(() => _deletingCache = true);
    try {
      await _repository.clearCache();
      _cacheJobs.clear();
      if (mounted) {
        setState(() => _cacheMessage = null);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('素材缓存已清空。')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('清理未完全完成：$error')));
      }
    } finally {
      try {
        final cached = await _repository.cachedStories();
        if (mounted) setState(() => _cached = cached);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('无法刷新离线记录，请重新打开应用确认。')));
        }
      } finally {
        if (mounted) setState(() => _deletingCache = false);
        await _refreshCacheInfo();
      }
    }
  }

  Future<void> _loadIndex() async {
    setState(() => _indexError = null);
    try {
      final groups = await _repository.loadIndex();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _activeGroup = null;
      });
      unawaited(_refreshCacheInfo());
    } catch (e) {
      if (mounted) setState(() => _indexError = '剧情目录加载失败：$e');
    }
  }

  Future<void> _open(StoryEntry entry) async {
    if (_busy || _deletingCache || _movingDirectory) return;
    if (_caching) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请等待批量缓存完成后播放。')));
      return;
    }
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
      if (mounted) {
        setState(() => _playError = '加载失败：$e');
        if (_page == 1) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('加载失败：$e')));
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(_refreshCacheInfo());
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
      ...group.entries.where(
        (entry) =>
            _selected.contains(entry.path) && !_cached.contains(entry.path),
      ),
  ];

  void _toggle(StoryEntry entry, bool selected) => setState(() {
    if (selected && !_cached.contains(entry.path)) {
      _selected.add(entry.path);
    } else {
      _selected.remove(entry.path);
    }
  });

  void _selectAll(List<StoryEntry> entries) => setState(() {
    final available = entries.where((entry) => !_cached.contains(entry.path));
    if (available.every((entry) => _selected.contains(entry.path))) {
      _selected.removeAll(available.map((entry) => entry.path));
    } else {
      _selected.addAll(available.map((entry) => entry.path));
    }
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 1100;
      return PopScope(
        canPop: !_busy && !(_page == 0 && _activeGroup != null),
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && !_busy && _page == 0 && _activeGroup != null) {
            _leaveActivity();
          }
        },
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
                                  groups: _groups ?? const [],
                                  active: _page == 1,
                                  selected: _selectedEntries,
                                  cached: [
                                    for (final group
                                        in _groups ?? <StoryGroup>[])
                                      ...group.entries.where(
                                        (entry) => _cached.contains(entry.path),
                                      ),
                                  ],
                                  caching: _caching,
                                  done: _cachedDone,
                                  total: _cachedTotal,
                                  message: _cacheMessage,
                                  onCache: _cacheSelected,
                                  onOpen: _open,
                                  jobs: _cacheJobs,
                                  onToggleJob: _toggleCacheJob,
                                  onRemoveJob: _removeCacheJob,
                                  onDeleteCached: _deleteCached,
                                  deleting: _deletingCache,
                                  onBrowse: () => setState(() {
                                    _page = 0;
                                    _activeGroup = null;
                                  }),
                                ),
                                SettingsPage(
                                  concurrency: _repository.store.concurrency,
                                  onConcurrencyChanged: _changeConcurrency,
                                  concurrencyBusy: _movingDirectory,
                                  isMobile: _repository.store.isMobile,
                                  isDesktop: _repository.store.isDesktop,
                                  caching: _caching,
                                  cacheBytes: _cacheBytes,
                                  cacheLocation: _cacheLocation,
                                  onOpenDirectory: _openCacheDirectory,
                                  onMoveDirectory: _moveCacheDirectory,
                                  onClearCache: _clearCache,
                                  directoryBusy:
                                      _movingDirectory ||
                                      _caching ||
                                      _deletingCache ||
                                      _busy,
                                ),
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

  void _leaveActivity() => setState(() {
    _activeGroup = null;
    _selected.clear();
  });

  Widget _library(bool desktop) {
    final groups = _visibleGroups;
    final active = _activeGroup;
    final catalog = CustomScrollView(
      key: PageStorageKey(desktop ? 'desktop-chapters' : 'mobile-chapters'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ArchiveHeading('剧情馆'),
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
        _catalogBody(groups),
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
        Expanded(child: active == null ? catalog : _chapterDetail(active)),
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

  Widget _catalogBody(List<StoryGroup> groups) {
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
        itemBuilder: (context, index) => _activityCard(groups[index]),
      ),
    );
  }

  Widget _activityCard(StoryGroup group) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: ArchivePanel(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          key: ValueKey('chapter-${group.name}'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          title: Text(group.name),
          subtitle: Text(
            '${_categories[_categoryOf(group)]} · ${_entries(group).length} 幕',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => setState(() {
            _selected.clear();
            _activeGroup = group;
          }),
        ),
      ),
    ),
  );

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
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _leaveActivity,
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('返回剧情馆'),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ArchiveTag(_categories[_categoryOf(group)]),
                    Text('${entries.length} 幕'),
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
                      onPressed: _selected.isEmpty || _caching
                          ? null
                          : _cacheSelected,
                      icon: const Icon(Icons.download_outlined, size: 17),
                      label: Text('缓存选中项 (${_selected.length})'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => setState(() => _page = 1),
                      icon: const Icon(Icons.download_done_outlined, size: 17),
                      label: const Text('管理离线剧情'),
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
                child: _stageRow(entries[index]),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _selectAllControl(List<StoryEntry> entries) {
    entries = entries.where((entry) => !_cached.contains(entry.path)).toList();
    final count = entries
        .where((entry) => _selected.contains(entry.path))
        .length;
    return MergeSemantics(
      child: InkWell(
        onTap: entries.isEmpty ? null : () => _selectAll(entries),
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
              onChanged: entries.isEmpty ? null : (_) => _selectAll(entries),
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

  Widget _stageRow(StoryEntry entry) => Material(
    key: ValueKey(entry.path),
    color: _selected.contains(entry.path)
        ? AppColors.surface
        : Colors.transparent,
    child: InkWell(
      onTap: () => _toggle(entry, !_selected.contains(entry.path)),
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
        padding: const EdgeInsets.fromLTRB(6, 12, 12, 12),
        child: Row(
          children: [
            Checkbox(
              value: _selected.contains(entry.path),
              semanticLabel: '选择 ${entry.title}',
              onChanged: _cached.contains(entry.path)
                  ? null
                  : (value) => _toggle(entry, value ?? false),
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
                      if (_cached.contains(entry.path))
                        const ArchiveTag('已缓存', color: AppColors.terminalWhite),
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
          onPressed: _selected.isEmpty || _caching ? null : _cacheSelected,
          icon: const Icon(Icons.download_outlined, size: 16),
          label: const Text('缓存'),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    for (final job in _cacheJobs.values) {
      job.control.cancel();
    }
    unawaited(_cacheNetworkSubscription?.cancel());
    _search.dispose();
    _ownedAssets?.close();
    super.dispose();
  }
}
