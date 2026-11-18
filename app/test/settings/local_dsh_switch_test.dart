import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/onboarding/onboarding_flow.dart';
import 'package:dsh_app/ui/remote/host_switcher.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../remote/support/fake_relay.dart';
import '../safe_mode/support.dart';
import '../shell/golden_harness.dart';

const _computer = 'Remote test computer';
const _remoteHome = 'Remote workspace';
const _settingsButton = 'Open app settings';

void main() {
  late RecordingRuntime runtime;

  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: RootGate(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  const Text(_remoteHome),
                  TextButton(
                    onPressed: () => showHostSheet(context, onManage: () {}),
                    child: Text(appL10n.remoteSwitchHost),
                  ),
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
                    child: const Text(_settingsButton),
                  ),
                ],
              ),
            ),
          ),
        ),
        overrides: [
          localRuntimeProvider.overrideWith(() => runtime),
          relayBackendProvider.overrideWithValue(
            FakeRelayBackend(
              user: sampleRelayUser,
              hosts: const [RelayHost(id: 'test-computer', name: _computer, online: true)],
            ),
          ),
        ],
      ),
    );
    // Give the asynchronous settings and saved-host reads a chance to schedule frames.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  final switchRow = find.byKey(const ValueKey('settings-local-dsh'));
  final engine = find.text(appL10n.hubSettingsEngine);
  Future<void> revealSwitch(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      switchRow,
      320,
      scrollable: find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)),
    );
    await tester.pumpAndSettle();
  }

  final phone = find.text(appL10n.commonThisPhone);

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    runtime = RecordingRuntime(
      const LocalRuntimeState(
        loaded: true,
        status: RuntimeStatus(phase: RuntimePhase.installed, installedVersion: 'r1', bundledVersion: 'r1'),
      ),
    );
  });

  testWidgets('default launch offers remote hosts instead of starting an installed local engine', (tester) async {
    usePhoneSurface(tester);
    await launch(tester);
    expect(find.byType(OnboardingFlow), findsNothing);
    expect(find.byType(RemoteScreen), findsOneWidget);
    expect(find.text(_computer).hitTestable(), findsOneWidget);
    expect(runtime.starts, isEmpty);
    await tap(tester, find.byTooltip(appL10n.commonSettings));
    await revealSwitch(tester);
    expect(find.text(appL10n.settingsLocalDsh), findsOneWidget);
    expect(engine, findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tap(tester, find.text(_computer));
    expect(find.text(_remoteHome), findsOneWidget);
    await tap(tester, find.text(appL10n.remoteSwitchHost));
    expect(find.text(_computer), findsOneWidget);
    expect(phone, findsNothing);
  });

  testWidgets('the switch persists, reveals the local host and hides it again without leaving the remote host', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'active_host': const HostRef.relay('test-computer', name: _computer).encode(),
    });
    usePhoneSurface(tester);
    tester.view.physicalSize = const Size(390 * 2, 1550 * 2);
    await launch(tester);
    expect(find.text(_remoteHome), findsOneWidget);
    await tap(tester, find.text(_settingsButton));
    await revealSwitch(tester);
    expect(find.text(appL10n.settingsLocalDsh), findsOneWidget);
    expect(engine, findsNothing);
    await tap(tester, switchRow);
    expect(engine, findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(runtime.starts, ['start']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    runtime = RecordingRuntime(const LocalRuntimeState(loaded: true, status: runningStatus));
    await launch(tester);
    await tap(tester, find.text(appL10n.remoteSwitchHost));
    expect(phone, findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tap(tester, find.text(_settingsButton));
    await revealSwitch(tester);
    expect(engine, findsOneWidget);
    await tap(tester, switchRow);
    expect(engine, findsNothing);
    expect(runtime.stops, 1);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text(_remoteHome), findsOneWidget);
    await tap(tester, find.text(appL10n.remoteSwitchHost));
    expect(find.text(_computer), findsOneWidget);
    expect(phone, findsNothing);
  });
}
