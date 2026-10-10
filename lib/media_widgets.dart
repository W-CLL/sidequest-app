import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

import 'domain.dart';
import 'media_capture.dart';
import 'media_temporary_files.dart';
import 'media_video_source.dart';
import 'repository.dart';

String mediaLabel(MediaKind kind) => switch (kind) {
  MediaKind.image => '图片',
  MediaKind.video => '视频',
  MediaKind.audio => '语音',
};

String syncStatusLabel(String status) => switch (status) {
  'saved' => '已保存',
  'uploading' => '上传中',
  'processing' => '处理附件',
  'failed' => '上传失败，内容仍在本机',
  _ => '已存本机 · 等待上传',
};

/// Fetch bytes with fresh account headers instead of sharing a URL-only image
/// cache between signed-in accounts. Local files are never sent to an image URL.
class PrivateMediaImage extends StatefulWidget {
  const PrivateMediaImage({
    super.key,
    required this.media,
    required this.repository,
    this.thumbnail = true,
    this.fit = BoxFit.cover,
    this.onLoaded,
  });
  final MediaAttachment media;
  final QuestRepository repository;
  final bool thumbnail;
  final BoxFit fit;
  final VoidCallback? onLoaded;

  @override
  State<PrivateMediaImage> createState() => _PrivateMediaImageState();
}

class _PrivateMediaImageState extends State<PrivateMediaImage> {
  late Future<Uint8List> _bytes;
  bool _reported = false;

  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  @override
  void didUpdateWidget(PrivateMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media.id != widget.media.id ||
        oldWidget.media.localPath != widget.media.localPath ||
        oldWidget.thumbnail != widget.thumbnail) {
      _reported = false;
      _bytes = _load();
    }
  }

  Future<Uint8List> _load() async {
    final path = widget.media.localPath;
    if (path != null &&
        path.isNotEmpty &&
        widget.media.kind == MediaKind.image) {
      try {
        return await XFile(path).readAsBytes();
      } catch (_) {
        /* A confirmed upload may have removed its local source. */
      }
    }
    final headers = await widget.repository.mediaHeaders();
    final response = await http
        .get(
          Uri.parse(
            widget.repository.mediaUrl(
              widget.media,
              thumbnail: widget.thumbnail,
            ),
          ),
          headers: headers,
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw const QuestException('图片暂时无法读取');
    return response.bodyBytes;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _bytes,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return const Center(child: Icon(Icons.broken_image_outlined));
      }
      if (!snapshot.hasData) {
        return const Center(child: Icon(Icons.image_outlined));
      }
      return Image.memory(
        snapshot.data!,
        fit: widget.fit,
        errorBuilder: (_, error, stackTrace) =>
            const Center(child: Icon(Icons.broken_image_outlined)),
        frameBuilder: (context, child, frame, synchronouslyLoaded) {
          if ((frame != null || synchronouslyLoaded) && !_reported) {
            _reported = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onLoaded?.call();
            });
          }
          return child;
        },
      );
    },
  );
}

class AttachmentList extends StatelessWidget {
  const AttachmentList({
    super.key,
    required this.attachments,
    required this.repository,
    this.onRemove,
    this.onMove,
  });
  final List<MediaAttachment> attachments;
  final QuestRepository repository;
  final ValueChanged<MediaAttachment>? onRemove;
  final void Function(MediaAttachment media, int direction)? onMove;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: attachments
        .map(
          (media) => SizedBox(
            width: 102,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Material(
                  color: const Color(0xFFEAF0E6),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: ValueKey('media-open-${media.id}'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            MediaViewer(media: media, repository: repository),
                      ),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: 72,
                        minWidth: 102,
                      ),
                      child: media.kind == MediaKind.image
                          ? SizedBox(
                              height: 72,
                              width: 102,
                              child: PrivateMediaImage(
                                media: media,
                                repository: repository,
                              ),
                            )
                          : Padding(
                              padding: const EdgeInsets.all(6),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    media.kind == MediaKind.video
                                        ? Icons.play_circle_outline
                                        : Icons.mic_none,
                                  ),
                                  Text(
                                    '${mediaLabel(media.kind)}${media.durationMs == null ? '' : ' · ${(media.durationMs! / 1000).ceil()}秒'}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
                if (onMove != null &&
                    media.kind == MediaKind.image &&
                    attachments.where((m) => m.kind == MediaKind.image).length >
                        1)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        key: ValueKey('media-earlier-${media.id}'),
                        tooltip: '图片向前移',
                        onPressed:
                            attachments
                                    .where((m) => m.kind == MediaKind.image)
                                    .first
                                    .id ==
                                media.id
                            ? null
                            : () => onMove!(media, -1),
                        icon: const Icon(Icons.chevron_left, size: 20),
                      ),
                      IconButton(
                        key: ValueKey('media-later-${media.id}'),
                        tooltip: '图片向后移',
                        onPressed:
                            attachments
                                    .where((m) => m.kind == MediaKind.image)
                                    .last
                                    .id ==
                                media.id
                            ? null
                            : () => onMove!(media, 1),
                        icon: const Icon(Icons.chevron_right, size: 20),
                      ),
                    ],
                  ),
                if (onRemove != null)
                  IconButton(
                    key: ValueKey('media-remove-${media.id}'),
                    tooltip: '移除${mediaLabel(media.kind)}',
                    onPressed: () => onRemove!(media),
                    icon: const Icon(Icons.close, size: 18),
                    constraints: const BoxConstraints(
                      minHeight: 48,
                      minWidth: 48,
                    ),
                  ),
              ],
            ),
          ),
        )
        .toList(),
  );
}

