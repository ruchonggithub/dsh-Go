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
}
