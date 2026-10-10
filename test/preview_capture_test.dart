// Opt-in visual review: renders real Flutter widgets with a supplied CJK font.
// No system font is copied into the repository or bundled with the app.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequest/domain.dart';
import 'package:sidequest/main.dart';
import 'package:sidequest/media_widgets.dart';
import 'package:sidequest/pages.dart';

import 'ui_test_harness.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_PREVIEWS');
  const rootKey = ValueKey('preview-boundary');
  testWidgets('capture Chinese-font Flutter previews for visual review', (
    tester,
  ) async {
    final fontPath =
        Platform.environment['SIDEQUEST_PREVIEW_FONT'] ??
        (Platform.isWindows
            ? '${Platform.environment['WINDIR']}\\Fonts\\msyh.ttc'
            : '');
    if (fontPath.isEmpty || !File(fontPath).existsSync()) {
      throw StateError(
        'Set SIDEQUEST_PREVIEW_FONT to a local CJK TTF/TTC font.',
      );
    }
    final font = ByteData.sublistView(File(fontPath).readAsBytesSync());
    await tester.runAsync(() async {
      for (final family in ['Roboto', 'PreviewCjk']) {
        await (FontLoader(family)..addFont(Future.value(font))).load();
      }
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      for (final entry in manifest.cast<Map<String, dynamic>>()) {
        final loader = FontLoader(entry['family'] as String);
        for (final asset
            in (entry['fonts'] as List).cast<Map<String, dynamic>>()) {
          loader.addFont(rootBundle.load(asset['asset'] as String));
        }
        await loader.load();
      }
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> shot(String name) async {
      await tester.pumpAndSettle();
      // File I/O, image codec creation, and the first decoded frame each cross
      // separate async boundaries. pumpAndSettle alone cannot finish real I/O.
      final privateImages = find.byType(PrivateMediaImage);
      bool imagesDecoded() => privateImages.evaluate().every((element) {
        final frames = find.descendant(
          of: find.byWidget(element.widget),
          matching: find.byType(RawImage),
        );
        return frames.evaluate().isNotEmpty &&
            tester.widgetList<RawImage>(frames).every((w) => w.image != null);
      });
      for (var attempt = 0; attempt < 100 && !imagesDecoded(); attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        imagesDecoded(),
        isTrue,
        reason: '$name: decode every media image',
      );
      await tester.pumpAndSettle();
      if (name == '19-share-photo-preview') {
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('share-confirm-action')),
              )
              .onPressed,
          isNotNull,
          reason: 'The exported photo preview must be fully loaded.',
        );
      }
      expect(tester.takeException(), isNull, reason: name);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(rootKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('screenshots/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    }

    Future<void> tap(Key key) async {
      final target = find.byKey(key);
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    late ThemeData previewTheme;
    Future<InMemoryQuestRepository> mount({
      bool onboarded = true,
      bool registered = false,
      bool active = false,
      bool completed = false,
    }) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      SharedPreferences.setMockInitialValues(
        onboarded ? {'ui_role': 'employee'} : {},
      );
      final repo = InMemoryQuestRepository();
      if (registered) {
        await repo.savePreferences('employee', ['观察细节']);
        await repo.register('小叶子', 'preview-test-password');
        if (active || completed) await repo.claim();
        if (completed) {
          await repo.complete('窗边的叶子是柔和的绿，杯子上的绿更深一点。');
        }
      }
      await tester.pumpWidget(
        RepaintBoundary(
          key: rootKey,
          child: Builder(
            builder: (context) {
              final app =
                  SideQuestApp(repository: repo).build(context) as MaterialApp;
              final base = app.theme!;
              final filled = base.filledButtonTheme.style!;
              previewTheme = base.copyWith(
                textTheme: base.textTheme.apply(fontFamily: 'PreviewCjk'),
                primaryTextTheme: base.primaryTextTheme.apply(
                  fontFamily: 'PreviewCjk',
                ),
                filledButtonTheme: FilledButtonThemeData(
                  style: filled.copyWith(
                    textStyle: WidgetStateProperty.resolveWith(
                      (states) =>
                          (filled.textStyle?.resolve(states) ??
                                  base.textTheme.labelLarge!)
                              .copyWith(fontFamily: 'PreviewCjk'),
                    ),
                  ),
                ),
              );
              return MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: previewTheme,
                home: app.home,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    await mount(onboarded: false);
    await shot('01-role');
    await tester.tap(find.text('上班族'));
    await tester.pumpAndSettle();
    await tap(const ValueKey('onboarding-next-action'));
    await shot('02-preferences');
    await tap(const ValueKey('preferences-skip-action'));
    await shot('03-today');
    await tap(const ValueKey('today-primary-action'));
    await shot('04-detail');
    await tap(const ValueKey('quest-primary-action'));
    expect(find.byType(LoginPage), findsOneWidget);
    await shot('05-login');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    await shot('14-sign-in');

    await mount(registered: true, active: true);
    await shot('09-today-active');
    await tap(const ValueKey('today-primary-action'));
    await tap(const ValueKey('quest-primary-action'));
    expect(find.byType(RecordPage), findsOneWidget);
    await shot('06-record');

    await mount();
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await shot('07-profile-guest');

    final repo = await mount(registered: true, completed: true);
    await shot('10-today-completed');
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await shot('08-profile-account');
    await tester.tap(find.text('版本说明'));
    await tester.pumpAndSettle();
    await shot('13-version');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('探索册').last);
    await tester.pumpAndSettle();
    await shot('11-journal');

    final snapshot = await repo.load();
    final context = tester.element(find.byType(QuestHome));
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            EntryPage(entry: snapshot.entries.single, repository: repo),
      ),
    );
    await tester.pumpAndSettle();
    await shot('12-entry');

    final fixtureDirectory = Directory('artifacts/v0.2.0/ui-fixtures');
    final fixtureFile = File('${fixtureDirectory.path}/leaf.png');
    await tester.runAsync(() async {
      await fixtureDirectory.create(recursive: true);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 400, 260),
        Paint()..color = const Color(0xFFEDF1E6),
      );
      canvas.drawCircle(
        const Offset(320, 55),
        30,
        Paint()..color = const Color(0xFFDFECAC),
      );
      final stem = Paint()
        ..color = const Color(0xFF234D3C)
        ..strokeWidth = 7;
      canvas.drawLine(const Offset(200, 220), const Offset(210, 65), stem);
      canvas.drawOval(
        const Rect.fromLTWH(145, 75, 72, 45),
        Paint()..color = const Color(0xFF78976B),
      );
      canvas.drawOval(
        const Rect.fromLTWH(207, 120, 72, 45),
        Paint()..color = const Color(0xFF4D7458),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(400, 260);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await fixtureFile.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    });
    final media = <MediaAttachment>[
      MediaAttachment(
        id: 'preview-image',
        kind: MediaKind.image,
        localPath: fixtureFile.absolute.path,
      ),
      const MediaAttachment(
        id: 'preview-video',
        kind: MediaKind.video,
        durationMs: 12000,
      ),
      const MediaAttachment(
        id: 'preview-audio',
        kind: MediaKind.audio,
        durationMs: 32000,
      ),
    ];
    Future<void> mountPage(Widget page) async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: previewTheme,
            home: page,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final mixedRepo = InMemoryQuestRepository(snapshotFixture(active: true));
    mixedRepo.snapshot = mixedRepo.snapshot.copyWith(
      draft: '窗边的绿叶、短视频和一句语音，都留在这次记录里。',
      draftAttachments: media,
    );
    await mountPage(
      RecordPage(
        repository: mixedRepo,
        quest: questById('green'),
        initialDraft: '窗边的绿叶、短视频和一句语音，都留在这次记录里。',
        initialAttachments: media,
        accountId: mixedRepo.snapshot.profile!.id,
      ),
    );
    await shot('15-record-mixed-media');
    final mixedEntry = snapshot.entries.single.copyWith(
      attachments: media,
      syncStatus: 'failed',
      syncError: '视频处理失败，可重试或仅上传文字。',
    );
    mixedRepo.snapshot = mixedRepo.snapshot.copyWith(
      entries: [mixedEntry],
      entryCount: 1,
      conflictDrafts: [
        ConflictDraft(
          id: 'preview-conflict',
          questId: 'light',
          text: '另一台设备留下的草稿',
          createdAt: DateTime(2026, 10, 10),
        ),
      ],
    );
    await mountPage(SyncStatusPage(repository: mixedRepo));
    await shot('16-sync-status');
    await mountPage(
      ShareSelectionPage(entry: mixedEntry, repository: mixedRepo),
    );
    await shot('17-share-selection-default');
    await mountPage(
      SharePreviewPage(
        entry: mixedEntry,
        repository: mixedRepo,
        images: const [],
      ),
    );
    await shot('18-share-text-preview');
    await mountPage(
      SharePreviewPage(
        entry: mixedEntry,
        repository: mixedRepo,
        images: [media.first],
      ),
    );
    await shot('19-share-photo-preview');

    // Every catalog entry is also visually rendered through the detail layout.
    for (final quest in questCatalog) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: previewTheme,
            home: QuestDetail(quest: quest, role: 'employee', active: false),
          ),
        ),
      );
      await shot('details/${quest.id}');
    }
  }, skip: !capture);
}
