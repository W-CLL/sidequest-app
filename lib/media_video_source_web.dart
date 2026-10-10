import 'package:video_player/video_player.dart';

VideoPlayerController localVideoController(String path) =>
    VideoPlayerController.networkUrl(Uri.parse(path));
