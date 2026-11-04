# 明日方舟剧情播放器

Flutter 剧情播放器原型。首页从 PRTS 的剧情索引列出全部剧情节点，选中后加载对应脚本和素材播放；应用不内置关卡地址。

## 运行

```sh
flutter pub get
flutter run -d chrome
```

剧情目录、脚本和游戏素材从 PRTS 静态数据站按需加载。对白字体（`assets/fonts/NotoSansHans-Medium.ttf`）和滑动遮罩纹理已随应用打包，运行时不联网获取。首次加载或缓存剧情需要网络；已缓存的目录、脚本和素材可在离线时读取。用户应只使用有权访问的剧情和资源。

## 产品界面与占位边界

界面采用 ak-ui `system` 设计语言，用 Flutter 原生组件实现。窗口宽度达到 1100 时展示固定侧栏和篇章／关卡双栏；窄屏使用底部三项导航和篇章折叠列表。UI 字体复用已打包的 Noto Sans，不新增网络字体或依赖。

- **剧情馆**：保留 PRTS 真实索引、分类搜索和原有播放链路，增加篇章层级、多选及播放准备浮层。分类使用索引的 `entryType`，未识别条目保留在“其他档案”；当前索引未覆盖的玩法衍生篇展示待接入空态。
- **离线与缓存**：批量缓存选中的剧情、资源表及素材，显示每幕进度，可暂停、恢复或移除任务；暂停会中止当前素材请求，恢复时重新下载该文件，已完成素材保留。完成项自动移出待缓存，剧情馆显示已缓存标识并禁止重复选择；下载期间可单项或批量删除已离线剧情，共用素材及活跃任务所需素材会保留。旧版本缺少素材清单，或活跃任务尚未解析依赖时，会保守保留文件。资源被浏览器或系统清理后需要重新下载。
- **系统设置**：并发下载数为 1 至 8，同时限制剧情任务数与素材请求数，重启后保留。下载中调整立即生效，降档时超额任务等待名额，之后自动继续；用户手动暂停的任务不会自动恢复。Android 和 iOS 在开始使用移动数据或下载中切换到移动网络时弹窗确认，同一轮确认后不重复提示；拒绝会停止剩余任务并保留已完成素材。桌面客户端可查看、打开和更改缓存目录。容量显示包含应用缓存文件及设置数据。清空素材缓存会删除脚本、图片、音频及离线记录，保留剧情目录和下载设置。其他音量、播放偏好及强制离线控件仍为界面预览。

原生平台将资源保存在应用支持目录；Web 使用浏览器 Cache Storage，通常要求 HTTPS 或 localhost，受浏览器配额、隐私模式和清理策略影响。首次打开 Web 应用本身仍需要网络。下载失败不会阻止其他资源继续处理，超时、连接错误及部分服务器错误会重试一次。

桌面更改目录时会把现有缓存复制到所选目录下的 `story_assets`，不会覆盖已存在的同名目录，也不会删除原目录；确认新目录正常后可自行清理旧副本。移动网络提示依据系统报告的连接类型；无法确认网络类型时也会提示。实际网络路由和状态更新时机由系统决定，不能据此保证零移动流量。下载期间仍禁止迁移目录和清空全部缓存。

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
