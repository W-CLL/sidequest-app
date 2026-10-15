import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidequest/widgets.dart';

void main() {
  testWidgets('宽屏时收成一列手机宽度的竖屏，窄屏保持原样', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: PortraitStage(
          child: SizedBox.expand(key: Key('stage-child')),
        ),
      ),
    );
    final wide = tester.getSize(find.byKey(const Key('stage-child')));
    expect(wide.width, 430);
    expect(wide.height, 800);

    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      const MaterialApp(
        home: PortraitStage(
          child: SizedBox.expand(key: Key('stage-child')),
        ),
      ),
    );
    final narrow = tester.getSize(find.byKey(const Key('stage-child')));
    expect(narrow.width, 390);
    expect(narrow.height, 844);
  });

  testWidgets('竖屏列内读到的窗口宽度与列一致', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    late Size seen;
    await tester.pumpWidget(
      MaterialApp(
        home: PortraitStage(
          child: Builder(
            builder: (context) {
              seen = MediaQuery.sizeOf(context);
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    expect(seen.width, 430);
    expect(seen.height, 768);
  });
}
