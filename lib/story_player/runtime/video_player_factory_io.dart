import 'dart:io';

import 'package:video_player/video_player.dart';

/// 桌面/移动平台：本地缓存命中时用文件播放器，其余走网络流。
VideoPlayerController createVideoController(Uri source) =>
    source.scheme == 'file'
        ? VideoPlayerController.file(File.fromUri(source))
        : VideoPlayerController.networkUrl(source);
