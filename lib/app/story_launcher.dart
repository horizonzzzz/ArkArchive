import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:file_selector/file_selector.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../story_player/story_player.dart';
import 'activity_images.dart';
import 'app_theme.dart';
import 'app_update.dart';
import 'archive_motion.dart';
import 'archive_widgets.dart';
import 'character_archive_page.dart';
import 'character_archive_data.dart';
import 'character_replay.dart';
import 'cache_page.dart';
import 'cache_job.dart';
import '../story_player/data/cache_control.dart';
import 'settings_page.dart';
import '../story_player/data/playback_settings.dart';

class StoryLauncher extends StatefulWidget {
  const StoryLauncher({super.key, this.repository, this.onThemeChanged});
  final StoryRepository? repository;
  final ValueChanged<bool>? onThemeChanged;

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
  String _filter = '';
  int _category = 0;
  static const _catalogPageSize = 10;
  final Map<int, int> _catalogPages = {};
  int _page = 0;
  int _cacheReturnPage = 0;
  bool _busy = false;
  int _done = 0, _total = 0;
  Set<String> _cached = {};
  final Map<String, CachedStory> _cachedDetails = {};
  bool _loadingCached = true;
  String? _cacheMessage;
  final Map<String, CacheJob> _cacheJobs = {};
  bool _networkPaused = false;
  bool _mobileApproved = false;
  bool _networkStopped = false;
  Future<bool>? _networkConfirmation;
  StreamSubscription<List<ConnectivityResult>>? _cacheNetworkSubscription;

  final AppUpdateClient _updateClient = AppUpdateClient();
  String? _appVersion;

  bool _isJobActive(CacheJob job) =>
      job.status == CacheJobStatus.waiting ||
      job.status == CacheJobStatus.downloading ||
      job.status == CacheJobStatus.paused;

  /// 队列中是否存在进行中的下载任务；期间可继续添加任务，也可播放已缓存剧情。
  bool get _hasActiveJobs => _cacheJobs.values.any(_isJobActive);

  /// 「已处理 X / Y 幕」的已处理数：队列里已到达终态的任务数。
  int get _cachedDone =>
      _cacheJobs.values.where((job) => !_isJobActive(job)).length;