class MediaComposer extends StatefulWidget {
  const MediaComposer({
    super.key,
    required this.repository,
    required this.accountId,
    required this.contextId,
    required this.attachments,
    required this.onChanged,
    required this.onError,
    this.enabled = true,
    this.onBusyChanged,
    this.recordingDirectory,
    this.removeRecordingFile,
  });
  final QuestRepository repository;
  final String accountId;
  final String contextId;
  final List<MediaAttachment> attachments;
  final ValueChanged<List<MediaAttachment>> onChanged;
  final ValueChanged<String> onError;
  final bool enabled;
  final ValueChanged<bool>? onBusyChanged;
  final Future<String> Function()? recordingDirectory;
  final Future<void> Function(String path)? removeRecordingFile;

  @override
  State<MediaComposer> createState() => _MediaComposerState();
}

class _MediaComposerState extends State<MediaComposer>
    with WidgetsBindingObserver {
  final _capture = MediaCapture();
  AudioRecorder? _recorder;
  Timer? _recordTimer;
  Timer? _recordLimit;
  Stopwatch? _watch;
  bool _busy = false, _recording = false;
  bool _hasRecovery = false;
  StreamSubscription<RecordState>? _recordSubscription;
  ({String path, int duration})? _pendingAudio;
  bool _reviewing = false;
  String? _recordPath;
  final _ownedRecordings = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _recover());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTimer?.cancel();
    _recordLimit?.cancel();
    unawaited(_recordSubscription?.cancel());
    unawaited(_disposeRecorder());
    super.dispose();
  }

  Future<void> _disposeRecorder() async {
    try {
      if (_recording) await _recorder?.cancel();
      await _recorder?.dispose();
    } catch (_) {
      // Disposing a platform recorder must not hide pending-data state.
    } finally {
      for (final path in Set<String>.of(_ownedRecordings)) {
        await _deleteRecording(path);
      }
    }
  }

  Future<void> _deleteRecording(String path) async {
    if (!_ownedRecordings.contains(path)) return;
    try {
      await (widget.removeRecordingFile ?? removeTemporaryRecording)(path);
      _ownedRecordings.remove(path);
    } catch (_) {
      // Retry at disposal. Only this composer's generated temp paths qualify.
    }
  }

  Future<void> _discardDetachedMedia(List<MediaAttachment> media) async {
    if (media.isEmpty) return;
    try {
      await widget.repository.discardStagedMedia(
        media.map((m) => m.id).toList(),
      );
    } catch (_) {
      if (mounted) widget.onError('未加入记录的附件暂未清理，请稍后重试。');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_recording &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive)) {
      unawaited(_stopRecording());
    }
    if (state == AppLifecycleState.resumed && _pendingAudio != null) {
      unawaited(_reviewAudio());
    }
  }

  Future<void> _recover() async {
    if (!mounted) return;
    setState(() => _busy = true);
    widget.onBusyChanged?.call(true);
    try {
      final media = await _capture.recover(
        repository: widget.repository,
        accountId: widget.accountId,
        contextId: widget.contextId,
      );
      if (mounted) {
        _append(media);
      } else {
        await _discardDetachedMedia(media);
      }
    } catch (error) {
      if (mounted) widget.onError('$error');
    } finally {
      final hasRecovery = await _capture.hasRecovery();
      if (mounted) {
        setState(() {
          _busy = false;
          _hasRecovery = hasRecovery;
        });
        widget.onBusyChanged?.call(false);
      }
    }
  }

  Future<void> _discardRecovery() async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('放弃尚未恢复的图库选择？'),
            content: const Text(
              '该选择可能来自其他账号或之前的编辑页面。只放弃尚未加入记录的系统选择结果，不删除原记录或原附件。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('放弃选择'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    try {
      await _capture.discardRecovery();
      if (mounted) setState(() => _hasRecovery = false);
    } catch (error) {
      if (mounted) widget.onError('暂时无法放弃图库选择，请重试。');
    }
  }

  void _append(List<MediaAttachment> media) {
    if (media.isEmpty) return;
    final replacing = media
        .where((m) => m.kind != MediaKind.image)
        .map((m) => m.kind)
        .toSet();
    final combined = [
      ...widget.attachments.where((m) => !replacing.contains(m.kind)),
      ...media,
    ];
    if (combined.where((m) => m.kind == MediaKind.image).length > 5 ||
        combined.where((m) => m.kind == MediaKind.video).length > 1 ||
        combined.where((m) => m.kind == MediaKind.audio).length > 1) {
      widget.onError('每条记录最多 5 张图片、1 段视频和 1 段语音。');
      unawaited(_discardDetachedMedia(media));
      return;
    }
    widget.onChanged(combined);
  }

  void _move(MediaAttachment media, int direction) {
    final images = widget.attachments
        .where((m) => m.kind == MediaKind.image)
        .toList();
    final index = images.indexWhere((m) => m.id == media.id);
    final other = index + direction;
    if (other < 0 || other >= images.length) return;
    final result = List<MediaAttachment>.of(widget.attachments);
    final left = result.indexWhere((m) => m.id == media.id);
    final right = result.indexWhere((m) => m.id == images[other].id);
    result[left] = images[other];
    result[right] = media;
    widget.onChanged(result);
  }

  Future<void> _pick(MediaKind kind) async {
    setState(() => _busy = true);
    widget.onBusyChanged?.call(true);
    try {
      final result = await _capture.pick(
        repository: widget.repository,
        accountId: widget.accountId,
        contextId: widget.contextId,
        kind: kind,
        remainingImages:
            5 -
            widget.attachments.where((m) => m.kind == MediaKind.image).length,
      );
      if (mounted) {
        _append(result);
      } else {
        await _discardDetachedMedia(result);
      }
    } catch (error) {
      if (mounted) widget.onError('$error');
    } finally {
      final hasRecovery = await _capture.hasRecovery();
      if (mounted) {
        setState(() {
          _busy = false;
          _hasRecovery = hasRecovery;
        });
      }
      if (mounted) widget.onBusyChanged?.call(false);
    }
  }

  Future<void> _startRecording() async {
    setState(() => _busy = true);
    widget.onBusyChanged?.call(true);
    try {
      _recorder ??= AudioRecorder();
      if (!await _recorder!.hasPermission()) {
        throw const QuestException('未获得麦克风权限，可在系统设置中开启后重试。');
      }
      final directory = widget.recordingDirectory == null
          ? (await getTemporaryDirectory()).path
          : await widget.recordingDirectory!();
      _recordSubscription ??= _recorder!.onStateChanged().listen((state) {
        if (_recording &&
            (state == RecordState.pause || state == RecordState.stop)) {
          unawaited(_stopRecording());
        }
      });
      _recordPath =
          '$directory/sidequest-${DateTime.now().microsecondsSinceEpoch}.m4a';
      _ownedRecordings.add(_recordPath!);
      await _recorder!.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: _recordPath!,
      );
      _watch = Stopwatch()..start();
      if (!mounted) {
        await _recorder!.cancel();
        await _deleteRecording(_recordPath!);
        return;
      }
      setState(() => _recording = true);
      _recordLimit = Timer(
        const Duration(milliseconds: 59700),
        () => unawaited(_stopRecording()),
      );
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if ((_watch?.elapsedMilliseconds ?? 0) >= 60000) {
          unawaited(_stopRecording());
        } else {
          setState(() {});
        }
      });
    } catch (error) {
      if (_recordPath != null) await _deleteRecording(_recordPath!);
      if (mounted) widget.onError('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
      if (mounted && !_recording) widget.onBusyChanged?.call(false);
    }
  }

  Future<void> _stopRecording() async {
    if (!_recording) return;
    _recordTimer?.cancel();
    _recordLimit?.cancel();
    _watch?.stop();
    final elapsed = (_watch?.elapsedMilliseconds ?? 0).clamp(1, 60000);
    setState(() {
      _recording = false;
      _busy = true;
    });
    try {
      final path = await _recorder!.stop() ?? _recordPath;
      if (path == null) throw const QuestException('录音未保存，请重试。');
      if ((await widget.repository.load()).profile?.id != widget.accountId) {
        throw const QuestException('账号已变化，录音未加入其他账号。');
      }
      _pendingAudio = (path: path, duration: elapsed);
      if (mounted &&
          (WidgetsBinding.instance.lifecycleState == null ||
              WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed)) {
        await _reviewAudio();
      }
    } catch (error) {
      if (_recordPath != null) await _deleteRecording(_recordPath!);
      if (mounted) widget.onError('$error');
    } finally {
      if (mounted && _pendingAudio == null) {
        setState(() => _busy = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }

  Future<void> _reviewAudio() async {
    if (!mounted || _reviewing || _pendingAudio == null) return;
    _reviewing = true;
    final pending = _pendingAudio!;
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认这段语音'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('已暂存 ${(pending.duration / 1000).ceil()} 秒，确认后才加入记录。'),
            TextButton.icon(
              key: const Key('audio-review-play'),
              onPressed: () => Navigator.of(dialogContext).push(
                MaterialPageRoute<void>(
                  builder: (_) => MediaViewer(
                    repository: widget.repository,
                    media: MediaAttachment(
                      id: 'audio-preview',
                      kind: MediaKind.audio,
                      localPath: pending.path,
                      durationMs: pending.duration,
                    ),
                  ),
                ),
              ),
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('试听'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'discard'),
            child: const Text('放弃'),
          ),
          TextButton(
            key: const Key('audio-review-rerecord'),
            onPressed: () => Navigator.pop(dialogContext, 'rerecord'),
            child: const Text('重新录制'),
          ),
          TextButton(
            key: const Key('audio-review-add'),
            onPressed: () => Navigator.pop(dialogContext, 'add'),
            child: const Text('加入记录'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    try {
      if (choice == 'add') {
        final state = await widget.repository.load();
        if (state.profile?.id != widget.accountId ||
            (widget.contextId.startsWith('draft:') &&
                state.activeQuestId != widget.contextId.substring(6))) {
          throw const QuestException('账号或活动已变化，语音未加入其他记录。');
        }
        final media = await widget.repository.stageMedia(
          pending.path,
          MediaKind.audio,
          durationMs: pending.duration,
        );
        if (mounted) {
          _append([media]);
        } else {
          await _discardDetachedMedia([media]);
        }
      }
      _pendingAudio = null;
      await _deleteRecording(pending.path);
    } catch (error) {
      if (mounted) widget.onError('$error');
    } finally {
      _reviewing = false;
      if (mounted) {
        setState(() => _busy = false);
        widget.onBusyChanged?.call(_pendingAudio != null);
      }
    }
    if (mounted && choice == 'rerecord') await _startRecording();
  }

  @override
  Widget build(BuildContext context) {
    final enabled =
        widget.enabled && !_busy && !_recording && _pendingAudio == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.attachments.isNotEmpty)
          AttachmentList(
            attachments: widget.attachments,
            repository: widget.repository,
            onMove: enabled ? _move : null,
            onRemove: enabled
                ? (media) => widget.onChanged(
                    widget.attachments.where((m) => m.id != media.id).toList(),
                  )
                : null,
          ),
        Wrap(
          spacing: 4,
          runSpacing: 0,
          children: [
            TextButton.icon(
              key: const Key('media-add-image'),
              onPressed:
                  enabled &&
                      widget.attachments
                              .where((m) => m.kind == MediaKind.image)
                              .length <
                          5
                  ? () => _pick(MediaKind.image)
                  : null,
              icon: const Icon(Icons.image_outlined, size: 20),
              label: const Text('图片'),
            ),
            TextButton.icon(
              key: const Key('media-add-video'),
              onPressed: enabled ? () => _pick(MediaKind.video) : null,
              icon: const Icon(Icons.videocam_outlined, size: 20),
              label: Text(
                widget.attachments.any((m) => m.kind == MediaKind.video)
                    ? '替换视频'
                    : '视频',
              ),
            ),
            TextButton.icon(
              key: const Key('media-add-audio'),
              onPressed: _recording
                  ? _stopRecording
                  : enabled &&
                        _pendingAudio == null &&
                        !widget.attachments.any(
                          (m) => m.kind == MediaKind.audio,
                        )
                  ? _startRecording
                  : null,
              icon: Icon(
                _recording ? Icons.stop_circle_outlined : Icons.mic_none,
                size: 20,
              ),
              label: Text(
                _recording ? '结束 ${(_watch?.elapsed.inSeconds ?? 0)}秒' : '语音',
              ),
            ),
          ],
        ),
        if (_pendingAudio != null && !_reviewing)
          TextButton(
            key: const Key('audio-resume-review'),
            onPressed: _reviewAudio,
            child: const Text('确认暂存语音'),
          ),
        Text(
          _busy ? '正在准备媒体…' : '最多 5 张图片 · 视频 15 秒 · 语音 60 秒，可同时添加',
          style: const TextStyle(fontSize: 11, color: Color(0xFF6D766B)),
        ),
        if (_hasRecovery)
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                key: const Key('media-retry-recovery'),
                onPressed: enabled ? _recover : null,
                child: const Text('重试恢复图库选择'),
              ),
              TextButton(
                key: const Key('media-discard-recovery'),
                onPressed: enabled ? _discardRecovery : null,
                child: const Text('放弃尚未恢复的图库选择'),
              ),
            ],
          ),
      ],
    );
  }
}

