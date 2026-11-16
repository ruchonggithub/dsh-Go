import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/relay_server_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('RelayAccountEntry', () {
    test('json round-trip keeps origin, account, label, provider and time', () {
      final when = DateTime.utc(2026, 11, 16, 3, 4, 5);
      final entry = RelayAccountEntry(
        origin: 'https://remote.example.com',
        account: 'me@example.com',
        label: '公司',
        provider: 'password',
        lastUsed: when,
      );
      final decoded = RelayAccountEntry.fromJson(jsonDecode(jsonEncode(entry.toJson())))!;
      expect(decoded.origin, entry.origin);
      expect(decoded.account, entry.account);
      expect(decoded.label, entry.label);
      expect(decoded.provider, entry.provider);
      expect(decoded.lastUsed, when);
    });

    test('identity is server + account, so one server holds several rows', () {
      const a = RelayAccountEntry(origin: 'https://s.example.com', account: 'a@example.com');
      const b = RelayAccountEntry(origin: 'https://s.example.com', account: 'b@example.com');
      const aUpper = RelayAccountEntry(origin: 'https://s.example.com', account: 'A@Example.com');
      expect(a.id, isNot(b.id));
      // Case and surrounding space are the same person, not a second account.
      expect(a.id, aUpper.id);
    });

    test('malformed input yields an empty list instead of throwing', () {
      expect(RelayAccountEntry.decodeList(null), isEmpty);
      expect(RelayAccountEntry.decodeList(''), isEmpty);
      expect(RelayAccountEntry.decodeList('{oops'), isEmpty);
      expect(RelayAccountEntry.decodeList('[1,2,3]'), isEmpty);
      expect(
        RelayAccountEntry.decodeList(
          jsonEncode([
            {'no': 'origin'},
          ]),
        ),
        isEmpty,
      );
    });

    test('duplicate rows collapse to the first occurrence', () {
      final list = RelayAccountEntry.decodeList(
        jsonEncode([
          {'origin': 'https://a.example.com', 'account': 'me@example.com', 'label': 'first'},
          {'origin': 'https://a.example.com', 'account': 'me@example.com', 'label': 'second'},
        ]),
      );
      expect(list, hasLength(1));
      expect(list.single.label, 'first');
    });

    test('display name prefers the label, then the account, then the host', () {
      const bare = RelayAccountEntry(origin: 'https://remote.example.com:8443', account: 'me@example.com');
      expect(bare.displayName, 'me@example.com');
      expect(bare.withLabel('公司').displayName, '公司');
      expect(bare.withLabel('   ').displayName, 'me@example.com');
      expect(bare.hostLabel, 'remote.example.com:8443');
    });

    test('a row without an account is a migrated address, not a broken one', () {
      const pending = RelayAccountEntry(origin: 'https://a.example.com', account: '');
      expect(pending.needsAccount, isTrue);
      expect(pending.displayName, 'a.example.com');
      // The label still wins, so an upgraded row keeps its name.
      expect(pending.withLabel('旧服务器').displayName, '旧服务器');
    });

    test('withLabel sets, clears and tolerates blank input', () {
      const bare = RelayAccountEntry(origin: 'https://a.example.com', account: 'me@example.com');
      expect(bare.withLabel('公司').label, '公司');
      expect(bare.withLabel('公司').withLabel(null).label, isNull);
      expect(bare.withLabel('公司').withLabel('   ').label, isNull);
      // copyWith without the argument must not drop an existing label.
      expect(bare.withLabel('公司').copyWith(provider: () => 'password').label, '公司');
    });

    test('the hosted server is not "the default" in a build that omits it', () {
      expect(
        const RelayAccountEntry(origin: defaultRelayServerOrigin, account: 'me@example.com').isDefaultServer,
        isFalse,
      );
    });

    test('the server-only format still decodes, for migration', () {
      final rows = RelayAccountEntry.decodeLegacyServers(
        jsonEncode([
          {'origin': 'https://a.example.com', 'account': 'me@example.com', 'label': 'A'},
          {'origin': 'https://b.example.com'},
        ]),
      );
      expect(rows, hasLength(2));
      expect(rows[0].account, 'me@example.com');
      expect(rows[1].account, isNull);
    });
  });

  group('RelayAccountsController', () {
    test('starts empty and reports when the stored list has loaded', () async {
      final c = container();
      await c.read(relayAccountsProvider.notifier).ready;
      expect(c.read(relayAccountsProvider), isEmpty);
    });

    test('two accounts on one server are two rows', () async {
      final c = container();
      final notifier = c.read(relayAccountsProvider.notifier);
      await notifier.ready;

      await notifier.remember('https://s.example.com', 'a@example.com');
      await notifier.remember('https://s.example.com', 'b@example.com');

      final rows = c.read(relayAccountsProvider);
      expect(rows, hasLength(2));
      expect(rows.map((e) => e.account), ['b@example.com', 'a@example.com']);
      expect(notifier.accountsOn('https://s.example.com'), hasLength(2));
    });

    test('re-remembering an account moves it to the front without duplicating', () async {
      final c = container();
      final notifier = c.read(relayAccountsProvider.notifier);
      await notifier.ready;

      await notifier.remember('https://s.example.com', 'a@example.com');
      await notifier.remember('https://s.example.com', 'b@example.com');
      await notifier.remember('https://s.example.com', 'a@example.com');

      expect(c.read(relayAccountsProvider).map((e) => e.account), ['a@example.com', 'b@example.com']);
    });

    test('the list survives a new container', () async {
      final first = container();
      await first
          .read(relayAccountsProvider.notifier)
          .remember('https://a.example.com', 'me@example.com', provider: 'password');

      final second = container();
      final notifier = second.read(relayAccountsProvider.notifier);
      await notifier.ready;
      final restored = second.read(relayAccountsProvider);
      expect(restored, hasLength(1));
      expect(restored.single.account, 'me@example.com');
      expect(restored.single.provider, 'password');
    });

    test('a pending row is replaced by the real account on the same server', () async {
      final c = container();
      final notifier = c.read(relayAccountsProvider.notifier);
      await notifier.ready;

      // Simulate what the upgrade leaves behind: an address with no account.
      await notifier.remember('https://a.example.com', '');
      expect(c.read(relayAccountsProvider), isEmpty, reason: 'an empty account cannot key a slot');

      await notifier.remember('https://a.example.com', 'me@example.com');
      expect(c.read(relayAccountsProvider), hasLength(1));
      expect(c.read(relayAccountsProvider).single.account, 'me@example.com');
    });

    test('forget removes only the named account', () async {
      final c = container();
      final notifier = c.read(relayAccountsProvider.notifier);
      await notifier.ready;
      await notifier.remember('https://s.example.com', 'a@example.com');
      await notifier.remember('https://s.example.com', 'b@example.com');

      final doomed = RelayAccountEntry(origin: 'https://s.example.com', account: 'a@example.com');
      await notifier.forget(doomed.id);
      expect(c.read(relayAccountsProvider).map((e) => e.account), ['b@example.com']);
    });

    test('rename sets and clears a label by id', () async {
      final c = container();
      final notifier = c.read(relayAccountsProvider.notifier);
      await notifier.ready;
      await notifier.remember('https://a.example.com', 'me@example.com');
      final id = c.read(relayAccountsProvider).single.id;

      await notifier.rename(id, '公司');
      expect(c.read(relayAccountsProvider).single.label, '公司');
      await notifier.rename(id, '  ');
      expect(c.read(relayAccountsProvider).single.label, isNull);
    });
  });

  group('RelayAccountSelection', () {
    test('encodes the pair the credential slot is keyed on', () {
      const selection = RelayAccountSelection(origin: 'https://a.example.com', account: 'me@example.com');
      final decoded = RelayAccountSelection.decode(selection.encode())!;
      expect(decoded.origin, selection.origin);
      expect(decoded.account, selection.account);
      expect(decoded.id, selection.id);
    });

    test('a selection without an account survives, for upgraded rows', () {
      final decoded = RelayAccountSelection.decode(jsonEncode({'origin': 'https://a.example.com'}))!;
      expect(decoded.account, isNull);
    });

    test('garbage decodes to null rather than a bogus selection', () {
      expect(RelayAccountSelection.decode(''), isNull);
      expect(RelayAccountSelection.decode('{oops'), isNull);
      expect(RelayAccountSelection.decode('[]'), isNull);
      expect(RelayAccountSelection.decode(jsonEncode({'origin': ''})), isNull);
    });
  });

  group('resolveRelayServer', () {
    test('a null selection means no server in this build', () {
      expect(resolveRelayServer(null), isNull);
      expect(resolveRelayServer('https://self.example.com'), 'https://self.example.com');
    });
  });
}
