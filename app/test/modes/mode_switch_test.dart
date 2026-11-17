import 'package:dsh_app/state/app_mode_state.dart';
import 'package:dsh_app/state/entertainment_state.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/modes/mode_switch.dart';
import 'package:dsh_app/ui/tavern/tavern_home_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// Entertainment is off by default, so anything that moves between 模式 has to
/// ask for it. The cases below that were written before the switch assume it is
/// on. [entertainmentProvider] itself is overridden (not just the boolean it
/// derives), because [ModeLaunch] waits for the stored answer to load.
Widget _app(Widget home, {bool entertainment = true}) => ProviderScope(
  overrides: [
    tavernProvider.overrideWith((ref) => PreviewTavern(tick: const Duration(milliseconds: 1))),
    entertainmentProvider.overrideWith(() => _FixedEntertainment(entertainment)),
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: withTestFonts(buildLightTheme()),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: home,
  ),
);

/// The switch already read back: no prefs round trip.
class _FixedEntertainment extends EntertainmentController {
  _FixedEntertainment(this.enabled);

  final bool enabled;

  @override
  EntertainmentSettings build() => EntertainmentSettings(enabled: enabled, loaded: true);
}

void main() {
  testWidgets('a launch opens straight into the startup mode, and back lands in 工作', (tester) async {
    SharedPreferences.setMockInitialValues({AppModeController.key: 'tavern'});
    await tester.pumpWidget(_app(const ModeLaunch(child: Text('工作首页'))));
    await tester.pumpAndSettle();

    expect(find.byType(TavernHomePage), findsOneWidget);
    expect(find.text('林晚'), findsOneWidget);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(TavernHomePage), findsNothing);
    expect(find.text('工作首页'), findsOneWidget);
  });

  testWidgets('工作 as the startup mode shows the home and opens nothing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_app(const ModeLaunch(child: Text('工作首页'))));
    await tester.pumpAndSettle();

    expect(find.text('工作首页'), findsOneWidget);
    expect(find.byType(TavernHomePage), findsNothing);
  });

  testWidgets('the 模式 sheet opens a mode and keeps the startup choice', (tester) async {
    SharedPreferences.setMockInitialValues({});
    AppMode? opened;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: ModeSheet(current: AppMode.work, onOpen: (mode) => opened = mode),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('工作'), findsWidgets);
    expect(find.text('伙伴小屋'), findsOneWidget);
    expect(find.text('酒馆'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('mode-row-tavern')));
    expect(opened, AppMode.tavern);

    // 启动时进入 › 酒馆.
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('mode-startup')), matching: find.text('酒馆')));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppModeController.key), 'tavern');
  });

  testWidgets('entertainment off: the 模式 sheet offers 工作 alone', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: ModeSheet(current: AppMode.work, onOpen: (mode) {}),
        ),
        entertainment: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mode-row-work')), findsOneWidget);
    expect(find.byKey(const ValueKey('mode-row-companion')), findsNothing);
    expect(find.byKey(const ValueKey('mode-row-tavern')), findsNothing);
    // A one-segment control would trip SegmentedPill's assert: the group is gone.
    expect(find.byKey(const ValueKey('mode-startup')), findsNothing);
  });

  testWidgets('entertainment off: the drawer key draws nothing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _app(const Scaffold(body: Center(child: ModeKey())), entertainment: false),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mode-key')), findsNothing);
  });

  testWidgets('entertainment off: a stored startup mode does not open on launch', (tester) async {
    SharedPreferences.setMockInitialValues({AppModeController.key: 'tavern'});
    await tester.pumpWidget(_app(const ModeLaunch(child: Text('工作首页')), entertainment: false));
    await tester.pumpAndSettle();

    expect(find.text('工作首页'), findsOneWidget);
    expect(find.byType(TavernHomePage), findsNothing);
  });
}
