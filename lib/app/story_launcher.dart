import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../story_player/story_player.dart';
import 'app_theme.dart';
import 'archive_motion.dart';
import 'archive_widgets.dart';
import 'cache_page.dart';
import 'cache_job.dart';
import '../story_player/data/cache_control.dart';
import 'settings_page.dart';
import '../story_player/data/playback_settings.dart';

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
  final _categoryPageController = PageController();
  List<StoryGroup>? _groups;
  StoryGroup? _activeGroup;
  String? _indexError;
  String? _playError;
  StoryEntry? _opening;
  bool _openingResume = false;
  String _filter = '';
  int _category = 0;
  int _page = 0;
  bool _busy = false;
  int _done = 0, _total = 0;
  Set<String> _cached = {};
  bool _caching = false;
  int _cachedDone = 0;
  int _cachedTotal = 0;
  int _cacheBatchId = 0;
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

  Future<void> _changePlaybackSettings(PlaybackSettings value) async {
    try {
      final write = _repository.store.setPlaybackSettings(value);
      setState(() {});
      await write;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('播放设置无法保存，当前值仅在本次运行中生效。')));
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

  Future<void> _retryFailedCacheJobs() async {
    final failed = _cacheJobs.values.where(
      (job) => job.status == CacheJobStatus.failed,
    );
    if (failed.isNotEmpty) await _cacheEntry(failed.first.entry);
  }

  Future<void> _cacheEntry(StoryEntry entry) async {
    if (_busy ||
        _caching ||
        _deletingCache ||
        _movingDirectory ||
        _cached.contains(entry.path)) {
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
      jobs.add(CacheJob(entry));
      setState(() {
        _cacheJobs
          ..clear()
          ..addEntries(jobs.map((job) => MapEntry(job.entry.path, job)));
        _cachedDone = 0;
        _cachedTotal = jobs.length;
        _cacheBatchId++;
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

  Future<void> _open(StoryEntry entry, {bool resume = false}) async {
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
      _openingResume = resume;
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
      final scriptHash = PlaybackProgress.fingerprint(document.script);
      final saved = resume
          ? _repository.store.getPlaybackProgress(entry.path)
          : null;
      PlaybackCheckpoint? checkpoint = saved?.checkpoint;
      if (saved != null && !saved.matches(document.script)) {
        if (!mounted) return;
        final restart = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('观看断点已失效'),
            content: const Text('剧情内容已更新，无法恢复原观看位置。是否从头观看？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('从头观看'),
              ),
            ],
          ),
        );
        if (restart != true) return;
        checkpoint = null;
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
      Future<void> progressWrite = Future.value();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => StoryPlayer(
            story: prepared,
            settings: _repository.store.playbackSettings,
            checkpoint: checkpoint,
            onProgress: (position) {
              progressWrite = position == null
                  ? _repository.store.removePlaybackProgress(entry.path)
                  : _repository.store.setPlaybackProgress(
                      PlaybackProgress(
                        path: entry.path,
                        scriptHash: scriptHash,
                        checkpoint: position,
                      ),
                    );
              return progressWrite;
            },
          ),
        ),
      );
      await progressWrite.catchError((_) {});
      if (mounted) setState(() {});
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

  List<StoryGroup> _visibleGroups(int category) =>
      (_groups ?? const <StoryGroup>[])
          .where(
            (group) =>
                (category == 0 || _categoryOf(group) == category) &&
                _entries(group).isNotEmpty,
          )
          .toList();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 1100;
      final glassNavigation =
          !desktop &&
          _repository.store.isMobile &&
          !MediaQuery.highContrastOf(context);
      final navigationBar = NavigationBar(
        backgroundColor: glassNavigation
            ? AppColors.panel.withValues(alpha: .86)
            : null,
        elevation: glassNavigation ? 0 : null,
        surfaceTintColor: glassNavigation ? Colors.transparent : null,
        animationDuration: ArchiveMotion.duration(
          context,
          ArchiveMotion.stateDuration,
        ),
        selectedIndex: _page,
        onDestinationSelected: (value) => setState(() => _page = value),
        destinations: [
          for (final item in _navigation)
            NavigationDestination(icon: Icon(item.$1), label: item.$2),
        ],
      );
      return PopScope(
        canPop: !_busy && !(_page == 0 && _activeGroup != null),
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && !_busy && _page == 0 && _activeGroup != null) {
            _leaveActivity();
          }
        },
        child: Scaffold(
          // 列表经过底栏后方，模糊才有实际内容；滚动区保留相应的底部留白。
          extendBody: glassNavigation,
          body: SafeArea(
            bottom: !glassNavigation,
            child: Stack(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (desktop) _sidebar(),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            child: ArchivePageTransition(
                              transitionKey: _page,
                              child: IndexedStack(
                                index: _page,
                                children: [
                                  _library(desktop),
                                  CachePage(
                                    // 新批次切回总览，即使缓存立即完成也不依赖中间帧。
                                    key: ValueKey('cache-batch-$_cacheBatchId'),
                                    groups: _groups ?? const [],
                                    active: _page == 1,
                                    cached: [
                                      for (final group
                                          in _groups ?? <StoryGroup>[])
                                        ...group.entries.where(
                                          (entry) =>
                                              _cached.contains(entry.path),
                                        ),
                                    ],
                                    caching: _caching,
                                    done: _cachedDone,
                                    total: _cachedTotal,
                                    message: _cacheMessage,
                                    onRetry: _retryFailedCacheJobs,
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
                                    active: _page == 2,
                                    settings:
                                        _repository.store.playbackSettings,
                                    onSettingsChanged: _changePlaybackSettings,
                                    probe: _repository.store.probe,
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
                  child: glassNavigation
                      ? ClipRect(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                            child: DecoratedBox(
                              position: DecorationPosition.foreground,
                              decoration: const BoxDecoration(
                                border: Border(
                                  top: BorderSide(color: AppColors.borderLight),
                                ),
                              ),
                              child: navigationBar,
                            ),
                          ),
                        )
                      : navigationBar,
                ),
        ),
      );
    },
  );

  Widget _sidebar() => SizedBox(
    key: const Key('desktop-sidebar'),
    width: 216,
    child: Material(
      color: AppColors.panel,
      shape: const Border(right: BorderSide(color: AppColors.borderSubtle)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 28, 16, 28),
            child: Row(
              children: [
                Image.asset(
                  'assets/images/logo_rhodes.png',
                  width: 28,
                  height: 28,
                  fit: BoxFit.contain,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '方舟档案室',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
              children: [
                for (var i = 0; i < _navigation.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      selected: _page == i,
                      selectedColor: AppColors.indicator,
                      selectedTileColor: AppColors.surface,
                      textColor: AppColors.subtext,
                      iconColor: AppColors.subtext,
                      leading: Icon(_navigation[i].$1, size: 20),
                      title: Text(
                        _navigation[i].$2,
                        style: const TextStyle(fontSize: 13),
                      ),
                      onTap: () => setState(() => _page = i),
                    ),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              '剧情浏览与离线阅读',
              style: TextStyle(fontSize: 12, color: AppColors.subtext),
            ),
          ),
        ],
      ),
    ),
  );

  void _leaveActivity() => setState(() => _activeGroup = null);
  Widget _library(bool desktop) {
    final active = _activeGroup;
    final catalog = Column(
      children: [
        ArchivePageHeader(
          key: const Key('catalog-header'),
          title: '剧情馆',
          bottom: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('story-search'),
                controller: _search,
                onChanged: (value) => setState(() => _filter = value),
                style: const TextStyle(fontSize: 14),
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
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: _categoryButtons()),
              ),
            ],
          ),
        ),
        Expanded(
          child: _repository.store.isMobile
              ? PageView.builder(
                  key: const PageStorageKey('category-pages'),
                  controller: _categoryPageController,
                  itemCount: _categories.length,
                  onPageChanged: (value) => setState(() => _category = value),
                  itemBuilder: (context, index) => _catalogPage(index, desktop),
                )
              : _catalogPage(_category, desktop),
        ),
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
                  onPressed: () => _open(_opening!, resume: _openingResume),
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
          child: ArchivePageTransition(
            transitionKey: (
              active?.name,
              active?.entryType,
              _repository.store.isMobile ? null : _category,
            ),
            depth: active == null ? 0 : 1,
            child: active == null ? catalog : _chapterDetail(active),
          ),
        ),
      ],
    );
  }

  Widget _catalogPage(int category, bool desktop) {
    final groups = _visibleGroups(category);
    return CustomScrollView(
      key: PageStorageKey(
        _repository.store.isMobile && category != 0
            ? 'mobile-chapters-$category'
            : desktop
            ? 'desktop-chapters'
            : 'mobile-chapters',
      ),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text(
              _groups == null
                  ? '正在读取剧情索引'
                  : '${groups.length} 个篇章 · ${groups.fold<int>(0, (sum, group) => sum + _entries(group).length)} 幕',
              style: const TextStyle(color: AppColors.subtext, fontSize: 12),
            ),
          ),
        ),
        _catalogBody(groups, category),
        const SliverToBoxAdapter(
          child: SafeArea(
            top: false,
            left: false,
            right: false,
            child: SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  void _selectCategory(int category) {
    if (_repository.store.isMobile && _categoryPageController.hasClients) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _categoryPageController.jumpToPage(category);
      } else {
        _categoryPageController.animateToPage(
          category,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    }
    setState(() => _category = category);
  }

  List<Widget> _categoryButtons() => [
    for (var i = 0; i < _categories.length; i++)
      Semantics(
        selected: _category == i,
        child: AnimatedContainer(
          duration: ArchiveMotion.duration(
            context,
            ArchiveMotion.stateDuration,
          ),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: _category == i
                    ? AppColors.indicator
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: TextButton(
            key: ValueKey('category-$i'),
            onPressed: () => _selectCategory(i),
            style: TextButton.styleFrom(
              foregroundColor: _category == i
                  ? AppColors.text
                  : AppColors.subtext,
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: Text(_categories[i]),
          ),
        ),
      ),
  ];

  Widget _catalogBody(List<StoryGroup> groups, int category) {
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
        title: category == 4 ? '玩法衍生档案待接入' : '没有匹配的剧情',
        message: category == 4 ? '当前索引未提供完整的玩法衍生目录，后续将在这里接入。' : '试试其他关键词或切换分类。',
        action: TextButton(
          onPressed: () {
            _search.clear();
            setState(() => _filter = '');
            _selectCategory(0);
          },
          child: const Text('查看全部剧情'),
        ),
      );
    }
    if (status != null) {
      return SliverFillRemaining(hasScrollBody: false, child: status);
    }
    return SliverPadding(
      padding: const EdgeInsets.all(20),
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
          title: Text(
            group.name,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            '${_categories[_categoryOf(group)]} · ${_entries(group).length} 幕',
            style: const TextStyle(fontSize: 12, color: AppColors.subtext),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => setState(() => _activeGroup = group),
        ),
      ),
    ),
  );

  Widget _chapterDetail(StoryGroup group) {
    final entries = _entries(group);
    return Column(
      children: [
        ArchivePageHeader(
          key: const Key('chapter-header'),
          title: group.name,
          leading: IconButton(
            tooltip: '返回剧情馆',
            onPressed: _leaveActivity,
            icon: const Icon(Icons.arrow_back, size: 22),
          ),
        ),
        Expanded(
          child: CustomScrollView(
            key: PageStorageKey('stages-${group.name}'),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Text(
                    '${_categories[_categoryOf(group)]} · ${entries.length} 幕',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.subtext,
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.all(20),
                sliver: SliverList.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ArchivePanel(
                      padding: EdgeInsets.zero,
                      child: _stageRow(entries[index]),
                    ),
                  ),
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
    );
  }

  Widget _stageRow(StoryEntry entry) => Material(
    key: ValueKey(entry.path),
    color: Colors.transparent,
    child: InkWell(
      onTap: () => _open(entry),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(
          children: [
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
                          style: AppTypography.tacticalCode.copyWith(
                            color: AppColors.subtext,
                            fontSize: 13,
                          ),
                        ),
                      if (entry.tag.isNotEmpty)
                        ArchiveTag(entry.tag, color: AppColors.subtext),
                      if (_cached.contains(entry.path))
                        const ArchiveTag('已缓存', color: AppColors.indicator),
                    ],
                  ),
                  if (entry.code.isNotEmpty || entry.tag.isNotEmpty)
                    const SizedBox(height: 8),
                  Text(
                    entry.name.isEmpty ? entry.title : entry.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: AppColors.text,
                      height: 1.5,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (_repository.store.getPlaybackProgress(entry.path) != null)
              TextButton.icon(
                key: ValueKey('continue-${entry.path}'),
                onPressed: _busy ? null : () => _open(entry, resume: true),
                icon: const Icon(Icons.history, size: 18),
                label: const Text('继续观看'),
              ),
            IconButton(
              tooltip: '播放 ${entry.title}',
              onPressed: () => _open(entry),
              icon: const Icon(Icons.play_arrow, size: 22),
            ),
            PopupMenuButton<String>(
              tooltip: '${entry.title}的更多操作',
              onSelected: (_) => _cacheEntry(entry),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'cache',
                  enabled:
                      !_cached.contains(entry.path) &&
                      !_caching &&
                      !_busy &&
                      !_deletingCache &&
                      !_movingDirectory,
                  child: Text(_cached.contains(entry.path) ? '已缓存' : '缓存'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  @override
  void dispose() {
    for (final job in _cacheJobs.values) {
      job.control.cancel();
    }
    unawaited(_cacheNetworkSubscription?.cancel());
    _categoryPageController.dispose();
    _search.dispose();
    _ownedAssets?.close();
    super.dispose();
  }
}