  int get _cachedTotal => _cacheJobs.length;

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
    (Icons.people_outline, '人物档案', '02'),
    (Icons.tune, '系统设置', '03'),
  ];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _updateClient.currentVersion = info.version;
      if (mounted) setState(() => _appVersion = info.version);
    } catch (_) {
      if (mounted) setState(() => _appVersion = null);
    }
  }

  /// 用系统浏览器打开外部链接（项目主页、发布页与更新包下载）。
  Future<void> _openExternalLink(Uri uri) async {
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开链接，请检查浏览器设置。')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法打开链接：$error')));
      }
    }
  }

  Future<void> _initialize() async {
    unawaited(_loadAppVersion());
    await _repository.store.loadSettings();
    if (mounted) {
      widget.onThemeChanged?.call(
        _repository.store.playbackSettings.lightTheme,
      );
    }
    unawaited(_refreshCacheInfo());
    try {
      final details = await _repository.cachedStoryDetails();
      if (mounted) {
        setState(() {
          _cachedDetails.addAll({
            for (final item in details) item.entry.path: item,
          });
          _cached = _cachedDetails.keys.toSet();
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cacheMessage = '无法读取离线记录，请检查存储权限或空间。');
    } finally {
      if (mounted) setState(() => _loadingCached = false);
    }
    if (mounted) {
      List<StoryGroup> localGroups;
      try {
        localGroups = await _repository.loadLocalIndex();
      } catch (_) {
        localGroups = [];
      }
      if (!mounted) return;
      setState(() {
        if (localGroups.isNotEmpty) _groups = localGroups;
        _restoreCachedDetails(localGroups);
      });
      unawaited(
        _repository.restoreCachedMetadata(localGroups).catchError((_) {}),
      );
      unawaited(_loadIndex());
    }
  }

  void _restoreCachedDetails(List<StoryGroup> groups) {
    for (final group in groups) {
      for (final entry in group.entries) {
        final item = _cachedDetails[entry.path];
        if (item != null &&
            (item.entry.title == entry.path || item.groupName.isEmpty)) {
          _cachedDetails[entry.path] = CachedStory(
            entry,
            groupName: group.name,
            groupId: group.id,
            entryType: group.entryType,
          );
        }
      }
    }
  }

  List<StoryGroup> get _offlineGroups {
    final groups = <String, List<CachedStory>>{};
    for (final item in _cachedDetails.values.where(
      (item) => _cached.contains(item.entry.path),
    )) {
      if (item.groupName.isEmpty) continue;
      groups
          .putIfAbsent(
            '${item.entryType}\u0000${item.groupId}\u0000${item.groupName}',
            () => [],
          )
          .add(item);
    }
    return [
      for (final items in groups.values)
        StoryGroup(
          items.first.groupName,
          items.map((item) => item.entry).toList(),
          id: items.first.groupId,
          entryType: items.first.entryType,
        ),
    ];
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

  /// Windows 上缓存路径含非 ASCII 字符时 just_audio_windows 打不开本地音频，
  /// 所以切换目录前先把这类路径拦下来。
  bool _pathBreaksAudio(String path) =>
      defaultTargetPlatform == TargetPlatform.windows &&
      path.runes.any((rune) => rune > 0x7f);

  Future<void> _moveCacheDirectory() async {
    if (_busy || _hasActiveJobs || _deletingCache || _movingDirectory) return;
    setState(() => _movingDirectory = true);
    try {
      final path = await getDirectoryPath(confirmButtonText: '选择缓存目录');
      if (path == null || !mounted) return;
      if (_pathBreaksAudio(path)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('所选路径包含中文，Windows 上会导致音频无法播放，请改用纯英文路径。'),
          ),
        );
        return;
      }
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

  Future<void> _changeMobileDataPrompt(bool enabled) async {
    // setMobileDataApproved 同步更新字段，先重建让开关状态立即生效。
    setState(() {});
    try {
      await _repository.store.setMobileDataApproved(!enabled);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('提示设置无法保存，当前选择仅在本次运行中生效。')),
        );
      }
    }
  }

  Future<void> _changePlaybackSettings(PlaybackSettings value) async {
    try {
      final write = _repository.store.setPlaybackSettings(value);
      widget.onThemeChanged?.call(value.lightTheme);
      setState(() {});
      await write;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('设置无法保存，当前值仅在本次运行中生效。')));
      }
    }
  }

  Future<bool> _checkCacheNetwork([
    List<ConnectivityResult>? connections,
  ]) async {
    if (_networkStopped) return false;
    if (!_repository.store.isMobile ||
        _mobileApproved ||
        _repository.store.mobileDataApproved) {
      return true;
    }
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
    var dontAskAgain = false;
    final confirmation =
        showDialog<(bool, bool)?>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => StatefulBuilder(
            builder: (dialogContext, setDialogState) => AlertDialog(
              title: const Text('使用移动数据缓存？'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('当前网络可能使用移动数据。剧情图片和音频可能消耗较多流量，是否继续本次缓存？'),
                  CheckboxListTile(
                    key: const ValueKey('mobile-data-dont-ask'),
                    value: dontAskAgain,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('不再提示'),
                    onChanged: (value) =>
                        setDialogState(() => dontAskAgain = value ?? false),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, (false, dontAskAgain)),
                  child: const Text('停止缓存'),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, (true, dontAskAgain)),
                  child: const Text('继续缓存'),
                ),
              ],
            ),
          ),
        ).then((result) {
          // 只有批准继续时才按勾选持久化偏好；拒绝不持久化，下次仍会询问。
          if (result?.$1 == true && result?.$2 == true) {
            unawaited(
              _repository.store.setMobileDataApproved(true).catchError((_) {}),
            );
          }
          return result?.$1 == true;
        });
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

  void _retryCacheJob(CacheJob job) => _cacheEntry(job.entry);

  /// 把一段剧情加入下载队列并立即开始执行；已有任务在下载时同样可以继续添加。
  /// 完成与否由每个任务自行上报，全部结束后在 [_checkCacheSettled] 收尾。
  Future<void> _cacheEntry(StoryEntry entry) async {
    if (_busy || _deletingCache || _movingDirectory) return;
    if (_cached.contains(entry.path)) return;
    final existing = _cacheJobs[entry.path];
    if (existing != null && _isJobActive(existing)) return;
    if (!_hasActiveJobs) {
      // 新一轮下载会话：移动数据批准与停止状态重新确认。
      _mobileApproved = false;
      _networkStopped = false;
    }
    final allowed = await _checkCacheNetwork();
    if (!allowed) {
      if (mounted && _networkStopped) {
        setState(() => _cacheMessage = '已停止缓存，未继续使用移动数据。');
      }
      return;
    }
    if (!mounted) return;
    final job = CacheJob(entry);
    setState(() {
      _cacheJobs[entry.path] = job;
      _cacheMessage = null;
      _syncCacheJobs();
    });
    _ensureCacheNetworkSubscription();
    unawaited(_runJob(job));
  }

  void _ensureCacheNetworkSubscription() {
    if (!_repository.store.isMobile || _cacheNetworkSubscription != null) {
      return;
    }
    _cacheNetworkSubscription = _repository.store.cacheConnectionChanges.listen(
      (connections) {
        if (!_hasActiveJobs && _networkConfirmation == null) return;
        unawaited(_checkCacheNetwork(connections));
      },
      onError: (Object _) {
        if (!_hasActiveJobs && _networkConfirmation == null) return;
        unawaited(_checkCacheNetwork([]));
      },
    );
  }

  Future<void> _runJob(CacheJob job) async {
    try {
      await job.control.checkpoint();
      job.started = true;
      final group = (_groups ?? const <StoryGroup>[])
          .where(
            (group) =>
                group.entries.any((entry) => entry.path == job.entry.path),
          )
          .firstOrNull;
      job.status = CacheJobStatus.downloading;
      if (mounted) setState(() {});
      final errors = await _repository.cacheEntry(
        job.entry,
        group: group,
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
        _cachedDetails[job.entry.path] = CachedStory(
          job.entry,
          groupName: group?.name ?? '',
          groupId: group?.id ?? '',
          entryType: group?.entryType ?? 'NONE',
        );
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
      if (mounted) setState(() {});
      _checkCacheSettled();
    }
  }

  /// 队列里不再有进行中的任务时统一收尾：断开网络监听并汇总提示。
  /// 用户中途删除任务或重试失败任务都会改变队列，因此每次任务结束都要重新检查。
  void _checkCacheSettled() {
    if (_hasActiveJobs) return;
    final subscription = _cacheNetworkSubscription;
    _cacheNetworkSubscription = null;
    // 取消监听立即生效，界面收尾不等待平台释放订阅。
    unawaited(subscription?.cancel());
    _repository.store.releaseMemory();
    unawaited(_refreshCacheInfo());
    if (!mounted) return;
    final stopped = _networkStopped;
    final completed = _cacheJobs.values
        .where((job) => job.status == CacheJobStatus.completed)
        .length;
    final failures = _cacheJobs.values
        .where((job) => job.status == CacheJobStatus.failed)
        .toList();
    setState(() {
      _networkPaused = false;
      _cacheMessage = [
        if (stopped) '已停止缓存，未继续使用移动数据。',
        if (_cacheJobs.isNotEmpty) '缓存完成，共 $completed 幕。',
        if (failures.isNotEmpty)
          '部分剧情缓存失败：\n${failures.map((job) => '${job.entry.title}：${job.error}').join('\n')}',
      ].join('\n');
    });
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
        content: Text('删除选中的 ${entries.length} 幕剧情的离线记录和全部缓存素材。'),
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
      for (final entry in entries) {
        await _repository.deleteCachedStory(entry);
        _cacheJobs.remove(entry.path);
      }
      final cached = await _repository.cachedStories();
      if (!mounted) return;
      setState(() {
        _cached.removeAll(entries.map((entry) => entry.path));
        _cached.addAll(cached);
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('删除未完全完成：$error'),
            action: SnackBarAction(
              label: '重试',
              onPressed: () => _deleteCached(entries),
            ),
          ),
        );
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
    if (_hasActiveJobs || _busy || _deletingCache || _movingDirectory) return;
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
            child: Text(
              '清空缓存',
              style: TextStyle(color: AppColors.of(context).danger),
            ),
          ),
        ],
      ),
    );
    if (confirm != true ||
        !mounted ||
        _hasActiveJobs ||
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
      final groups = await _repository.refreshIndex();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _restoreCachedDetails(groups);
      });
      unawaited(_repository.restoreCachedMetadata(groups).catchError((_) {}));
      unawaited(_refreshCacheInfo());
    } catch (e) {
      if (mounted) setState(() => _indexError = '剧情目录加载失败：$e');
    }
  }

  Future<void> _openCharacterReplay(
    CharacterStory story,
    CharacterSnippet snippet,
  ) => _open(
    StoryEntry(story.title, story.path),
    archiveStory: story,
    snippet: snippet,
  );
  Future<void> _open(
    StoryEntry entry, {
    CharacterStory? archiveStory,
    CharacterSnippet? snippet,
  }) async {
    final archive = archiveStory != null && snippet != null;
    if (_busy || _deletingCache || _movingDirectory) return;
    // 下载任务在后台继续执行，播放已缓存剧情不再被缓存中拦截。
    setState(() {
      _busy = true;
      _playError = null;
      _opening = entry;
      _done = 0;
      _total = 0;
    });
    // 已缓存剧情播放期间的动态补下素材归入它的独立目录；
    // 在线试看则进共享层，不产生无法管理的临时目录。
    _repository.store.playbackScope = _cached.contains(entry.path)
        ? entry.path
        : null;
    try {
      final document = await _repository.loadEntry(entry);
      if (!document.script.commands.any(
        (c) => c.tag == 'dialogue' || c.text.isNotEmpty,
      )) {
        throw const FormatException('脚本中没有可播放内容');
      }
      final location = archive
          ? locateCharacterReplay(document, archiveStory, snippet)
          : null;
      final scriptHash = PlaybackProgress.fingerprint(document.script);
      // 有保存进度时作为可选恢复点传入播放器，是否失效由「从上次继续」点击时校验。
      final saved = _repository.store.getPlaybackProgress(entry.path);
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
            resumable: archive ? null : saved,
            archiveMode: archive,
            initialCommandIndex: location?.commandIndex,
            archiveNotice: location?.notice,
            onProgress: (position) {
              progressWrite = progressWrite.catchError((_) {}).then((_) async {
                if (position == null) {
                  await _repository.store.markStoryCompleted(entry.path);
                  await _repository.store.removePlaybackProgress(entry.path);
                } else {
                  await _repository.store.setPlaybackProgress(
                    PlaybackProgress(
                      path: entry.path,
                      scriptHash: scriptHash,
                      checkpoint: position,
                    ),
                  );
                }
              });
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
        if (_page == 2 || archive) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('加载失败：$e')));
        }
      }
    } finally {
      _repository.store.playbackScope = null;
      if (mounted) setState(() => _busy = false);
      unawaited(_refreshCacheInfo());
    }
  }

  int _categoryOf(StoryGroup group) => switch (group.entryType) {
    'MAINLINE' => 1,
    'ACTIVITY' => 2,
    'MINI_ACTIVITY' => 3,
    'GAMEPLAY' => 4,
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
      final navigationPage = _page == 2 ? _cacheReturnPage : _page;
      final glassNavigation =
          !desktop &&
          _repository.store.isMobile &&
          !MediaQuery.highContrastOf(context);
      final navigationBar = NavigationBar(
        backgroundColor: glassNavigation
            ? AppColors.of(context).panel.withValues(alpha: .86)
            : null,
        elevation: glassNavigation ? 0 : null,
        surfaceTintColor: glassNavigation ? Colors.transparent : null,
        animationDuration: ArchiveMotion.duration(
          context,
          ArchiveMotion.stateDuration,
        ),
        selectedIndex: navigationPage == 3 ? 2 : navigationPage,
        onDestinationSelected: (value) =>
            setState(() => _page = value == 2 ? 3 : value),
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
                                  _library(),
                                  CharacterArchivePage(
                                    store: _repository.store,
                                    active: _page == 1,
                                    onReplay: _openCharacterReplay,
                                    onBrowse: () => setState(() => _page = 0),
                                  ),
                                  CachePage(
                                    groups: _offlineGroups,
                                    loading: _loadingCached,
                                    active: _page == 2,
                                    onBack: () => setState(
                                      () => _page = _cacheReturnPage,
                                    ),
                                    cached: [
                                      for (final item in _cachedDetails.values)
                                        if (_cached.contains(item.entry.path))
                                          item.entry,
                                    ],
                                    caching: _hasActiveJobs,
                                    progressPaths: {
                                      for (final path in _cached)
                                        if (_repository.store
                                                .getPlaybackProgress(path) !=
                                            null)
                                          path,
                                    },
                                    completedPaths:
                                        _repository.store.completedStories,
                                    done: _cachedDone,
                                    total: _cachedTotal,
                                    message: _cacheMessage,
                                    onRetry: _retryCacheJob,
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
                                    active: _page == 3,
                                    onOpenCache: _openCache,
                                    settings:
                                        _repository.store.playbackSettings,
                                    onSettingsChanged: _changePlaybackSettings,
                                    probe: _repository.store.probe,
                                    concurrency: _repository.store.concurrency,
                                    onConcurrencyChanged: _changeConcurrency,
                                    concurrencyBusy: _movingDirectory,
                                    isMobile: _repository.store.isMobile,
                                    isDesktop: _repository.store.isDesktop,
                                    caching: _hasActiveJobs,
                                    cacheBytes: _cacheBytes,
                                    cacheLocation: _cacheLocation,
                                    mobileDataPrompt:
                                        !_repository.store.mobileDataApproved,
                                    onMobileDataPromptChanged:
                                        _changeMobileDataPrompt,
                                    onOpenDirectory: _openCacheDirectory,
                                    onMoveDirectory: _moveCacheDirectory,
                                    onClearCache: _clearCache,
                                    appVersion: _appVersion,
                                    update: _updateClient,
                                    onOpenLink: _openExternalLink,
                                    directoryBusy:
                                        _movingDirectory ||
                                        _hasActiveJobs ||
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
                              Icon(
                                Icons.radar,
                                size: 48,
                                color: AppColors.of(context).muted,
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
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.of(context).secondary,
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
                                style: TextStyle(
                                  color: AppColors.of(context).secondary,
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
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                    color: AppColors.of(context).borderLight,
                                  ),
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
      color: AppColors.of(context).panel,
      shape: Border(
        right: BorderSide(color: AppColors.of(context).borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 28, 16, 28),
            child: Row(
              children: [
                Image.asset(
                  'assets/images/app_icon.png',
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
                      selected:
                          (_page == 2 ? _cacheReturnPage : _page) ==
                          (i == 2 ? 3 : i),
                      selectedColor: AppColors.of(context).indicator,
                      selectedTileColor: AppColors.of(context).surface,
                      textColor: AppColors.of(context).subtext,
                      iconColor: AppColors.of(context).subtext,
                      leading: Icon(_navigation[i].$1, size: 20),
                      title: Text(
                        _navigation[i].$2,
                        style: const TextStyle(fontSize: 13),
                      ),
                      onTap: () => setState(() => _page = i == 2 ? 3 : i),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              '剧情浏览与离线阅读',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.of(context).subtext,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  void _openCache() => setState(() {
    _cacheReturnPage = _page;
    _page = 2;
  });

  Widget _cacheShortcut() => IconButton(
    tooltip: '离线与缓存',
    onPressed: _openCache,
    icon: Badge(
      isLabelVisible:
          _hasActiveJobs ||
          _cacheJobs.values.any((job) => job.status == CacheJobStatus.failed),
      child: const Icon(Icons.download_outlined),
    ),
  );
  void _leaveActivity() => setState(() => _activeGroup = null);
  Widget _library() {
    final active = _activeGroup;
    final catalog = Column(
      children: [
        ArchivePageHeader(
          key: const Key('catalog-header'),
          title: '剧情馆',
          trailing: _cacheShortcut(),
          bottom: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('story-search'),
                controller: _search,
                onChanged: (value) => setState(() {
                  _filter = value;
                  _catalogPages.clear();
                }),
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
                            setState(() {
                              _filter = '';
                              _catalogPages.clear();
                            });
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
        // 分类切换统一为横向滑动分页，与移动端交互一致。
        Expanded(
          child: PageView.builder(
            key: const PageStorageKey('category-pages'),
            controller: _categoryPageController,
            itemCount: _categories.length,
            onPageChanged: (value) => setState(() => _category = value),
            itemBuilder: (context, index) => _catalogPage(index),
          ),
        ),
      ],
    );
    return Column(
      children: [
        if (_playError != null)
          Container(
            color: AppColors.of(context).danger.withValues(alpha: .08),
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _playError!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.of(context).danger,
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
          child: ArchivePageTransition(
            transitionKey: (active?.name, active?.entryType),
            depth: active == null ? 0 : 1,
            child: active == null ? catalog : _chapterDetail(active),
          ),
        ),
      ],
    );
  }

  Widget _catalogPage(int category) {
    final groups = _visibleGroups(category);
    final pageCount =
        (groups.length + _catalogPageSize - 1) ~/ _catalogPageSize;
    final page = (_catalogPages[category] ?? 0).clamp(
      0,
      pageCount == 0 ? 0 : pageCount - 1,
    );
    final start = page * _catalogPageSize;
    final pageGroups = groups.skip(start).take(_catalogPageSize).toList();
    return KeyedSubtree(
      key: PageStorageKey('catalog-$category-$page-$_filter'),
      child: CustomScrollView(
        key: PageStorageKey('chapters-$category'),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Text(
                _groups == null
                    ? '正在读取剧情索引'
                    : '${groups.length} 个篇章 · ${groups.fold<int>(0, (sum, group) => sum + _entries(group).length)} 幕',
                style: TextStyle(
                  color: AppColors.of(context).subtext,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          _catalogBody(pageGroups, category),
          if (pageCount > 1)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '上一页',
                      onPressed: page == 0
                          ? null
                          : () => setState(
                              () => _catalogPages[category] = page - 1,
                            ),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    PopupMenuButton<int>(
                      tooltip: '选择页码',
                      initialValue: page,
                      onSelected: (value) =>
                          setState(() => _catalogPages[category] = value),
                      itemBuilder: (context) => [
                        for (var index = 0; index < pageCount; index++)
                          PopupMenuItem(
                            value: index,
                            child: Text('第 ${index + 1} 页'),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 12,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${page + 1} / $pageCount',
                              style: TextStyle(
                                color: AppColors.of(context).subtext,
                              ),
                            ),
                            Icon(
                              Icons.arrow_drop_down,
                              color: AppColors.of(context).subtext,
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '下一页',
                      onPressed: page + 1 == pageCount
                          ? null
                          : () => setState(
                              () => _catalogPages[category] = page + 1,
                            ),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
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
    );
  }

  void _selectCategory(int category) {
    if (_categoryPageController.hasClients) {
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
                    ? AppColors.of(context).indicator
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
                  ? AppColors.of(context).text
                  : AppColors.of(context).subtext,
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
        title: '没有匹配的剧情',
        message: '试试其他关键词或切换分类。',
        action: TextButton(
          onPressed: () {
            _search.clear();
            setState(() {
              _filter = '';
              _catalogPages.clear();
            });
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
      child: Stack(
        children: [
          if (activityImages[group.id] case final imageUrl?)
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) => Align(
                  alignment: Alignment.centerRight,
                  child: IgnorePointer(
                    child: ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (bounds) => const LinearGradient(
                        colors: [
                          Colors.transparent,
                          Color(0x33000000),
                          Color(0xB3000000),
                        ],
                        stops: [0.1, 0.55, 1.0],
                      ).createShader(bounds),
                      child: Image.network(
                        imageUrl,
                        height: constraints.maxHeight,
                        fit: BoxFit.fitHeight,
                        alignment: Alignment.centerRight,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Material(
            color: Colors.transparent,
            child: ListTile(
              key: ValueKey('chapter-${group.name}'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              title: Text(
                group.name,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                '${_categories[_categoryOf(group)]} · ${_entries(group).length} 幕',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.of(context).subtext,
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => setState(() => _activeGroup = group),
            ),
          ),
        ],
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
          trailing: _cacheShortcut(),
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
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.of(context).subtext,
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

  Widget _stageRow(StoryEntry entry) {
    final hasProgress =
        _repository.store.getPlaybackProgress(entry.path) != null;
    final completed = _repository.store.completedStories.contains(entry.path);
    final job = _cacheJobs[entry.path];
    final activeJob = job != null && _isJobActive(job);
    final hasMeta =
        hasProgress ||
        completed ||
        activeJob ||
        entry.code.isNotEmpty ||
        entry.tag.isNotEmpty ||
        _cached.contains(entry.path);
    return Material(
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
                    if (hasMeta) ...[
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (hasProgress)
                            ArchiveTag(
                              '继续观看',
                              key: ValueKey('continue-${entry.path}'),
                              color: AppColors.of(context).yellow,
                            ),
                          if (!hasProgress && completed)
                            ArchiveTag(
                              '已看完',
                              key: ValueKey('completed-${entry.path}'),
                              color: AppColors.of(context).green,
                            ),
                          if (entry.code.isNotEmpty)
                            Text(
                              entry.code,
                              style: AppTypography.tacticalCode.copyWith(
                                color: AppColors.of(context).subtext,
                                fontSize: 13,
                              ),
                            ),
                          if (entry.tag.isNotEmpty)
                            ArchiveTag(
                              entry.tag,
                              color: AppColors.of(context).subtext,
                            ),
                          if (activeJob)
                            Tooltip(
                              message: '缓存中',
                              child: Icon(
                                Icons.downloading,
                                size: 16,
                                color: AppColors.of(context).green,
                              ),
                            )
                          else if (_cached.contains(entry.path))
                            Tooltip(
                              message: '已缓存',
                              child: Icon(
                                Icons.offline_pin_outlined,
                                size: 16,
                                color: AppColors.of(context).indicator,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    Text(
                      entry.name.isEmpty ? entry.title : entry.name,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: AppColors.of(context).text,
                        height: 1.5,
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
                icon: const Icon(Icons.play_arrow, size: 22),
              ),
              PopupMenuButton<String>(
                tooltip: '${entry.title}的更多操作',
                position: PopupMenuPosition.under,
                offset: const Offset(0, 4),
                // 置零消除 under 模式对 IconButton 默认 padding 的 8px 补偿，
                // 使菜单恰好落在按钮下方而不与按钮重叠。
                padding: EdgeInsets.zero,
                onSelected: (_) => _cacheEntry(entry),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'cache',
                    enabled:
                        !_cached.contains(entry.path) &&
                        !activeJob &&
                        !_busy &&
                        !_deletingCache &&
                        !_movingDirectory,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.download_outlined,
                          size: 20,
                          color: AppColors.of(context).secondary,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _cached.contains(entry.path)
                              ? '已缓存'
                              : activeJob
                              ? '缓存中'
                              : '缓存',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final job in _cacheJobs.values) {
      job.control.cancel();
    }
    unawaited(_cacheNetworkSubscription?.cancel());
    _categoryPageController.dispose();
    _search.dispose();
    _updateClient.close();
    _ownedAssets?.close();
    super.dispose();
  }
}
