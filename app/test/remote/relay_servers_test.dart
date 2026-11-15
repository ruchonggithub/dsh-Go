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

  group('RelayServerEntry', () {
    test('json round-trip keeps origin, label, account and time', () {
      final when = DateTime.utc(2026, 11, 16, 3, 4, 5);
      final entry = RelayServerEntry(
        origin: 'https://remote.example.com',
        label: '公司',
        account: 'me@example.com',
        lastUsed: when,
      );
      final decoded = RelayServerEntry.fromJson(jsonDecode(jsonEncode(entry.toJson())))!;
      expect(decoded.origin, entry.origin);
      expect(decoded.label, entry.label);
      expect(decoded.account, entry.account);
      expect(decoded.lastUsed, when);
    });

    test('a bare string decodes to one entry, so a half-migrated value survives', () {
      final list = RelayServerEntry.decodeList(jsonEncode('https://a.example.com'));
      expect(list, hasLength(1));
      expect(list.single.origin, 'https://a.example.com');
    });

    test('malformed input yields an empty list instead of throwing', () {
      expect(RelayServerEntry.decodeList(null), isEmpty);
      expect(RelayServerEntry.decodeList(''), isEmpty);
      expect(RelayServerEntry.decodeList('{oops'), isEmpty);
      expect(RelayServerEntry.decodeList('[1,2,3]'), isEmpty);
      expect(RelayServerEntry.decodeList(jsonEncode([{'no': 'origin'}])), isEmpty);
    });

    test('duplicate origins collapse to the first occurrence', () {
      final list = RelayServerEntry.decodeList(
        jsonEncode([
          {'origin': 'https://a.example.com', 'account': 'first@example.com'},
          {'origin': 'https://a.example.com', 'account': 'second@example.com'},
        ]),
      );
      expect(list, hasLength(1));
      expect(list.single.account, 'first@example.com');
    });

    test('display name prefers the label and falls back to the host', () {
      const bare = RelayServerEntry(origin: 'https://remote.example.com:8443');
      expect(bare.displayName, 'remote.example.com:8443');
      expect(bare.hostLabel, 'remote.example.com:8443');
      expect(bare.copyWith(label: '公司').displayName, '公司');
      expect(bare.copyWith(label: '   ').displayName, 'remote.example.com:8443');
    });

    test('the hosted server is recognised', () {
      expect(const RelayServerEntry(origin: defaultRelayServerOrigin).isDefault, isTrue);
      expect(const RelayServerEntry(origin: 'https://self.example.com').isDefault, isFalse);
    });

    test('withLabel sets, clears and tolerates blank input', () {
      const bare = RelayServerEntry(origin: 'https://a.example.com');
      expect(bare.withLabel('公司').label, '公司');
      expect(bare.withLabel('公司').withLabel(null).label, isNull);
      expect(bare.withLabel('公司').withLabel('   ').label, isNull);
      expect(bare.withLabel('   ').label, isNull);
      // copyWith without the argument must not drop an existing label.
      expect(bare.withLabel('公司').copyWith(account: () => 'x@example.com').label, '公司');
    });
  });

  group('RelayServersController', () {
    test('starts empty and reports when the stored list has loaded', () async {
      final c = container();
      final notifier = c.read(relayServersProvider.notifier);
      await notifier.ready;
      expect(c.read(relayServersProvider), isEmpty);
    });

    test('remember adds an entry and moves an existing one to the front', () async {
      final c = container();
      final notifier = c.read(relayServersProvider.notifier);
      await notifier.ready;

      await notifier.remember('https://a.example.com');
      await notifier.remember('https://b.example.com');
      expect(c.read(relayServersProvider).map((e) => e.origin), [
        'https://b.example.com',
        'https://a.example.com',
      ]);

      // Re-remembering a server must not duplicate it.
      await notifier.remember('https://a.example.com');
      expect(c.read(relayServersProvider).map((e) => e.origin), [
        'https://a.example.com',
        'https://b.example.com',
      ]);
    });

    test('the list survives a new container', () async {
      final first = container();
      await first.read(relayServersProvider.notifier).remember('https://a.example.com', account: 'me@example.com');

      final second = container();
      final notifier = second.read(relayServersProvider.notifier);
      await notifier.ready;
      final restored = second.read(relayServersProvider);
      expect(restored, hasLength(1));
      expect(restored.single.origin, 'https://a.example.com');
      expect(restored.single.account, 'me@example.com');
    });

    test('a legacy single-server preference becomes the first entry', () async {
      SharedPreferences.setMockInitialValues({
        RelayServersController.legacyKey: 'https://legacy.example.com',
      });
      final c = container();
      final notifier = c.read(relayServersProvider.notifier);
      await notifier.ready;
      final list = c.read(relayServersProvider);
      expect(list, hasLength(1));
      expect(list.single.origin, 'https://legacy.example.com');
    });

    test('writing the list drops the legacy key so a removed server cannot return', () async {
      SharedPreferences.setMockInitialValues({
        RelayServersController.legacyKey: 'https://legacy.example.com',
      });
      final c = container();
      final notifier = c.read(relayServersProvider.notifier);
      await notifier.ready;
      await notifier.remember('https://new.example.com');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(RelayServersController.legacyKey), isNull);
      expect(c.read(relayServersProvider).map((e) => e.origin), contains('https://new.example.com'));
    });

    test('noteAccount records who signed in where, and adds an unknown server', () async {
      final c = container();
      final notifier = c.read(relayServersProvider.notifier);
      await notifier.ready;

      await notifier.remember('https://a.example.com');
      await notifier.noteAccount('https://a.example.com', 'me@example.com');
      expect(c.read(relayServersProvider).single.account, 'me@example.com');

      // An account for a server that was never saved still gets a row.
      await notifier.noteAccount('https://b.example.com', 'other@example.com');
      expect(c.read(relayServersProvider).map((e) => e.origin), containsAll([
        'https://a.example.com',
        'https://b.example.com',
      ]));
    });

    test('noteAccount without an account does not create a row', () async {
      final c = container();
      final notifier = c.read(relayServersProvider.notifier);
      await notifier.ready;
      await notifier.noteAccount('https://a.example.com', null);
      expect(c.read(relayServersProvider), isEmpty);
    });

    test('rename sets and clears a label', () async {
      final c = container();
      final notifier = c.read(relayServersProvider.notifier);
      await notifier.ready;
      await notifier.remember('https://a.example.com');

      await notifier.rename('https://a.example.com', '公司');
      expect(c.read(relayServersProvider).single.label, '公司');
      expect(c.read(relayServersProvider).single.displayName, '公司');

      await notifier.rename('https://a.example.com', '  ');
      expect(c.read(relayServersProvider).single.label, isNull);
    });

    test('forget removes only the named server', () async {
      final c = container();
      final notifier = c.read(relayServersProvider.notifier);
      await notifier.ready;
      await notifier.remember('https://a.example.com');
      await notifier.remember('https://b.example.com');

      await notifier.forget('https://a.example.com');
      expect(c.read(relayServersProvider).map((e) => e.origin), ['https://b.example.com']);
    });

    test('entryFor finds a saved server and tolerates unknown origins', () async {
      final c = container();
      final notifier = c.read(relayServersProvider.notifier);
      await notifier.ready;
      await notifier.remember('https://a.example.com');

      expect(c.read(relayServersProvider.notifier).entryFor('https://a.example.com')?.origin, 'https://a.example.com');
      expect(c.read(relayServersProvider.notifier).entryFor('https://nope.example.com'), isNull);
      expect(c.read(relayServersProvider.notifier).entryFor(null), isNull);
    });
  });
}
