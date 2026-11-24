import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:arknights_story_player/app/app_theme.dart';
import 'package:arknights_story_player/app/audio_preview.dart';
import 'package:arknights_story_player/app/export_job.dart';
import 'package:arknights_story_player/app/story_export_page.dart';
import 'package:arknights_story_player/app/story_launcher.dart';
import 'package:arknights_story_player/story_player/data/asset_package.dart';
import 'package:arknights_story_player/story_player/data/export_target.dart';
import 'package:arknights_story_player/story_player/data/export_target_backend.dart';
import 'package:arknights_story_player/story_player/data/file_cache.dart';
import 'package:arknights_story_player/story_player/data/story_export.dart';
import 'package:arknights_story_player/story_player/story_player.dart';

class _MemoryCache extends FileCache {
  final data = <Uri, Uint8List>{};
  final stories = <String, Map<Uri, Uint8List>>{};

  @override
  Future<Uint8List?> read(
    Uri uri, {
    String? story,
    bool allowShared = true,
  }) async =>
      stories[story]?[uri] ?? (story == null || allowShared ? data[uri] : null);

  @override
  Future<void> write(Uri uri, Uint8List bytes, {String? story}) async {
    (story == null ? data : stories.putIfAbsent(story, () => {}))[uri] = bytes;
  }

  @override
  Future<int?> sizeOf(Uri uri, {String? story}) async =>
      (stories[story]?[uri] ?? (story == null ? null : data[uri]))?.length;
}

class _FakeBackend implements AudioPreviewBackend {
  final sources = <Uri>[];
  var playCalls = 0;
  var pauseCalls = 0;
  var disposed = false;
  final _positions = StreamController<Duration>.broadcast();
  Completer<void>? _playing;

  /// 模拟 Windows 上本地文件 URI 打不开。
  bool failOnFile = false;

  /// 模拟网络地址也无法访问。
  bool failAll = false;

  @override
  Future<void> setSource(Uri uri) async {
    sources.add(uri);
    if (failAll || (failOnFile && uri.isScheme('file'))) {
      throw StateError('无法打开音频');
    }
  }

  /// 与 just_audio 一致：play() 的 Future 等到播放结束、暂停或停止才完成。
  /// 30 秒试听计时与进度订阅必须在 play() 返回之前就生效。
  @override
  Future<void> play() async {
    playCalls++;
    await (_playing ??= Completer<void>()).future;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing?.complete();
    _playing = null;
  }

  @override
  Stream<Duration> get positions => _positions.stream;

  /// 播放器上报播放位置（仅在有订阅时能传达到控制器）。
  void emitPosition(Duration position) => _positions.add(position);

  @override
  void dispose() {
    disposed = true;
    _playing?.complete();
    _playing = null;
    _positions.close();
  }
}

const _entry = StoryEntry(
  '14-1 余火 行动前',
  'main/14-1',
  code: '14-1',
  name: '余火',
  tag: '行动前',
);
const _group = StoryGroup('慈悲灯塔', [_entry], entryType: 'MAINLINE');

const _script = r'''
[Background(image="bg_forest")]
[PlayMusic(key="$theme")]
[CharSlot(slot="m",name="amiya#1")]
对白
''';

Future<StoryRepository> _seededRepository() async {
  final cache = _MemoryCache();
  final store = AssetStore(
    cache: cache,
    client: MockClient((request) async => http.Response('not an image', 200)),
  );
  final repository = StoryRepository(store);
  await cache.write(
    StoryRepository.storyBase.resolve('main/14-1.txt'),
    Uint8List.fromList(utf8.encode(_script)),
    story: 'main/14-1',
  );
  for (final (uri, body) in [
    (
      MediaCatalog.tableUris[0],
      {'theme': 'Sound_Beta_2/Music/AVG/m_theme_loop'},
    ),
    (
      MediaCatalog.tableUris[1],
      {
        'amiya': {
          'pos': {'x': 30, 'y': 150},
          'size': {'x': 1000, 'y': 1000},
          'groups': [
            {
              'mode': 'face_overlay',
              'base': r'amiya/amiya$1',
              'faceRect': {'x': 460, 'y': 87, 'w': 115, 'h': 82},
            },
          ],
          'array': [
            {
              'name': r'1$1',
              'alias': '',
              'group': 0,
              'face': r'amiya/1$1',
              'body': 0,
              'index': 0,
            },
          ],
        },
      },
    ),
    (MediaCatalog.tableUris[2], {}),
  ]) {
    await cache.write(uri, Uint8List.fromList(utf8.encode(jsonEncode(body))));
  }
  return repository;
}

