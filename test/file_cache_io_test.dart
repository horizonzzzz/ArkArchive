import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/data/file_cache_io.dart';

void main() {
  test('Windows 打开默认及自定义缓存目录时使用系统规范路径', () async {
    final root = await Directory.systemTemp.createTemp('缓存目录 空格-');
    addTearDown(() => root.delete(recursive: true));
    final support = await Directory('${root.path}/support').create();
    final selected = await Directory('${root.path}/自定义 缓存/story_assets')
        .create(recursive: true);
    final calls = <List<String>>[];
    FileCache cache() => FileCache(
      supportDirectory: () async => support,
      startProcess: (executable, arguments) async {
        calls.add([executable, ...arguments]);
      },
    );
    final initial = cache();
    await initial.openDirectory();
    expect(calls.single, [
      'explorer.exe',
      '/n,',
      await Directory((await initial.location())!).resolveSymbolicLinks(),
    ]);
    await File('${support.path}/story_cache_directory.json')
        .writeAsString('"${selected.path.replaceAll(r'\', '/')}"');
    await cache().openDirectory();
    expect(calls.last, [
      'explorer.exe',
      '/n,',
      await selected.resolveSymbolicLinks(),
    ]);
    expect(calls.every((call) => !call.last.contains('/')), isTrue);
  }, skip: !Platform.isWindows);

  test('缓存目录迁移保留数据，重启后使用新目录且不覆盖已有目录', () async {
    final root = await Directory.systemTemp.createTemp('story-cache-test-');
    addTearDown(() => root.delete(recursive: true));
    final support = await Directory('${root.path}/support').create();
    final destination = await Directory('${root.path}/destination').create();
    final cache = FileCache(supportDirectory: () async => support);
    final uri = Uri.parse('https://example.test/image.png');
    await cache.write(uri, Uint8List.fromList([1, 2, 3]));
    final original = (await cache.location())!;
    await cache.setDirectory(destination.path);
    expect(await cache.read(uri), [1, 2, 3]);
    expect(await Directory(original).exists(), isTrue);
    final reopened = FileCache(supportDirectory: () async => support);
    expect(await reopened.read(uri), [1, 2, 3]);
    expect(await reopened.location(), await cache.location());
    final occupied = await Directory('${root.path}/occupied').create();
    await Directory('${occupied.path}/story_assets').create();
    await expectLater(
      cache.setDirectory(occupied.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(await cache.read(uri), [1, 2, 3]);
    final second = await Directory('${root.path}/second').create();
    await cache.setDirectory(second.path);
    expect(
      await FileCache(supportDirectory: () async => support).location(),
      await cache.location(),
    );
    expect(await cache.read(uri), [1, 2, 3]);
  });
  test('目录配置写入失败时保留旧缓存，清除新副本后可以重试', () async {
    final root = await Directory.systemTemp.createTemp('story-cache-rollback-');
    addTearDown(() => root.delete(recursive: true));
    final support = await Directory('${root.path}/support').create();
    final destination = await Directory('${root.path}/destination').create();
    final cache = FileCache(supportDirectory: () async => support);
    final uri = Uri.parse('https://example.test/image.png');
    await cache.write(uri, Uint8List.fromList([1, 2, 3]));
    final original = await cache.location();
    final obstruction = await Directory(
      '${support.path}/story_cache_directory.json',
    ).create();
    await expectLater(
      cache.setDirectory(destination.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(await cache.location(), original);
    expect(await cache.read(uri), [1, 2, 3]);
    expect(
      await Directory('${destination.path}/story_assets').exists(),
      isFalse,
    );
    await obstruction.delete();
    await cache.setDirectory(destination.path);
    expect(await cache.read(uri), [1, 2, 3]);
  });

  test('同一素材并发写入不会共用临时文件或留下半份数据', () async {
    final root = await Directory.systemTemp.createTemp('story-cache-writes-');
    addTearDown(() => root.delete(recursive: true));
    final cache = FileCache(supportDirectory: () async => root);
    final uri = Uri.parse('https://example.test/shared.png');
    await Future.wait(
      List.generate(
        8,
        (index) =>
            cache.write(uri, Uint8List.fromList(List.filled(4096, index))),
      ),
    );
    final bytes = (await cache.read(uri))!;
    expect(bytes, hasLength(4096));
    expect(bytes.toSet(), hasLength(1));
    expect(bytes.first, inInclusiveRange(0, 7));
    // 同一素材只写入共享层一份。
    final shared = Directory(
      '${(await cache.location())!}${Platform.pathSeparator}_shared',
    );
    expect(await shared.list().length, 1);
  });
  test('清空真实缓存保留指定资源和非缓存文件，目录仍可写入', () async {
    final root = await Directory.systemTemp.createTemp('story-cache-clear-');
    addTearDown(() => root.delete(recursive: true));
    final cache = FileCache(supportDirectory: () async => root);
    final asset = Uri.parse('https://example.test/image.png');
    final retained = Uri.parse('https://local.invalid/settings');
    await cache.write(asset, Uint8List.fromList([1, 2]));
    await cache.write(retained, Uint8List.fromList([9]));
    final notes = File('${await cache.location()}/notes.txt');
    await notes.writeAsString('keep');
    await cache.clear(keep: {retained});
    expect(await cache.read(asset), isNull);
    expect(await cache.read(retained), [9]);
    expect(await notes.readAsString(), 'keep');
    await cache.write(asset, Uint8List.fromList([3]));
    expect(await cache.read(asset), [3]);
  });

  test('剧情素材存独立目录，删除单幕整目录回收，其他剧情不受影响', () async {
    final root = await Directory.systemTemp.createTemp('story-cache-scope-');
    addTearDown(() => root.delete(recursive: true));
    final cache = FileCache(supportDirectory: () async => root);
    final asset = Uri.parse('https://example.test/image.png');
    await cache.write(asset, Uint8List.fromList([1]), story: 'main/0-1');
    await cache.write(asset, Uint8List.fromList([2]), story: 'main/0-2');
    // 同一素材在每个剧情目录各存一份，互不共用。
    expect(await cache.read(asset, story: 'main/0-1'), [1]);
    expect(await cache.read(asset, story: 'main/0-2'), [2]);
    // 剧情层未命中时回退共享层。
    final shared = Uri.parse('https://example.test/shared.png');
    await cache.write(shared, Uint8List.fromList([9]));
    expect(await cache.read(shared, story: 'main/0-1'), [9]);
    expect(await cache.size(), 3);
    await cache.deleteStory('main/0-1');
    expect(await cache.read(asset, story: 'main/0-1'), isNull);
    expect(await cache.read(asset, story: 'main/0-2'), [2]);
    expect(await cache.read(shared), [9]);
    // 清空缓存删除所有剧情目录，共享层按 keep 保留。
    await cache.clear(keep: {shared});
    expect(await cache.read(asset, story: 'main/0-2'), isNull);
    expect(await cache.read(shared), [9]);
  });
}
