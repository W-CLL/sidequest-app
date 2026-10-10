import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidequest/domain.dart';
import 'package:sidequest/media_normalizer.dart';

class _PolicyCompressor extends UnsupportedFlutterImageCompress {
  bool called = false;
  Uint8List? output = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);

  @override
  Future<Uint8List?> compressWithFile(
    String path, {
    int minWidth = 1920,
    int minHeight = 1080,
    int inSampleSize = 1,
    int quality = 95,
    int rotate = 0,
    bool autoCorrectionAngle = true,
    CompressFormat format = CompressFormat.jpeg,
    bool keepExif = false,
    int numberOfRetries = 5,
  }) async {
    called = true;
    expect(autoCorrectionAngle, isTrue);
    expect(keepExif, isFalse);
    expect(format, CompressFormat.jpeg);
    expect(quality, 90);
    expect(minWidth, 1280);
    expect(minHeight, 1280);
    return output;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File source;
  late _PolicyCompressor compressor;
  late FlutterImageCompressPlatform previous;
  const paths = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'sidequest-normalizer-test-',
    );
    source = File('${directory.path}/gallery-source.jpg');
    await source.writeAsBytes([1, 2, 3, 4], flush: true);
    previous = FlutterImageCompressPlatform.instance;
    compressor = _PolicyCompressor();
    FlutterImageCompressPlatform.instance = compressor;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => directory.path);
  });

  tearDown(() async {
    FlutterImageCompressPlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    await directory.delete(recursive: true);
  });

  test(
    'normalization applies orientation/metadata policy without changing source',
    () async {
      final normalized = await normalizeImageForUpload(source.path);
      expect(compressor.called, isTrue);
      expect(normalized.path, isNot(source.path));
      expect(await File(normalized.path).readAsBytes(), compressor.output);
      expect(await source.readAsBytes(), [1, 2, 3, 4]);
      await normalized.dispose();
      expect(await File(normalized.path).exists(), isFalse);
      expect(await source.exists(), isTrue);
    },
  );

  test('failed decoding does not delete gallery files', () async {
    compressor.output = null;
    await expectLater(
      normalizeImageForUpload(source.path),
      throwsA(isA<QuestException>()),
    );
    expect(await source.readAsBytes(), [1, 2, 3, 4]);
    expect(await directory.list().length, 1);
  });

  test('oversized source is rejected before native decode', () async {
    final handle = await source.open(mode: FileMode.write);
    await handle.truncate(10 * 1024 * 1024 + 1);
    await handle.close();
    await expectLater(
      normalizeImageForUpload(source.path),
      throwsA(isA<QuestException>()),
    );
    expect(compressor.called, isFalse);
    expect(await source.exists(), isTrue);
  });

  test('temporary cleanup cannot remove unrelated or original files', () async {
    await const NormalizedImage('unowned-path').dispose();
    await expectLater(
      NormalizedImage(source.path, temporaryDirectory: directory).dispose(),
      throwsStateError,
    );
    expect(await source.exists(), isTrue);
  });
}
