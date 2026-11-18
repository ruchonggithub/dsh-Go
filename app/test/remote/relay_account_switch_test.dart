import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_app/state/hosts_state.dart';

/// Switching account has to reach the thing that decides which computers are
/// listed. These pin the chain selection → backend → account state, because a
/// broken link shows as "my other server's computers are missing" rather than
/// as an error.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  group('account selection reaches the backend', () {
    test('the backend is built for the selected server and account', () async {
      final c = container();
      const selection = RelayAccountSelection(origin: 'https://s.example.com', account: 'a@example.com');
      await c.read(relaySelectionProvider.notifier).set(selection);

      // relayServerProvider is the address half the rest of the app reads.
      expect(c.read(relayServerProvider), 'https://s.example.com');
      expect(c.read(relaySelectionProvider)?.account, 'a@example.com');

      // The backend is the component that turns that pair into credentials.
      final backend = c.read(relayBackendProvider);
      expect(backend, isNotNull);
    });

    test('switching account rebuilds the backend, it does not reuse the old one', () async {
      final c = container();
      await c.read(relaySelectionProvider.notifier).set(
        const RelayAccountSelection(origin: 'https://s.example.com', account: 'a@example.com'),
      );
      final first = c.read(relayBackendProvider);

      await c.read(relaySelectionProvider.notifier).set(
        const RelayAccountSelection(origin: 'https://s.example.com', account: 'b@example.com'),
      );
      final second = c.read(relayBackendProvider);

      // Same server, different account: the credential slot differs, so this
      // must be a different backend. Reusing it would keep showing account A's
      // computers while the UI says B.
      expect(identical(first, second), isFalse);
      expect(c.read(relayServerProvider), 'https://s.example.com');
      expect(c.read(relaySelectionProvider)?.account, 'b@example.com');
    });

    test('switching server changes the address the app reads', () async {
      final c = container();
      await c.read(relaySelectionProvider.notifier).set(
        const RelayAccountSelection(origin: 'https://a.example.com', account: 'me@example.com'),
      );
      expect(c.read(relayServerProvider), 'https://a.example.com');

      await c.read(relaySelectionProvider.notifier).set(
        const RelayAccountSelection(origin: 'https://b.example.com', account: 'me@example.com'),
      );
      expect(c.read(relayServerProvider), 'https://b.example.com');
    });

    test('a migrated row selects by server with no account yet', () async {
      final c = container();
      await c.read(relaySelectionProvider.notifier).set(
        const RelayAccountSelection(origin: 'https://legacy.example.com', account: null),
      );
      expect(c.read(relayServerProvider), 'https://legacy.example.com');
      expect(c.read(relaySelectionProvider)?.account, isNull);
    });

    test('clearing the selection leaves no server to talk to', () async {
      final c = container();
      await c.read(relaySelectionProvider.notifier).set(
        const RelayAccountSelection(origin: 'https://a.example.com', account: 'me@example.com'),
      );
      await c.read(relaySelectionProvider.notifier).set(null);
      expect(c.read(relayServerProvider), isNull);
    });
  });

  group('the switcher lists every account', () {
    test('two servers, two accounts, all reachable from one list', () async {
      final c = container();
      final notifier = c.read(relayAccountsProvider.notifier);
      await notifier.ready;

      await notifier.remember('https://a.example.com', 'me@a.example.com');
      await notifier.remember('https://b.example.com', 'me@b.example.com');

      final rows = c.read(relayAccountsProvider);
      expect(rows, hasLength(2));
      // The sheet shows this list; picking a row sets the selection that the
      // backend reads.
      await c.read(relaySelectionProvider.notifier).set(
        RelayAccountSelection(origin: rows.last.origin, account: rows.last.account),
      );
      expect(c.read(relayServerProvider), rows.last.origin);
    });

    test('same server twice: the rows differ by account', () async {
      final c = container();
      final notifier = c.read(relayAccountsProvider.notifier);
      await notifier.ready;
      await notifier.remember('https://s.example.com', 'a@example.com');
      await notifier.remember('https://s.example.com', 'b@example.com');

      final rows = c.read(relayAccountsProvider);
      expect(rows.map((e) => e.origin).toSet(), {'https://s.example.com'});
      expect(rows.map((e) => e.account).toSet(), {'a@example.com', 'b@example.com'});
      expect(rows.map((e) => e.id).toSet(), hasLength(2));
    });
  });
}
