import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the app offers its entertainment half.
///
/// People do not see this value: they see **生产力模式** (`productivityModeProvider`,
/// 设置 › 外观), which is this one inverted. On hides the play half; off shows it.
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
  ///
  /// 生产力模式's default is the inverse: on, which is this.
  static const bool defaultEnabled = false;

  /// Where the choice is stored now: 生产力模式 itself, so the key says what
  /// people see. Read through [EntertainmentController._load], which also
  /// migrates [legacyPrefsKey].
  static const String prefsKey = 'productivity.enabled';

  /// The old key, which stored the entertainment switch directly (the inverse).
  ///
  /// Only read, once, when [prefsKey] is absent: a person who chose
  /// 娱乐内容 on keeps entertainment on (productivity off) across the rename.
  static const String legacyPrefsKey = 'entertainment.enabled';

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
      // The new key holds 生产力模式 (the inverse); the old one held this value.
      final stored = prefs.getBool(EntertainmentSettings.prefsKey);
      if (stored != null) {
        state = EntertainmentSettings(enabled: !stored, loaded: true);
        return;
      }
      final legacy = prefs.getBool(EntertainmentSettings.legacyPrefsKey);
      if (legacy != null) {
        // Migrated once, so the old key is never read again (nothing is
        // deleted, so a downgrade still finds its own value). A choice made
        // meanwhile wins over both.
        try {
          await prefs.setBool(EntertainmentSettings.prefsKey, !legacy);
        } catch (_) {}
        if (_touched) return;
        state = EntertainmentSettings(enabled: legacy, loaded: true);
        return;
      }
      state = const EntertainmentSettings(loaded: true);
    } catch (_) {
      state = const EntertainmentSettings(loaded: true);
    }
  }

  Future<void> setEnabled(bool enabled) async {
    _touched = true;
    state = state.copyWith(enabled: enabled, loaded: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      // Stored inverted: the key is 生产力模式.
      await prefs.setBool(EntertainmentSettings.prefsKey, !enabled);
    } catch (_) {}
  }

  /// 生产力模式: on hides the play half. The switch people actually see; it is
  /// [setEnabled] with the answer inverted, so there is one stored state.
  Future<void> setProductivity(bool productivity) => setEnabled(!productivity);
}

final entertainmentProvider = NotifierProvider<EntertainmentController, EntertainmentSettings>(
  EntertainmentController.new,
);

/// Whether to show entertainment entry points right now.
///
/// Read as a boolean so a widget rebuilds only when the answer changes, not on
/// every unrelated update of the settings object.
final entertainmentEnabledProvider = Provider<bool>((ref) => ref.watch(entertainmentProvider.select((s) => s.enabled)));

/// 生产力模式: hides the entertainment half. Inverse of `enabled`.
///
/// The one switch the settings show (设置 › 外观). It is derived rather than
/// stored, so every screen that already reads [entertainmentEnabledProvider]
/// keeps its meaning and there is still a single stored answer.
final productivityModeProvider = Provider<bool>((ref) => !ref.watch(entertainmentEnabledProvider));
