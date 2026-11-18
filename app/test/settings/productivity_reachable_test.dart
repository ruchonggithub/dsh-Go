import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';

import '../shell/golden_harness.dart';

/// 生产力模式 has to be findable on the settings hub's 外观 group.
///
/// The hub is long and Flutter builds only what is on screen, so the row has to
/// be scrolled to before it exists in the tree — which is also why a person can
/// miss it. This walks down the page the way a person does and then asserts the
/// row is there, with the label and the switch.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<Finder> scrollToProductivity(WidgetTester tester) async {
    final row = find.byKey(const ValueKey('settings-productivity'));
    for (var i = 0; i < 20; i++) {
      if (row.evaluate().isNotEmpty) return row;
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -260));
      await tester.pump(const Duration(milliseconds: 90));
    }
    return row;
  }

  testWidgets('设置主页的「外观」分组有生产力模式开关', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(goldenApp(home: const SettingsScreen(), brightness: Brightness.light));
    await tester.pump(const Duration(milliseconds: 300));

    final row = await scrollToProductivity(tester);
    expect(row, findsOneWidget, reason: '滚到外观分组应当看到生产力模式');
    expect(find.text(appL10n.settingsProductivity), findsWidgets);
    expect(find.descendant(of: row, matching: find.byType(Switch)), findsOneWidget);
  });

  testWidgets('默认开着，点一下会关掉', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(goldenApp(home: const SettingsScreen(), brightness: Brightness.light));
    await tester.pump(const Duration(milliseconds: 300));

    final row = await scrollToProductivity(tester);
    expect(row, findsOneWidget);

    bool value() => tester.widget<Switch>(find.descendant(of: row, matching: find.byType(Switch))).value;
    final pets = find.text(appL10n.botsPets);
    expect(value(), isTrue, reason: '默认生产力模式开（隐藏娱乐）');
    expect(pets, findsNothing);

    await tester.tap(row);
    await tester.pump(const Duration(milliseconds: 250));
    expect(value(), isFalse, reason: '点一下应当切到关');
    expect(pets, findsOneWidget);
  });

  testWidgets('设置搜索把生产力模式定位到外观分组的开关', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(goldenApp(home: const SettingsScreen(), brightness: Brightness.light));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-search')));
    await tester.pumpAndSettle();
    final input = find.descendant(
      of: find.byKey(const ValueKey('settings-search-field')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(input, appL10n.settingsProductivity);
    await tester.pumpAndSettle();
    final result = find.widgetWithText(ListPageRow, appL10n.settingsProductivity);
    await tester.tap(result);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-productivity')).hitTestable(), findsOneWidget);
  });
}
