import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/host_switcher.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support/fake_relay.dart';

const _first = 'http://relay-a.example.test:8020';
const _second = 'https://relay-b.example.test:9443';
const _alice = 'alice@example.test';
const _bob = 'bob@example.test';
const _carol = 'carol@example.test';

/// Stand-in for the server and durable credentials. A sign-in replaces the
/// credentials in its own slot, just as the production adapter does. All
/// assertions below are on what the user can see or tap.
class _Relay extends FakeRelayBackend {
  _Relay(this.origin) : super(hosts: []) {
    providers = [];
  }

  final String origin;

  @override
  String get serverLabel => Uri.parse(origin).authority;

  void seed(String email) {
    user = RelayUser(id: 'device:$email', displayName: email, provider: 'password');
    hosts = [
      RelayHost(id: '$origin/$email', name: '${Uri.parse(origin).host} · ${email.split('@').first}', online: true),
    ];
  }

  @override
  Future<RelayUser> loginWithPassword(String email, String password) async {
    if (password != 'test-pass') throw const HostLinkError(HostLinkErrorKind.notLoggedIn, 'Wrong test password');
    seed(email);
    return user!;
  }
}

void main() {
  late Map<(String, String?), _Relay> slots;
  setUp(() {
    slots = {};
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> open(WidgetTester tester, {Widget home = const RemoteScreen()}) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: home,
        brightness: Brightness.light,
        overrides: [
          relayScopedBackendProvider.overrideWith((ref, scope) => slots.putIfAbsent(scope, () => _Relay(scope.$1))),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  final address = find.byKey(const ValueKey('relay-server-address'));
  final emailField = find.byKey(const ValueKey('relay-server-email'));
  final passwordField = find.byKey(const ValueKey('relay-server-password'));
  final choose = find.byKey(const ValueKey('relay-choose-account'));

  Future<void> credentials(WidgetTester tester, String email, {String? origin, String password = 'test-pass'}) async {
    if (origin != null) await tester.enterText(address, origin);
    await tester.enterText(emailField, email);
    await tester.enterText(passwordField, password);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, String email) async {
    await tap(tester, choose);
    expect(passwordField, findsNothing, reason: 'Saved accounts are a chooser, not a password form');
    await tap(tester, find.widgetWithText(ListTile, email));
  }

  testWidgets('two accounts and another server can be opened directly, including after restarting', (tester) async {
    await open(tester);
    await tap(tester, find.text(appL10n.remoteAddServer));
    await credentials(tester, _alice, origin: _first);
    expect(find.text('relay-a.example.test · alice'), findsOneWidget);

    await tap(tester, find.byTooltip(appL10n.remoteAddAccount));
    expect(find.text(_first), findsWidgets, reason: 'Adding on this server keeps its scheme and port');
    await credentials(tester, _bob);
    expect(find.text('relay-a.example.test · bob'), findsOneWidget);
    expect(find.text('relay-a.example.test · alice'), findsNothing);

    await tap(tester, choose);
    await tap(tester, find.text(appL10n.remoteAddServer));
    await credentials(tester, _carol, origin: _second);
    expect(find.text('relay-b.example.test · carol'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await open(tester);
    expect(find.text('relay-b.example.test · carol'), findsOneWidget);
    await tap(tester, choose);
    await tap(tester, find.text(_first));
    expect(passwordField, findsNothing);
    expect(find.text('relay-a.example.test · bob'), findsOneWidget);
    await select(tester, _alice);
    expect(passwordField, findsNothing);
    expect(find.text('relay-a.example.test · alice').hitTestable(), findsOneWidget);
    expect(find.text('relay-b.example.test · carol'), findsNothing);
    await select(tester, _bob);
    expect(passwordField, findsNothing);
    const bobHost = 'relay-a.example.test · bob';
    await tap(tester, find.text(bobHost));
    expect(find.text(appL10n.remoteActiveHost(bobHost)), findsOneWidget);
  });

  testWidgets('a refused login and a saved account without credentials both leave the current account alone', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'remote_relay_accounts': jsonEncode([
        {'origin': _second, 'account': _carol},
      ]),
    });
    await open(tester);
    await tap(tester, find.text(appL10n.remoteAddServer));
    await credentials(tester, _alice, origin: _first);
    await tap(tester, find.byTooltip(appL10n.remoteAddAccount));
    await credentials(tester, _bob, password: 'wrong');
    expect(find.text('Wrong test password'), findsOneWidget);
    await tap(tester, find.byTooltip(appL10n.commonClose));
    expect(find.text('relay-a.example.test · alice'), findsOneWidget);
    await select(tester, _carol);
    expect(find.text(appL10n.remoteAccountMissing), findsOneWidget);
    expect(find.text(_second), findsWidgets);
    expect(find.text(_carol), findsOneWidget);
    expect(passwordField, findsOneWidget);
    await tap(tester, find.byTooltip(appL10n.commonClose));
    expect(find.text('relay-a.example.test · alice'), findsOneWidget);
  });

  testWidgets('a previous server-only login still opens its computers from the host switcher', (tester) async {
    slots[(_first, null)] = _Relay(_first)..seed(_alice);
    slots[(_second, _carol)] = _Relay(_second)..seed(_carol);
    SharedPreferences.setMockInitialValues({
      'remote_relay_selection': jsonEncode({'origin': _second, 'account': _carol}),
      'remote_relay_accounts': jsonEncode([
        {'origin': _first, 'account': _alice},
        {'origin': _second, 'account': _carol},
      ]),
    });
    await open(
      tester,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showHostSheet(context, onManage: () {}),
            child: Text(appL10n.remoteSwitchHost),
          ),
        ),
      ),
    );
    await tap(tester, find.text(appL10n.remoteSwitchHost));
    expect(find.text('relay-b.example.test · carol'), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('host-choose-relay-account')));
    await tap(tester, find.widgetWithText(ListTile, _alice));
    expect(passwordField, findsNothing);
    expect(find.text('relay-a.example.test · alice').hitTestable(), findsOneWidget);
    expect(find.text('relay-b.example.test · carol'), findsNothing);
  });
}
