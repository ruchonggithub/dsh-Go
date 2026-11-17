import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_app/state/entertainment_state.dart';

/// The entertainment switch, on its own.
///
/// These check the preference itself — default, persistence, and the read race —
/// not what any screen does with it. What a screen does is a black-box question
/// for that screen's own test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  /// A container whose stored preference has been read.
  Future<ProviderContainer> loaded() async {
    final c = container();
    await c.read(entertainmentProvider.notifier).ready;
    return c;
  }

  test('entertainment is off before anything is chosen', () async {
    final c = container();
    expect(c.read(entertainmentEnabledProvider), isFalse);

    await c.read(entertainmentProvider.notifier).ready;
    expect(c.read(entertainmentEnabledProvider), isFalse);
  });

  test('turning it on is remembered', () async {
    final first = container();
    await first.read(entertainmentProvider.notifier).setEnabled(true);
    expect(first.read(entertainmentEnabledProvider), isTrue);

    final second = await loaded();
    expect(second.read(entertainmentEnabledProvider), isTrue);
  });

  test('turning it back off is remembered too', () async {
    final first = container();
    await first.read(entertainmentProvider.notifier).setEnabled(true);
    await first.read(entertainmentProvider.notifier).setEnabled(false);

    final second = await loaded();
    expect(second.read(entertainmentEnabledProvider), isFalse);
  });

  test('a choice made while the store is still being read is not overwritten', () async {
    final c = container();
    // build() starts the read; choose in the same turn, before it can land.
    final notifier = c.read(entertainmentProvider.notifier);
    await notifier.setEnabled(true);
    await notifier.ready;
    expect(c.read(entertainmentEnabledProvider), isTrue);
  });

  test('the default is off, so a fresh install sees no entertainment', () {
    expect(EntertainmentSettings.defaultEnabled, isFalse);
  });

  test('生产力模式 is the inverse, and on by default', () async {
    // The same fresh install: nothing stored means 娱乐 off, 生产力 on.
    final c = container();
    expect(c.read(productivityModeProvider), isTrue);
    await c.read(entertainmentProvider.notifier).ready;
    expect(c.read(productivityModeProvider), isTrue);
  });

  test('setProductivity(true) turns entertainment off, and is remembered inverted', () async {
    final first = container();
    await first.read(entertainmentProvider.notifier).setProductivity(false);
    expect(first.read(entertainmentEnabledProvider), isTrue);
    expect(first.read(productivityModeProvider), isFalse);
    // Stored as 生产力模式: off.
    expect((await SharedPreferences.getInstance()).getBool(EntertainmentSettings.prefsKey), isFalse);

    final second = await loaded();
    expect(second.read(productivityModeProvider), isFalse);

    await second.read(entertainmentProvider.notifier).setProductivity(true);
    expect(second.read(entertainmentEnabledProvider), isFalse);
  });

  test('a stored 娱乐内容 choice is migrated to the new key, inverted', () async {
    // The old build stored the entertainment switch itself under the old key.
    SharedPreferences.setMockInitialValues({EntertainmentSettings.legacyPrefsKey: true});
    final c = await loaded();
    expect(c.read(entertainmentEnabledProvider), isTrue);
    expect(c.read(productivityModeProvider), isFalse);

    // Migrated once: the new key now holds 生产力模式 (the inverse).
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(EntertainmentSettings.prefsKey), isFalse);
    // The old key is left alone, so a downgrade still finds its own value.
    expect(prefs.getBool(EntertainmentSettings.legacyPrefsKey), isTrue);
  });

  test('the new key wins over the old one', () async {
    SharedPreferences.setMockInitialValues({
      EntertainmentSettings.legacyPrefsKey: true,
      EntertainmentSettings.prefsKey: true, // 生产力 on: entertainment off
    });
    final c = await loaded();
    expect(c.read(entertainmentEnabledProvider), isFalse);
  });
}