class MediaViewer extends StatefulWidget {
  const MediaViewer({super.key, required this.media, required this.repository});
  final MediaAttachment media;
  final QuestRepository repository;
  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> with WidgetsBindingObserver {
  static _MediaViewerState? _playing;
  VideoPlayerController? _video;
  AudioPlayer? _audio;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_playing == this) _playing = null;
    _video?.removeListener(_changed);
    unawaited(_video?.dispose());
    unawaited(_audio?.dispose());
    super.dispose();
  }

  Future<void> _pause() async {
    try {
      await _video?.pause();
      await _audio?.pause();
    } catch (_) {
      // The player can already be closing during a lifecycle transition.
    }
  }

  Future<void> _activate() async {
    final other = _playing;
    _playing = this;
    if (other != null && other != this) await other._pause();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_pause());
  }

  Future<void> _toggleVideo() async {
    final video = _video;
    if (video == null) return;
    try {
      if (video.value.isPlaying) {
        await video.pause();
      } else {
        await _activate();
        if (mounted && _playing == this) await video.play();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '视频播放失败，请重新打开。');
    }
  }

  Future<void> _toggleAudio() async {
    final audio = _audio;
    if (audio == null) return;
    try {
      if (audio.playing) {
        await audio.pause();
      } else {
        await _activate();
        if (!mounted || _playing != this) return;
        if (audio.processingState == ProcessingState.completed) {
          await audio.seek(Duration.zero);
        }
        if (mounted && _playing == this) await audio.play();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '语音播放失败，请重新打开。');
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (widget.media.kind == MediaKind.image) return;
    try {
      final path = widget.media.localPath;
      final local = path != null && path.isNotEmpty;
      final headers = local
          ? <String, String>{}
          : await widget.repository.mediaHeaders();
      if (!mounted) return;
      final url = local ? path : widget.repository.mediaUrl(widget.media);
      if (widget.media.kind == MediaKind.video) {
        _video = local
            ? localVideoController(url)
            : VideoPlayerController.networkUrl(
                Uri.parse(url),
                httpHeaders: headers,
              );
        _video!.addListener(_changed);
        await _video!.initialize();
      } else {
        _audio = AudioPlayer();
        if (local) {
          await _audio!.setFilePath(url);
        } else {
          await _audio!.setUrl(url, headers: headers);
        }
      }
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) setState(() => _error = '媒体暂时无法播放，请检查连接后重新打开。');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(mediaLabel(widget.media.kind))),
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: widget.media.kind == MediaKind.image
              ? InteractiveViewer(
                  child: PrivateMediaImage(
                    media: widget.media,
                    repository: widget.repository,
                    thumbnail: false,
                    fit: BoxFit.contain,
                  ),
                )
              : _error != null
              ? Text(_error!)
              : !_ready
              ? const CircularProgressIndicator()
              : _video != null
              ? Column(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: _video!.value.aspectRatio,
                          child: VideoPlayer(_video!),
                        ),
                      ),
                    ),
                    VideoProgressIndicator(_video!, allowScrubbing: true),
                    IconButton(
                      key: const Key('media-video-toggle'),
                      onPressed: _toggleVideo,
                      icon: Icon(
                        _video!.value.isPlaying
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                      tooltip: '播放 / 暂停',
                    ),
                  ],
                )
              : StreamBuilder<PlayerState>(
                  stream: _audio!.playerStateStream,
                  builder: (context, snapshot) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.graphic_eq, size: 56),
                      const SizedBox(height: 12),
                      Text(
                        '语音 · ${((widget.media.durationMs ?? 0) / 1000).ceil()}秒',
                      ),
                      IconButton(
                        key: const Key('media-audio-toggle'),
                        tooltip: '播放 / 暂停',
                        onPressed: _toggleAudio,
                        icon: Icon(
                          snapshot.data?.playing == true
                              ? Icons.pause
                              : Icons.play_arrow,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    ),
  );
}
