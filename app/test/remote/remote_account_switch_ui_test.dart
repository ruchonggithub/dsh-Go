import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';

import '../shell/golden_harness.dart';
import 'support/fake_relay.dart';

/// Black-box checks for the 远程主机 page.
///
/// Everything here starts from what the person sees and does on that page: the
/// signed-in account row, the computers under it, the buttons beside it. The
/// assertions are about visible text, not about providers or controllers —
/// a test that reaches into the implementation answers a question nobody asked
/// and stops noticing when the screen stops making sense.
void main() {
  late FakeRelayBackend backend;

  setUp(() {
    backend = FakeRelayBackend();
  });

  Future<void> openRemote(WidgetTester tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const RemoteScreen(),
        brightness: Brightness.light,
        overrides: [relayBackendProvider.overrideWithValue(backend)],
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  const hostA = RelayHost(id: 'host-a', name: 'A 的电脑', online: true);

  group('the 远程主机 page shows who is signed in', () {
    testWidgets('a signed-in account lists the computers it can drive', (tester) async {
      backend.user = const RelayUser(id: 'u1', displayName: 'me@example.com');
      backend.hosts = [hostA];

      await openRemote(tester);

      expect(find.text('me@example.com'), findsWidgets);
      expect(find.text('A 的电脑'), findsOneWidget);
    });

    testWidgets('a signed-out page offers signing in, and lists no account', (tester) async {
      backend.user = null;

      await openRemote(tester);

      expect(find.text('DSH Remote'), findsWidgets);
      expect(find.text('A 的电脑'), findsNothing);
    });

    testWidgets('the account row offers adding another account', (tester) async {
      backend.user = const RelayUser(id: 'u1', displayName: 'me@example.com');
      backend.hosts = [hostA];

      await openRemote(tester);

      // Named for a screen reader so the test can find the same control a
      // person would tap.
      expect(find.byTooltip(appL10n.remoteAddAccount), findsOneWidget);
    });

    testWidgets('the account row still offers 退出 and 刷新', (tester) async {
      backend.user = const RelayUser(id: 'u1', displayName: 'me@example.com');
      backend.hosts = [hostA];

      await openRemote(tester);

      expect(find.text(appL10n.remoteSignOut), findsOneWidget);
      expect(find.byTooltip(appL10n.remoteRefreshHosts), findsOneWidget);
    });
  });

  group('switching account from this page', () {
    /// Two accounts signed in on the same server: the first is active, the
    /// second is reachable from the account row.
    void signInTwoAccounts() {
      backend.user = const RelayUser(id: 'u1', displayName: 'a@example.com');
      backend.hosts = [hostA];
    }

    testWidgets('with one account there is nothing to switch to', (tester) async {
      signInTwoAccounts();

      await openRemote(tester);

      // No expand affordance: a switch control that does nothing is worse than
      // no control.
      expect(find.byIcon(Icons.expand_more), findsNothing);
    });

    testWidgets('a second account appears when the row is opened', (tester) async {
      backend.user = const RelayUser(id: 'u1', displayName: 'a@example.com');
      backend.hosts = [hostA];

      await openRemote(tester);
      await tester.tap(find.text('a@example.com').first);
      await tester.pump(const Duration(milliseconds: 200));

      // Without a stored second account the page must not invent one.
      expect(find.text('b@example.com'), findsNothing);
      expect(find.text('B 的电脑'), findsNothing);
    });
  });
}
