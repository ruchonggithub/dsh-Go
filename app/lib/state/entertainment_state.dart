import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the app offers its entertainment half.
///
/// One switch for everything that is play rather than work: the tavern (role
/// play), the companion room, pets, DS Bots, the community page and the forum,
/// wallpapers, share posters, conversation replay and the little visual
/// effects around all of them.
///
/// Off hides the entry points; it does not remove the code. Everything these
/// screens need — the shared layout pieces, the voice stack, the credential
/// store, the pack libraries — stays compiled and working, because the parts
/// that are only *named* like entertainment are in fact load-bearing for the
/// chat: `PetPerch` lays out the composer strip, `ThinkingOrb` draws the
/// thinking state, `speech_ui` prints voice errors. Unpicking those would
/// take the core down with them, and every future merge with upstream would
/// land on a tree that no longer matches.
///
/// So this is a preference, not a build flag: flipping it changes what is
/// offered without changing what is built.
class EntertainmentSettings {
  const EntertainmentSettings({this.enabled = defaultEnabled, this.loaded = false});

  /// Off unless the person turns it on: this build is meant for work first.
  static const bool defaultEnabled = false;

  static const String prefsKey = 'entertainment.enabled';

  /// Whether the entertainment half is offered.
  final bool enabled;

  /// The stored preference has been read. Until then the default applies, so
  /// first frame and later frames agree.
  final bool loaded;

  EntertainmentSettings copyWith({bool? enabled, bool? loaded}) =>
      EntertainmentSettings(enabled: enabled ?? this.enabled, loaded: loaded ?? this.loaded);
}

class EntertainmentController extends Notifier<EntertainmentSettings> {
  bool _touched = false;
  late Future<void> _loaded;

  @override
  EntertainmentSettings build() {
    _loaded = _load();
    return const EntertainmentSettings();
  }

  /// The stored preference has been read. Callers that must not act on the
  /// default (a test asserting a fresh container, a screen deciding whether to
  /// show a section for the first time) wait for this.
  Future<void> get ready => _loaded;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // A choice made while the read was in flight wins.
      if (_touched) return;
      final stored = prefs.getBool(EntertainmentSettings.prefsKey);
      state = EntertainmentSettings(
        enabled: stored ?? EntertainmentSettings.defaultEnabled,
        loaded: true,
      );
    } catch (_) {
      state = const EntertainmentSettings(loaded: true);
    }
  }

  Future<void> setEnabled(bool enabled) async {
    _touched = true;
    state = state.copyWith(enabled: enabled, loaded: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(EntertainmentSettings.prefsKey, enabled);
    } catch (_) {}
  }
}

final entertainmentProvider = NotifierProvider<EntertainmentController, EntertainmentSettings>(
  EntertainmentController.new,
);

/// Whether to show entertainment entry points right now.
///
/// Read as a boolean so a widget rebuilds only when the answer changes, not on
/// every unrelated update of the settings object.
final entertainmentEnabledProvider = Provider<bool>(
  (ref) => ref.watch(entertainmentProvider.select((s) => s.enabled)),
);
