import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'domain.dart';

typedef ImageNormalizer = Future<NormalizedImage> Function(String sourcePath);

class NormalizedImage {
  const NormalizedImage(this.path, {this.temporaryDirectory});
  final String path;
  final Directory? temporaryDirectory;

  /// The normalizer owns only this newly-created file and empty temp directory.
  /// Gallery sources and previously staged attachments are never deleted here.
  Future<void> dispose() async {
    final directory = temporaryDirectory;
    if (directory == null) return;
    if (p.dirname(p.absolute(path)) != p.absolute(directory.path) ||
        p.basename(path) != 'normalized.jpg') {
      throw StateError('Refusing to clean an unrelated media path.');
    }
    final file = File(path);
    if (await file.exists()) await file.delete();
    if (await directory.exists()) await directory.delete();
  }
}

/// Native decode/re-encode applies EXIF orientation and strips metadata before
/// upload. The server independently validates and normalizes the bytes again.
Future<NormalizedImage> normalizeImageForUpload(String sourcePath) async {
  final source = File(sourcePath);
  if (!await source.exists()) throw const QuestException('选择的图片已经不存在。');
  final length = await source.length();
  if (length <= 0 || length > 10 * 1024 * 1024) {
    throw const QuestException('请选择不超过 10 MiB 的有效图片。');
  }
  final bytes = await FlutterImageCompress.compressWithFile(
    sourcePath,
    minWidth: 1280,
    minHeight: 1280,
    quality: 90,
    autoCorrectionAngle: true,
    keepExif: false,
    format: CompressFormat.jpeg,
  );
  if (bytes == null ||
      bytes.length < 4 ||
      bytes.length > 10 * 1024 * 1024 ||
      bytes[0] != 0xff ||
      bytes[1] != 0xd8) {
    throw const QuestException('无法处理这张图片，请重新选择。');
  }
  final root = await getTemporaryDirectory();
  final directory = await root.createTemp('sidequest-normalize-');
  final result = NormalizedImage(
    p.join(directory.path, 'normalized.jpg'),
    temporaryDirectory: directory,
  );
  try {
    await File(result.path).writeAsBytes(bytes, flush: true);
    return result;
  } catch (_) {
    await result.dispose();
    rethrow;
  }
}
