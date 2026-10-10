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
import 'package:sidequest/pages.dart';
import 'package:sidequest/repository.dart';

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
    Future<LocalQuestRepository> mount({
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
      final repo = LocalQuestRepository(
        preferences: await SharedPreferences.getInstance(),
        passwordIterations: 100,
      );
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
