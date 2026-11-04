import '../story_player/data/cache_control.dart';
import '../story_player/data/story_repository.dart';

enum CacheJobStatus { waiting, downloading, paused, completed, failed, cancelled }

class CacheJob {
  CacheJob(this.entry);

  final StoryEntry entry;
  final control = CacheControl();
  bool started = false;
  CacheJobStatus status = CacheJobStatus.waiting;
  int done = 0;
  int total = 0;
  String? error;
}
