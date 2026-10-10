import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'domain.dart';
import 'media_video_source.dart';
import 'repository.dart';

/// Gallery recovery is claimed only by the account and editor that opened it.
/// This key stores no token, record text, or media contents.
class MediaCapture {
  MediaCapture({ImagePicker? picker}) : _picker = picker ?? ImagePicker();
  final ImagePicker _picker;
  static const _contextKey = 'sidequest.picker.context.v2';

  Future<List<MediaAttachment>> pick({
    required QuestRepository repository,
    required String accountId,
    required String contextId,
    required MediaKind kind,
    required int remainingImages,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final contextMarker = <String, Object>{
      'scope': repository.cacheScope,
      'accountId': accountId,
      'contextId': contextId,
      'kind': kind.name,
    };
    final marker = jsonEncode(contextMarker);
    final previous = prefs.getString(_contextKey);
    if (previous != null && previous != marker) {
      throw const QuestException('有尚未恢复的图库选择。请返回原记录，或先放弃该选择后继续。');
    }
    if (!await prefs.setString(_contextKey, marker)) {
      throw const QuestException('无法保存图库恢复信息，请稍后重试。');
    }
    final files = kind == MediaKind.image
        ? await _picker.pickMultiImage(
            limit: remainingImages,
            requestFullMetadata: false,
          )
        : [
            ?await _picker.pickVideo(
              source: ImageSource.gallery,
              maxDuration: const Duration(seconds: 15),
            ),
          ];
    final claimedMarker = jsonEncode({
      ...contextMarker,
      'files': files.map((file) => file.path).toList(),
    });
    if (!await prefs.setString(_contextKey, claimedMarker)) {
      throw const QuestException('无法保留图库选择，请勿退出此页面并重试。');
    }
    if (files.isEmpty) {
      if (prefs.getString(_contextKey) == claimedMarker) {
        await prefs.remove(_contextKey);
      }
      return [];
    }
    if (kind == MediaKind.image && files.length > remainingImages) {
      throw QuestException('这次最多还能添加 $remainingImages 张图片，请重新选择。');
    }
    final result = await _stage(files, repository, accountId, contextId, kind);
    if (prefs.getString(_contextKey) == claimedMarker) {
      await prefs.remove(_contextKey);
    }
    return result;
  }

  Future<List<MediaAttachment>> recover({
    required QuestRepository repository,
    required String accountId,
    required String contextId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_contextKey);
    if (raw == null) return [];
    final marker = jsonDecode(raw) as Map<String, dynamic>;
    if (marker['scope'] != repository.cacheScope ||
        marker['accountId'] != accountId ||
        marker['contextId'] != contextId) {
      return [];
    }
    var markerValue = raw;
    List<XFile> files;
    if (marker['files'] case final List paths) {
      files = paths.cast<String>().map(XFile.new).toList();
    } else {
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return [];
      final response = await _picker.retrieveLostData();
      if (response.isEmpty) {
        await prefs.remove(_contextKey);
        return [];
      }
      if (response.exception case final error?) throw error;
      files = response.files ?? [if (response.file != null) response.file!];
      marker['files'] = files.map((file) => file.path).toList();
      markerValue = jsonEncode(marker);
      if (!await prefs.setString(_contextKey, markerValue)) {
        throw const QuestException('无法保留恢复信息，请勿退出此页面并重试。');
      }
    }
    final kind = marker['kind'] == 'video' ? MediaKind.video : MediaKind.image;
    final result = await _stage(files, repository, accountId, contextId, kind);
    if (prefs.getString(_contextKey) == markerValue) {
      await prefs.remove(_contextKey);
    }
    return result;
  }

  Future<bool> hasRecovery() async =>
      (await SharedPreferences.getInstance()).containsKey(_contextKey);

  /// Explicitly discards only the OS picker's unclaimed result. Original bound
  /// attachments, completed records, and private staged files are not deleted.
  Future<void> discardRecovery() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await _picker.retrieveLostData();
    }
    await (await SharedPreferences.getInstance()).remove(_contextKey);
  }

  Future<List<MediaAttachment>> _stage(
    List<XFile> files,
    QuestRepository repository,
    String accountId,
    String contextId,
    MediaKind kind,
  ) async {
    final current = await repository.load();
    if (current.profile?.id != accountId ||
        (contextId.startsWith('draft:') &&
            current.activeQuestId != contextId.substring(6))) {
      throw const QuestException('账号或当前活动已变化，未把选择结果加入记录。');
    }
    final result = <MediaAttachment>[];
    try {
      for (final file in files) {
        if ((await repository.load()).profile?.id != accountId) {
          throw const QuestException('账号已变化，未把选择结果加入记录。');
        }
        int? duration;
        if (kind == MediaKind.video) {
          final controller = localVideoController(file.path);
          try {
            await controller.initialize();
            duration = controller.value.duration.inMilliseconds;
            if (duration <= 0 || duration > 15000) {
              throw const QuestException('请选择不超过 15 秒的视频。');
            }
          } finally {
            await controller.dispose();
          }
        }
        result.add(
          await repository.stageMedia(file.path, kind, durationMs: duration),
        );
      }
    } catch (_) {
      if (result.isNotEmpty) {
        try {
          await repository.discardStagedMedia(result.map((m) => m.id).toList());
        } catch (_) {
          // Preserve the original staging failure. Repository cleanup is safe
          // to retry and must never erase a referenced or other-account file.
        }
      }
      rethrow;
    }
    return result;
  }
}
