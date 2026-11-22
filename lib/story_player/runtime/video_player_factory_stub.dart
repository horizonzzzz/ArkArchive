import 'package:video_player/video_player.dart';

/// Web 平台没有本地文件通道；视频缓存命中时主实现已回退原始网络地址，
/// 这里只需要网络控制器。
VideoPlayerController createVideoController(Uri source) =>
    VideoPlayerController.networkUrl(source);
