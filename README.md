# 明日方舟剧情播放器

Flutter 剧情播放器原型。首页从 PRTS 的剧情索引列出全部剧情节点，选中后加载对应脚本和素材播放；应用不内置关卡地址。

## 运行

```sh
flutter pub get
flutter run -d chrome
```

剧情目录、脚本和游戏素材从 PRTS 静态数据站按需加载。对白字体（`assets/fonts/NotoSansHans-Medium.ttf`）和滑动遮罩纹理已随应用打包，运行时不联网获取。加载剧情需要网络，用户应只使用有权访问的剧情和资源。

## 复用播放器

播放器不依赖应用入口或关卡目录。外部页面先准备 `PreparedStory`，再将其传入 `StoryPlayer`：

```dart
import 'package:arknights_story_player/story_player/story_player.dart';

final assets = AssetStore();
final repository = StoryRepository(assets);
final document = await repository.load(Uri.parse(storyUrl));
final prepared = await repository.prepare(document);

Navigator.of(context).push(MaterialPageRoute<void>(
  builder: (_) => StoryPlayer(story: prepared),
));
```

目录页可以调用 `StoryRepository.loadIndex()` 取到按章节分组的 `StoryGroup` 列表，再交给 `loadEntry(entry)` 下载脚本；也可以自行创建 `StoryDocument` 后交给 `prepare()`。`prepare()` 只准备该剧情需要的图片和音频，字体与遮罩不参与下载。播放器核心通过 `StoryEngine` 执行解析后的命令；`StoryPlayer` 负责舞台和交互。资源缓存随 `AssetStore` 所有者管理，应用退出时调用 `assets.close()`。

演出依据、模块边界和未支持效果见 [docs/player_alignment.md](docs/player_alignment.md)。

## 验证与构建

```sh
flutter analyze
flutter test --reporter expanded
flutter build web --release --no-web-resources-cdn
```

Web 构建输出在 `build/web/`，需要通过 HTTP 服务访问。`--no-web-resources-cdn` 将 Flutter 渲染器资源放入构建目录；剧情目录、脚本和游戏素材仍按需联网获取。打包的字体与遮罩同时供原生端和 Web 使用，Web 不再受这两个资源的跨域限制。

`test/reference_live_test.dart` 默认跳过联网。复核真实剧情时，给 `flutter test test/reference_live_test.dart` 传入 `--dart-define=STORY_REFERENCE_URL=<剧情页或原始脚本URL>`；该测试会下载静态依赖并解码图片，需要网络连接。