Future<void> _mountDialog(
  WidgetTester tester,
  StoryRepository repository, {
  ExportJob? existingJob,
  ExportJob Function(AssetPackage, List<AssetItem>, String)? onStart,
  Size size = const Size(1280, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: StoryExportDialog(
          repository: repository,
          entry: _entry,
          group: _group,
          parentPath: r'C:\Exports',
          cached: true,
          appVersion: '1.1.2',
          existingJob: existingJob,
          onStartExport: onStart ?? (_, _, _) => throw StateError('不应导出'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 菜单测试用仓库：目录来自静态数据，不访问网络。
class _UiRepository extends StoryRepository {
  _UiRepository({AssetStore? store})
    : super(store ?? AssetStore(cache: _MemoryCache()));

  @override
  Future<List<StoryGroup>> loadIndex() async => [_group];

  @override
  Future<List<StoryGroup>> refreshIndex() => loadIndex();

  @override
  Future<List<StoryGroup>> loadLocalIndex() => loadIndex();
}

/// 直接返回手工清单，用于验证列表统计口径。
class _PackageRepository extends _UiRepository {
  _PackageRepository(this.package, {super.store});

  final AssetPackage package;

  @override
  Future<AssetPackage> packageEntry(
    StoryEntry entry, {
    StoryGroup? group,
  }) async => package;
}

/// 记录完成动作的假后端：真实后端（目录写盘、zip 打包）的行为由
/// story_export_test 在真实事件循环中覆盖，这里只验证结果视图与
/// 完成按钮的接线，不碰真实文件 IO。
class _RecordingExportBackend implements ExportTargetBackend {
  _RecordingExportBackend({
    required String actionLabel,
    required this.directorySelection,
  }) : openActionLabel = actionLabel;

  @override
  final String openActionLabel;

  final bool directorySelection;
  String? _rootName;
  final opened = <String>[];

  @override
  String? get rootPath => _rootName;

  @override
  bool get supportsDirectorySelection => directorySelection;

  @override
  String destinationSummary(String parentPath, String rootName) =>
      directorySelection
      ? '保存到 $parentPath/$rootName'
      : '打包为 ${rootName.replaceAll('/', '_')}.zip';

  @override
  String describeCompletion(String rootPath) =>
      directorySelection ? '素材已导出到 $rootPath' : '素材已打包为 $rootPath';

  @override
  Future<String> createDirectory(String parentPath, String name) async =>
      _rootName = directorySelection
      ? '$parentPath/$name'
      : '${name.replaceAll('/', '_')}.zip';

  @override
  Future<void> writeFile(String relativePath, List<int> bytes) async {}

  @override
  Future<void> commit() async {}

  @override
  Future<void> deleteDirectory() async {
    _rootName = null;
  }

  @override
  Future<void> openResult() async {
    final root = _rootName;
    if (root == null) throw StateError('尚未创建导出目录');
    opened.add(root);
  }
}

Future<void> _mountLauncher(
  WidgetTester tester,
  StoryRepository repository,
) async {
  await repository.store.loadSettings();
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: StoryLauncher(repository: repository),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('试听切换自动停止上一项，30 秒到点暂停并标记结束', () {
    fakeAsync((async) {
      final backend = _FakeBackend();
      final controller = AudioPreviewController(
        resolveSource: (uri) async => uri,
        initialBackend: backend,
      );

      controller.toggle('a', Uri.parse('https://x.test/a.mp3'));
      async.elapse(const Duration(milliseconds: 20));
      expect(controller.isPlaying('a'), isTrue);
      expect(backend.sources, [Uri.parse('https://x.test/a.mp3')]);
      expect(backend.playCalls, 1);
      // play() 尚未完成时进度订阅与计时器也必须已经生效。
      backend.emitPosition(const Duration(seconds: 5));
      async.elapse(const Duration(milliseconds: 1));
      expect(controller.position, const Duration(seconds: 5));

      controller.toggle('b', Uri.parse('https://x.test/b.mp3'));
      async.elapse(const Duration(milliseconds: 20));
      expect(controller.isPlaying('b'), isTrue);
      expect(controller.isPlaying('a'), isFalse);
      expect(backend.pauseCalls, greaterThanOrEqualTo(1));

      async.elapse(AudioPreviewController.limit);
      expect(controller.ended, isTrue);
      expect(controller.isPlaying('b'), isFalse);
      expect(backend.pauseCalls, greaterThanOrEqualTo(2));

      controller.dispose();
      expect(backend.disposed, isTrue);
    });
  });

  test('本地文件打不开时回退网络地址，回退也失败才报错', () {
    fakeAsync((async) {
      final backend = _FakeBackend()..failOnFile = true;
      final controller = AudioPreviewController(
        resolveSource: (uri) async => Uri.file(r'C:\缓存\a.mp3'),
        initialBackend: backend,
      );

      controller.toggle('a', Uri.parse('https://x.test/a.mp3'));
      async.elapse(const Duration(milliseconds: 20));
      expect(backend.sources, [
        Uri.file(r'C:\缓存\a.mp3'),
        Uri.parse('https://x.test/a.mp3'),
      ]);
      expect(controller.errorOf('a'), isNull);
      expect(controller.isPlaying('a'), isTrue);

      // 网络地址也失败时才进入错误态，且错误只归属对应条目。
      backend.failAll = true;
      controller.toggle('b', Uri.parse('https://x.test/b.mp3'));
      async.elapse(const Duration(milliseconds: 20));
      expect(controller.errorOf('b'), isNotNull);
      expect(controller.errorOf('a'), isNull);
      expect(controller.isPlaying('b'), isFalse);

      controller.dispose();
      expect(backend.disposed, isTrue);
    });
  });

  testWidgets('对话框展示清单摘要、分类计数与默认全选', (tester) async {
    final repository = await _seededRepository();
    addTearDown(repository.store.close);
    await _mountDialog(tester, repository);

    expect(find.text('导出《14-1 余火 行动前》素材'), findsOneWidget);
    expect(find.textContaining('4 项 / 5 个文件 · 已离线缓存，无需联网'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('立绘'), findsOneWidget);
    expect(find.text('音频'), findsOneWidget);
    expect(find.text('脚本'), findsOneWidget);
    expect(find.textContaining('已选 4 项'), findsOneWidget);
  });

  testWidgets('取消勾选会更新统计与导出按钮，启动导出切换到进度视图', (tester) async {
    final repository = await _seededRepository();
    addTearDown(repository.store.close);
    final started = <(AssetPackage, List<AssetItem>, String)>[];
    await _mountDialog(
      tester,
      repository,
      onStart: (package, items, parent) {
        started.add((package, items, parent));
        return ExportJob(package: package, items: items, parentPath: parent);
      },
    );

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 3 项'), findsOneWidget);
    expect(find.text('导出素材 (3)'), findsOneWidget);

    await tester.tap(find.text('导出素材 (3)'));
    await tester.pumpAndSettle();
    expect(started, hasLength(1));
    expect(started.single.$2, hasLength(3));
    expect(started.single.$3, r'C:\Exports');
    expect(find.text('正在导出素材…'), findsOneWidget);
    expect(find.text('后台继续'), findsOneWidget);
  });

  testWidgets('挂接运行中的任务直接显示进度视图', (tester) async {
    final repository = await _seededRepository();
    addTearDown(repository.store.close);
    final package = await repository.packageEntry(_entry, group: _group);
    final job = ExportJob(
      package: package,
      items: package.items,
      parentPath: r'C:\Exports',
    );
    job.apply(done: 2, total: 5, bytes: 2048);
    await _mountDialog(tester, repository, existingJob: job);

    expect(find.text('正在导出素材…'), findsOneWidget);
    expect(find.textContaining('2 / 5 个文件'), findsOneWidget);
  });

  testWidgets('跨条目共享的同一文件只计一次大小', (tester) async {
    final cache = _MemoryCache();
    final shared = Uri.parse('https://x.test/shared.png');
    await cache.write(
      shared,
      Uint8List.fromList(List.filled(800, 0)),
      story: 'main/14-1',
    );
    final package = AssetPackage.fromRefs(
      storyTitle: _entry.title,
      storyPath: _entry.path,
      groupName: _group.name,
      entryType: 'MAINLINE',
      refs: [
        AssetRef(AssetKind.cg, 'shared', [
          AssetFile(shared, 'images/cg/shared.png'),
        ]),
        AssetRef(AssetKind.other, 'shared', [
          AssetFile(shared, 'images/item/shared.png'),
        ]),
      ],
      script: [],
      unresolved: [],
    );
    final repository = _PackageRepository(
      package,
      store: AssetStore(cache: cache),
    );
    addTearDown(repository.store.close);
    await _mountDialog(tester, repository);

    // 两个条目共享同一来源：字节只计一次，目标路径有两个因此文件数为 2。
    expect(find.textContaining('已选 2 项 · 800 B / 2 个文件'), findsOneWidget);
  });

  testWidgets('桌面端剧情行菜单提供导出入口', (tester) async {
    final repository = _UiRepository();
    addTearDown(repository.store.close);
    // 基础校验在测试体结束时进行，平台覆盖必须在体内恢复。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await _mountLauncher(tester, repository);
      await tester.tap(find.byKey(const ValueKey('chapter-慈悲灯塔')));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('14-1 余火 行动前的更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('导出素材…'), findsOneWidget);
      expect(find.text('缓存'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android 菜单同样提供导出入口并打开对话框', (tester) async {
    // flutter test 默认目标平台是 android，无需覆盖。
    final package = AssetPackage.fromRefs(
      storyTitle: _entry.title,
      storyPath: _entry.path,
      groupName: _group.name,
      entryType: 'MAINLINE',
      refs: [
        AssetRef(AssetKind.background, 'bg', [
          AssetFile(
            Uri.parse('https://x.test/bg.png'),
            'images/background/bg.png',
          ),
        ]),
      ],
      script: [],
      unresolved: [],
    );
    final repository = _PackageRepository(package);
    addTearDown(repository.store.close);
    await _mountLauncher(tester, repository);
    await tester.tap(find.byKey(const ValueKey('chapter-慈悲灯塔')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('14-1 余火 行动前的更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('导出素材…'), findsOneWidget);
    await tester.tap(find.text('导出素材…'));
    await tester.pumpAndSettle();
    expect(find.text('导出《14-1 余火 行动前》素材'), findsOneWidget);
    // 底栏提示 zip 打包，不提供目录选择。
    expect(find.textContaining('打包为 慈悲灯塔_14-1 余火 行动前.zip'), findsOneWidget);
    expect(find.text('更改'), findsNothing);
  });

  testWidgets('桌面底栏显示保存目录并提供更改', (tester) async {
    final repository = await _seededRepository();
    addTearDown(repository.store.close);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await _mountDialog(tester, repository);
      expect(find.text(r'保存到 C:\Exports/慈悲灯塔/14-1 余火 行动前'), findsOneWidget);
      expect(find.text('更改'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android 底栏显示打包 zip 说明且不提供目录更改', (tester) async {
    final repository = await _seededRepository();
    addTearDown(repository.store.close);
    // 默认 android 平台。
    await _mountDialog(tester, repository, size: const Size(390, 844));
    expect(find.text('打包 zip 后系统分享'), findsOneWidget);
    expect(find.text('更改'), findsNothing);
    expect(find.textContaining('保存到'), findsNothing);
  });

  testWidgets('窄屏竖屏改用顶部分类栏与全宽网格，右侧不再被挤成细条', (tester) async {
    final repository = await _seededRepository();
    addTearDown(repository.store.close);
    // 手机竖屏：分类改为顶部横向标签，条目网格独占整宽。
    await _mountDialog(tester, repository, size: const Size(390, 844));
    for (final label in ['图片', '立绘', '音频', '脚本']) {
      expect(find.text(label), findsOneWidget);
    }
    final grid = tester.getSize(find.byType(GridView));
    expect(grid.width, 390);
    expect(grid.height, greaterThan(450));
    expect(find.text('类型：全部'), findsOneWidget);
    await tester.tap(find.byTooltip('筛选素材类型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CG'));
    await tester.pumpAndSettle();
    expect(find.text('类型：CG'), findsOneWidget);
    expect(find.text('该剧情没有此类素材'), findsOneWidget);
    expect(find.text('导出素材 (4)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏底栏用三态复选框全选与清空', (tester) async {
    final repository = await _seededRepository();
    addTearDown(repository.store.close);
    await _mountDialog(tester, repository, size: const Size(390, 844));
    final all = find.widgetWithText(InkWell, '全选');
    Checkbox dockCheckbox() => tester.widget(
      find.byWidgetPredicate((widget) => widget is Checkbox && widget.tristate),
    );
    expect(dockCheckbox().value, isTrue);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(dockCheckbox().value, isNull);
    await tester.tap(all);
    await tester.pumpAndSettle();
    expect(dockCheckbox().value, isTrue);
    await tester.tap(all);
    await tester.pumpAndSettle();
    expect(dockCheckbox().value, isFalse);
    expect(find.text('未选择素材'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏保持左侧分类栏双栏布局', (tester) async {
    final repository = await _seededRepository();
    addTearDown(repository.store.close);
    await _mountDialog(tester, repository);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(find.byTooltip('筛选素材类型'), findsNothing);
    await tester.tap(find.text('CG'));
    await tester.pumpAndSettle();
    expect(find.text('该剧情没有此类素材'), findsOneWidget);
  });

  testWidgets('Android 完成视图提供分享并调用系统分享', (tester) async {
    final repository = await _seededRepository();
    addTearDown(repository.store.close);
    final package = await repository.packageEntry(_entry, group: _group);
    final backend = _RecordingExportBackend(
      actionLabel: '分享',
      directorySelection: false,
    );
    final target = ExportTarget(backend: backend);
    await target.createDirectory('', '慈悲灯塔/14-1 余火 行动前');
    final job =
        ExportJob(
          package: package,
          items: package.items,
          parentPath: '',
          target: target,
        )..apply(
          status: ExportJobStatus.completed,
          result: ExportResult(
            rootPath: '慈悲灯塔_14-1 余火 行动前.zip',
            fileCount: 5,
            totalBytes: 2048,
            failures: const [],
            manifest: const {},
          ),
        );
    await _mountDialog(tester, repository, existingJob: job);

    expect(find.text('素材已导出'), findsOneWidget);
    // zip 名出现在结果位置行与底栏目的地提示两处。
    expect(find.textContaining('慈悲灯塔_14-1 余火 行动前.zip'), findsOneWidget);
    await tester.tap(find.text('分享'));
    await tester.pumpAndSettle();
    expect(backend.opened, ['慈悲灯塔_14-1 余火 行动前.zip']);
  });

  testWidgets('桌面完成视图提供打开文件夹', (tester) async {
    final repository = await _seededRepository();
    addTearDown(repository.store.close);
    final package = await repository.packageEntry(_entry, group: _group);
    final backend = _RecordingExportBackend(
      actionLabel: '打开文件夹',
      directorySelection: true,
    );
    final target = ExportTarget(backend: backend);
    await target.createDirectory(r'C:\Exports', '慈悲灯塔/14-1 余火 行动前');
    final job =
        ExportJob(
          package: package,
          items: package.items,
          parentPath: r'C:\Exports',
          target: target,
        )..apply(
          status: ExportJobStatus.completed,
          result: ExportResult(
            rootPath: r'C:\Exports/慈悲灯塔/14-1 余火 行动前',
            fileCount: 5,
            totalBytes: 2048,
            failures: const [],
            manifest: const {},
          ),
        );
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await _mountDialog(tester, repository, existingJob: job);
      expect(find.text('打开文件夹'), findsOneWidget);
      await tester.tap(find.text('打开文件夹'));
      await tester.pumpAndSettle();
      expect(backend.opened, [r'C:\Exports/慈悲灯塔/14-1 余火 行动前']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
