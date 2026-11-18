import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../remote/link_status.dart';
import '../remote/relay/dsh_remote_backend.dart';
import 'android_features.dart';
import 'app_info.dart';
import '../remote/relay/relay_backend.dart';
import '../remote/relay/webrtc_peer.dart';
import '../remote/secret_store.dart';
import '../remote/ssh/ssh_host_config.dart';
import '../remote/ssh/ssh_transport.dart';
import '../links/removed_links.dart' show hostedRelayServerEnabled;
import 'relay_server_entry.dart';
import 'sessions_state.dart';
import 'read_list_epoch.dart';

export '../remote/link_status.dart' show HostLinkStatus, HostLinkPhase, HostLinkStep, HostLinkError, HostLinkErrorKind;
export '../remote/ssh/ssh_transport.dart' show PresentedHostKey;
export '../remote/relay/relay_backend.dart' show RelayHost, RelayTrust, RelayUser;
export '../remote/ssh/ssh_host_config.dart';

/// The three kinds of DSH host the app can talk to.
enum HostKind { local, ssh, relay }

/// Identifies a host: the on-device engine, a saved SSH host, or a relay
/// (ds-harness-remote) device. Equality is by kind + id; [name] is only a
/// cached display name for relay hosts (their list lives on the server).
class HostRef {
  const HostRef._(this.kind, this.id, [this.name]);

  static const local = HostRef._(HostKind.local, 'local');

  const HostRef.ssh(String id) : this._(HostKind.ssh, id);

  const HostRef.relay(String id, {String? name}) : this._(HostKind.relay, id, name);

  final HostKind kind;
  final String id;
  final String? name;

  bool get isLocal => kind == HostKind.local;

  String encode() => jsonEncode({'kind': kind.name, 'id': id, if (name != null) 'name': name});

  static HostRef decode(String? raw) {
    if (raw == null || raw.isEmpty) return local;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return local;
      final id = map['id'];
      final name = map['name'];
      if (id is! String || id.isEmpty) return local;
      return switch (map['kind']) {
        'ssh' => HostRef.ssh(id),
        'relay' => HostRef.relay(id, name: name is String ? name : null),
        _ => local,
      };
    } catch (_) {
      return local;
    }
  }

  @override
  bool operator ==(Object other) => other is HostRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'HostRef(${kind.name}:$id)';
}

/// Chat-header label for a connection: "本机", "电脑 · SSH", "家里的 Mac · 远程".
String hostLabel(HostKind kind, String? name) => switch (kind) {
  HostKind.local => appL10n.commonThisPhone,
  HostKind.ssh => '${_short(name ?? appL10n.stateSshHost)} · SSH',
  HostKind.relay => appL10n.stateHostRemoteLabel(_short(name ?? appL10n.commonRemoteHost)),
};

String _short(String name) {
  final t = name.trim();
  return t.length <= 14 ? t : '${t.substring(0, 13)}…';
}

// ── Secrets ──────────────────────────────────────────────────────────────────

/// Keystore-backed in the app; tests override with [MemorySecretStore].
final secretStoreProvider = Provider<SecretStore>((ref) => SecureSecretStore());

// ── Saved SSH hosts ──────────────────────────────────────────────────────────

class HostsState {
  const HostsState({this.ssh = const [], this.loaded = false});

  final List<SshHostConfig> ssh;
  final bool loaded;

  SshHostConfig? sshById(String id) {
    for (final h in ssh) {
      if (h.id == id) return h;
    }
    return null;
  }
}

/// Saved SSH hosts: configs in SharedPreferences, secrets in [SecretStore].
class HostsController extends Notifier<HostsState> {
  static const prefsKey = 'remote_ssh_hosts';

  SecretStore get _secrets => ref.read(secretStoreProvider);
  late Future<void> _loaded;

  @override
  HostsState build() {
    _loaded = _load();
    return const HostsState();
  }

  /// Completes once the saved list has been read (writes wait for it, so an
  /// early save can't clobber what's on disk).
  Future<void> get ready => _loaded;

  Future<void> _load() async {
    var hosts = const <SshHostConfig>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null) {
        final list = jsonDecode(raw);
        if (list is List) hosts = list.map(SshHostConfig.fromJson).whereType<SshHostConfig>().toList();
      }
    } catch (_) {
      // No preferences backend (tests) or a corrupt entry: start empty.
    }
    state = HostsState(ssh: hosts, loaded: true);
  }

  Future<bool> _persist(List<SshHostConfig> hosts) async {
    state = HostsState(ssh: List.unmodifiable(hosts), loaded: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(prefsKey, jsonEncode([for (final h in hosts) h.toJson()]));
    } catch (_) {
      return false;
    }
  }

  /// Adds or replaces [config]. With [secrets], stores the one matching the
  /// auth method and deletes the other kind, so a host never keeps a stale
  /// password next to its key.
  /// Returns the preferences write result. A false result does not undo the
  /// in-memory config or any completed secret operations.
  Future<bool> saveSsh(SshHostConfig config, {SshSecrets? secrets}) async {
    await _loaded;
    ref.read(readListCredentialEpochProvider.notifier).advance();
    if (secrets != null) await _writeSecrets(config, secrets);
    final hosts = [...state.ssh];
    final index = hosts.indexWhere((h) => h.id == config.id);
    if (index >= 0) {
      hosts[index] = config;
    } else {
      hosts.add(config);
    }
    return _persist(hosts);
  }

  Future<void> _writeSecrets(SshHostConfig config, SshSecrets secrets) async {
    final id = config.id;
    Future<void> put(String key, String? value) async {
      if (value == null || value.isEmpty) {
        await _secrets.delete(key);
      } else {
        await _secrets.write(key, value);
      }
    }

    if (config.auth == SshAuthMethod.password) {
      await put(SshSecrets.passwordKey(id), secrets.password);
      await _secrets.delete(SshSecrets.privateKeyKey(id));
      await _secrets.delete(SshSecrets.passphraseKey(id));
    } else {
      await put(SshSecrets.privateKeyKey(id), secrets.privateKey?.trim());
      await put(SshSecrets.passphraseKey(id), secrets.passphrase);
      await _secrets.delete(SshSecrets.passwordKey(id));
    }
    // A failure writing the credential the person just entered must be
    // reported as that failure, not hidden behind unrelated token cleanup.
    await put(
      SshSecrets.attachTokenKey(id),
      config.dshMode == SshDshMode.attachOnly ? secrets.attachToken?.trim() : null,
    );
  }

  Future<SshSecrets> loadSecrets(String id) async {
    Future<String?> get(String key) async {
      try {
        return await _secrets.read(key);
      } catch (_) {
        return null;
      }
    }

    return SshSecrets(
      password: await get(SshSecrets.passwordKey(id)),
      privateKey: await get(SshSecrets.privateKeyKey(id)),
      passphrase: await get(SshSecrets.passphraseKey(id)),
      attachToken: await get(SshSecrets.attachTokenKey(id)),
    );
  }

  /// Removes the host and its secrets; switches back to 本机 if it was active.
  Future<void> removeSsh(String id) async {
    await _loaded;
    await _persist([...state.ssh.where((h) => h.id != id)]);
    for (final key in [
      SshSecrets.passwordKey(id),
      SshSecrets.privateKeyKey(id),
      SshSecrets.passphraseKey(id),
      SshSecrets.attachTokenKey(id),
    ]) {
      try {
        await _secrets.delete(key);
      } catch (_) {}
    }
    unawaited(ref.read(activeHostProvider.notifier).forget((h) => h == HostRef.ssh(id)));
  }

  /// Trust on first use: remembers the key the person accepted.
  Future<void> pinHostKey(String id, PresentedHostKey key) async {
    final host = state.sshById(id);
    if (host == null) return;
    await saveSsh(host.copyWith(hostKeyType: () => key.type, hostKeyFingerprint: () => key.fingerprint));
  }

  /// Forgets the pinned key (after the person confirmed the machine changed).
  Future<void> resetHostKey(String id) async {
    final host = state.sshById(id);
    if (host == null) return;
    await saveSsh(host.copyWith(hostKeyType: () => null, hostKeyFingerprint: () => null));
  }
}

final hostsProvider = NotifierProvider<HostsController, HostsState>(HostsController.new);

// ── Active host ──────────────────────────────────────────────────────────────

/// Whether a cold start restores the last host. Manual connects and their
/// short-network-outage recovery are independent of this preference.
class RemoteAutoConnectController extends Notifier<bool> {
  static const prefsKey = 'remote_auto_connect_on_startup';
  late Future<void> _loaded;

  @override
  bool build() {
    _loaded = _load();
    return true;
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getBool(prefsKey);
      if (stored != null && ref.mounted) state = stored;
    } catch (_) {}
  }

  Future<void> set(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = value;
    try {
      await (await SharedPreferences.getInstance()).setBool(prefsKey, value);
    } catch (_) {}
  }
}

final remoteAutoConnectProvider = NotifierProvider<RemoteAutoConnectController, bool>(RemoteAutoConnectController.new);

/// Reduces history payloads on supporting Remote Hosts, never live events.
/// Changes apply to the next client, so an active turn is not interrupted.
class RemoteCompactHistoryController extends Notifier<bool> {
  static const prefsKey = 'remote_compact_history';
  late Future<void> _loaded;

  @override
  bool build() {
    _loaded = _load();
    return false;
  }

  Future<void> get ready => _loaded;

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getBool(prefsKey);
      if (stored != null && ref.mounted) state = stored;
    } catch (_) {}
  }

  Future<void> set(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = value;
    try {
      await (await SharedPreferences.getInstance()).setBool(prefsKey, value);
    } catch (_) {}
  }
}

final remoteCompactHistoryProvider = NotifierProvider<RemoteCompactHistoryController, bool>(
  RemoteCompactHistoryController.new,
);

/// Which host the chat, session list and new chats use. Persisted.
class ActiveHostController extends Notifier<HostRef> {
  static const prefsKey = 'active_host';
  bool _touched = false;
  late Future<void> _loaded;

  @override
  HostRef build() {
    // Read the startup preference now, so the remote hosts page shows the
    // stored value from its first frame.
    ref.read(remoteAutoConnectProvider);
    _loaded = _restore();
    return HostRef.local;
  }

  /// The startup host choice has settled, including a disabled auto-connect
  /// preference or an earlier explicit selection.
  Future<void> get ready => _loaded;

  Future<void> _restore() async {
    final owner = ref;
    try {
      final prefs = await SharedPreferences.getInstance();
      final restored = HostRef.decode(prefs.getString(prefsKey));
      final autoConnect = prefs.getBool(RemoteAutoConnectController.prefsKey) ?? true;
      if (!_touched && owner.mounted && autoConnect) state = restored;
    } catch (_) {
      // No preferences backend (tests): stay on 本机.
    }
  }

  /// Switches hosts. The open conversation belongs to the old host, so the
  /// chat goes back to "新对话".
  void select(HostRef host) {
    _touched = true;
    if (host == state && host.name == state.name) return;
    final changed = host != state;
    state = host;
    if (changed) ref.read(currentSessionProvider.notifier).select(null);
    unawaited(
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setString(prefsKey, host.encode()))
          .catchError((_) => false),
    );
  }

  /// Hosts matching [gone] no longer exist (a deleted SSH host, a signed-out
  /// relay account): leave one in use for 本机, and drop one only saved for
  /// the next launch (with 连接上次使用的主机 off, this launch never used it).
  Future<void> forget(bool Function(HostRef host) gone) async {
    if (gone(state)) {
      select(HostRef.local);
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (gone(HostRef.decode(prefs.getString(prefsKey)))) await prefs.setString(prefsKey, HostRef.local.encode());
    } catch (_) {}
  }
}

final activeHostProvider = NotifierProvider<ActiveHostController, HostRef>(ActiveHostController.new);

// ── DSH Remote (relay) accounts ──────────────────────────────────────────────

/// The signed-in DSH Remote accounts, most recently used first.
///
/// One row per (server, account): a server can hold several accounts, each with
/// its own credentials, because `packages/dsh_remote` derives the storage scope
/// from both. Rows are shortcuts — the tokens stay in secure storage under that
/// scope, keyed by [RelayAccountEntry.id].
class RelayAccountsController extends Notifier<List<RelayAccountEntry>> {
  static const prefsKey = 'remote_relay_accounts';

  /// Written by earlier versions: the single selected server, and then a list
  /// of servers with the last account seen on each. Both are read once so an
  /// upgrade keeps whatever the person had.
  static const legacyServerKey = 'remote_relay_server';
  static const legacyServersKey = 'remote_relay_servers';

  bool _touched = false;
  late Future<void> _loaded;

  @override
  List<RelayAccountEntry> build() {
    _loaded = _restore();
    return const [];
  }

  /// The saved list has been read; writes wait for it so an early save cannot
  /// drop what is already on disk.
  Future<void> get ready => _loaded;

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var entries = RelayAccountEntry.decodeList(prefs.getString(prefsKey));
      if (entries.isEmpty) entries = _migrate(prefs);
      if (!_touched && entries.isNotEmpty) state = entries;
    } catch (_) {}
  }

  /// Rows from the server-only formats. An account name is required to address
  /// a credential slot, so a server row without one becomes a "placeholder"
  /// row the person completes by signing in — it is kept so the address is not
  /// lost, and [remember] replaces it once the account is known.
  List<RelayAccountEntry> _migrate(SharedPreferences prefs) {
    final now = DateTime.now();
    final out = <RelayAccountEntry>[];
    final seenOrigin = <String>{};

    for (final entry in RelayAccountEntry.decodeLegacyServers(prefs.getString(legacyServersKey))) {
      if (!seenOrigin.add(entry.origin)) continue;
      final account = entry.account?.trim();
      out.add(
        RelayAccountEntry(
          origin: entry.origin,
          // An empty account cannot key a credential slot; use a marker the UI
          // shows as "sign in again" rather than silently dropping the row.
          account: (account == null || account.isEmpty) ? _pendingAccount : account,
          label: entry.label,
          lastUsed: entry.lastUsed ?? now,
        ),
      );
    }

    final legacyServer = prefs.getString(legacyServerKey);
    if (legacyServer != null && legacyServer.isNotEmpty && seenOrigin.add(legacyServer)) {
      out.add(RelayAccountEntry(origin: legacyServer, account: _pendingAccount, lastUsed: now));
    }
    return out;
  }

  Future<void> _persist(List<RelayAccountEntry> entries) async {
    _touched = true;
    state = entries;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, RelayAccountEntry.encodeList(entries));
      // The list supersedes both older keys; keeping them would resurrect a
      // removed account on the next migration.
      if (prefs.containsKey(legacyServersKey)) await prefs.remove(legacyServersKey);
      if (prefs.containsKey(legacyServerKey)) await prefs.remove(legacyServerKey);
    } catch (_) {}
  }

  /// Records a signed-in account and moves it to the front.
  ///
  /// [account] is what the server reports. A row saved as [_pendingAccount] for
  /// the same origin is replaced by this one, so an upgraded install does not
  /// accumulate a dead row.
  Future<void> remember(String origin, String account, {String? label, String? provider}) async {
    await _loaded;
    final now = DateTime.now();
    final trimmedAccount = account.trim();
    if (trimmedAccount.isEmpty || trimmedAccount == _pendingAccount) return;

    final id = RelayAccountEntry(origin: origin, account: trimmedAccount).id;
    final existing = state.where((e) => e.id == id).firstOrNull;
    final trimmedLabel = label?.trim();
    final entry = (existing ?? RelayAccountEntry(origin: origin, account: trimmedAccount)).copyWith(
      // Omitting a label keeps the saved one; typing a blank one clears it.
      label: label == null ? RelayAccountEntry.clearLabel : ((trimmedLabel?.isEmpty ?? true) ? null : trimmedLabel),
      provider: provider == null ? null : () => provider,
      lastUsed: now,
    );
    await _persist([entry, ...state.where((e) => e.id != id && !(e.origin == origin && e.account == _pendingAccount))]);
  }

  /// Sets the display name for [id]; a blank [label] removes it.
  Future<void> rename(String id, String? label) async {
    await _loaded;
    if (state.every((e) => e.id != id)) return;
    await _persist([for (final e in state) e.id == id ? e.withLabel(label) : e]);
  }

  /// Forgets [id]. Its credentials stay in secure storage — dropping the row
  /// only hides the shortcut, and signing in again restores it.
  Future<void> forget(String id) async {
    await _loaded;
    if (state.every((e) => e.id != id)) return;
    await _persist([...state.where((e) => e.id != id)]);
  }

  RelayAccountEntry? entryFor(String? id) {
    if (id == null) return null;
    return state.where((e) => e.id == id).firstOrNull;
  }

  /// The rows for one server, newest first.
  List<RelayAccountEntry> accountsOn(String origin) => [
    for (final e in state)
      if (e.origin == origin && e.account != _pendingAccount) e,
  ];
}

/// Marks a row that came from an older format which did not know the account.
/// Such a row cannot address a credential slot, so it only carries the address
/// until the person signs in on it.
const String _pendingAccount = '';

/// The selected account, as the credential scope it addresses.
///
/// Kept separate from the server selection because the same server can be used
/// with several accounts; the backend is built for this scope, so switching
/// accounts switches which stored tokens it reads.
class RelaySelectionController extends Notifier<RelayAccountSelection?> {
  static const prefsKey = 'remote_relay_selection';
  bool _touched = false;

  @override
  RelayAccountSelection? build() {
    unawaited(_restore());
    return null;
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty || _touched) return;
      final restored = RelayAccountSelection.decode(raw);
      if (restored != null) state = restored;
    } catch (_) {}
  }

  /// Records [selection] and persists it.
  Future<void> set(RelayAccountSelection? selection) async {
    _touched = true;
    if (selection == state) return;
    unawaited(ref.read(activeHostProvider.notifier).forget((h) => h.kind == HostKind.relay));
    state = selection;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (selection == null) {
        await prefs.remove(prefsKey);
      } else {
        await prefs.setString(prefsKey, selection.encode());
      }
    } catch (_) {}
  }
}

/// One account on one server: the pair the credential scope is derived from.
class RelayAccountSelection {
  const RelayAccountSelection({required this.origin, required this.account});

  final String origin;

  /// Null for a server whose account was not recorded (an upgraded row the
  /// person has not signed in on yet): the backend then reads the server's
  /// single upstream slot.
  final String? account;

  String get id => RelayAccountEntry(origin: origin, account: account ?? '').id;

  String encode() => jsonEncode({'origin': origin, if (account != null) 'account': account});

  static RelayAccountSelection? decode(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final origin = map['origin'];
      if (origin is! String || origin.isEmpty) return null;
      final account = map['account'];
      return RelayAccountSelection(origin: origin, account: account is String && account.isNotEmpty ? account : null);
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is RelayAccountSelection && other.origin == origin && other.account == account;

  @override
  int get hashCode => Object.hash(origin, account);

  @override
  String toString() => 'RelayAccountSelection($origin, ${account ?? '-'})';
}

/// The selected server, derived from the selected account.
///
/// Kept as a plain origin so the backend, the pairing flow and the WebView
/// console keep working unchanged. Which account's tokens are used is decided
/// by [relaySelectionProvider]: that pair is what the credential slot is keyed
/// on, while this is only the address half.
class RelayServerController extends Notifier<String?> {
  @override
  String? build() => ref.watch(relaySelectionProvider)?.origin;

  Future<void> _set(String? origin) async {
    final current = ref.read(relaySelectionProvider);
    if (current?.origin == origin && (origin != null || current == null)) return;
    // Switching servers assumes the most recent account on the new one, if any;
    // the previous account's tokens belong to another host.
    final next = origin == null ? null : ref.read(relayAccountsProvider.notifier).accountsOn(origin).firstOrNull;
    await ref
        .read(relaySelectionProvider.notifier)
        .set(origin == null ? null : RelayAccountSelection(origin: origin, account: next?.account));
  }

  /// Back to the hosted server, or — in a build that does not offer it — to no
  /// server at all. Each Server keeps its own sign-in either way.
  Future<void> useDefault() => ref.read(_relayServerActionsProvider).useDefault();

  /// Switches to [server] after the person selects it or agrees to a pairing
  /// code; each Server keeps its own sign-in. Throws [HostLinkError] when
  /// invalid.
  Future<void> useServer(String server) => ref.read(_relayServerActionsProvider).useServer(server);

  /// Switches to [server] (normalized; throws [HostLinkError] when invalid)
  /// and signs in there with email + password.
  Future<void> loginWithPassword({required String server, required String email, required String password}) =>
      ref.read(_relayServerActionsProvider).loginWithPassword(server: server, email: email, password: password);
}

final relayServerProvider = NotifierProvider<RelayServerController, String?>(RelayServerController.new);

/// Every signed-in account, newest first.
final relayAccountsProvider = NotifierProvider<RelayAccountsController, List<RelayAccountEntry>>(
  RelayAccountsController.new,
);

/// The account in use. Its credential slot is what the backend reads.
final relaySelectionProvider = NotifierProvider<RelaySelectionController, RelayAccountSelection?>(
  RelaySelectionController.new,
);

/// The server a Remote call should go to, or null when there is nowhere to go.
///
/// The selection is nullable because the hosted server is the "nothing chosen"
/// case upstream. This build does not offer that server
/// ([hostedRelayServerEnabled]), so a null selection means unsigned-up rather
/// than "use dsh.r2049.cn" — callers must not silently substitute it.
String? resolveRelayServer(String? selection) => selection ?? (hostedRelayServerEnabled ? defaultRelayServer : null);

// Commands need their own Ref: the backend watches the server state, so the
// server notifier cannot read/invalidate its downstream providers. This provider
// does not watch the selection and remains alive when a login sheet closes.
final _relayServerActionsProvider = Provider<_RelayServerActions>(_RelayServerActions.new);

class _RelayServerActions {
  _RelayServerActions(this.ref);

  final Ref ref;
  int _operation = 0;

  bool _owns(int operation, String? selection) =>
      ref.mounted && operation == _operation && ref.read(relayServerProvider) == selection;

  Future<void> useDefault() async {
    final operation = ++_operation;
    await ref.read(relaySelectionProvider.notifier).set(null);
    if (_owns(operation, null)) ref.invalidate(relayAccountProvider);
  }

  Future<void> useServer(String server) async {
    final origin = DshRemoteRelayBackend.normalizeServer(server);
    final selection = origin == defaultRelayServer ? null : origin;
    final operation = ++_operation;
    await ref
        .read(relaySelectionProvider.notifier)
        .set(
          RelayAccountSelection(
            origin: selection ?? defaultRelayServer,
            account: ref.read(relaySelectionProvider)?.account,
          ),
        );
    if (_owns(operation, selection)) ref.invalidate(relayAccountProvider);
  }

  Future<void> loginWithPassword({required String server, required String email, required String password}) async {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    final origin = DshRemoteRelayBackend.normalizeServer(server);
    final selection = origin == defaultRelayServer ? null : origin;
    final operation = ++_operation;
    await ref.read(relayServerProvider.notifier)._set(selection);
    // Persistence may yield to another server action, including A -> B -> A.
    // Never resolve a retired request against the newly selected backend.
    if (!_owns(operation, selection)) {
      throw HostLinkError(HostLinkErrorKind.other, appL10n.remoteSignInCancelled);
    }
    final backend = ref.read(relayBackendProvider);
    await backend.loginWithPassword(email.trim(), password);
    // The captured account may have completed successfully after selection
    // changed. Keep that result, but do not rebuild/cancel its successor login.
    if (_owns(operation, selection) && identical(backend, ref.read(relayBackendProvider))) {
      ref.invalidate(relayAccountProvider);
    }
  }
}

const defaultRelayServer = 'https://dsh.r2049.cn';

/// The relay client (`packages/dsh_remote`) for the chosen server and account.
/// Tests override with a fake; [UnavailableRelayBackend] turns the native relay
/// off.
///
/// Both halves are watched: the origin selects the server, and the account is
/// what the credential slot is keyed on, so switching accounts rebuilds this
/// backend against that account's stored tokens.
final relayBackendProvider = Provider<RelayBackend>((ref) {
  final history = ref.read(remoteCompactHistoryProvider.notifier);
  final selection = ref.watch(relaySelectionProvider);
  final backend = DshRemoteRelayBackend(
    secrets: ref.watch(secretStoreProvider),
    serverUrl: selection?.origin,
    accountKey: selection?.account,
    clientVersion: AppInfo.version.split('+').first,
    // flutter_webrtc has no HarmonyOS implementation: straight to the relay,
    // not two handshakes that fail on the way there.
    peerConnector: ref.watch(webRtcAvailableProvider) ? flutterPeerConnector : null,
    loadCompactHistory: () async {
      await history.ready;
      return ref.read(remoteCompactHistoryProvider);
    },
  );
  ref.listen<bool>(
    remoteCompactHistoryProvider,
    (_, enabled) => backend.compactHistory = enabled,
    fireImmediately: true,
  );
  // The old default-off preference no longer controls automatic transport selection.
  unawaited(
    SharedPreferences.getInstance().then((prefs) => prefs.remove('remote_direct_p2p')).catchError((_) => false),
  );
  ref.onDispose(() => unawaited(backend.close()));
  return backend;
});

/// Opens the login page: a Custom Tab on Android (Google sign-in refuses
/// WebViews), the browser elsewhere.
typedef UrlOpener = Future<bool> Function(Uri url);

final urlOpenerProvider = Provider<UrlOpener>(
  (ref) => (url) async {
    // HarmonyOS's url_launcher answers the in-app mode with a developer's toast.
    if (Platform.operatingSystem == 'ohos') return launchUrl(url, mode: LaunchMode.externalApplication);
    try {
      return await launchUrl(url, mode: LaunchMode.inAppBrowserView);
    } catch (_) {
      return launchUrl(url, mode: LaunchMode.externalApplication);
    }
  },
);

class RelayAccountState {
  const RelayAccountState({
    this.available = false,
    this.server = '',
    this.user,
    this.hosts = const [],
    this.providers = const [],
    this.loggingIn = false,
    this.loginUrl,
    this.refreshing = false,
    this.hostsFailed = false,
    this.error,
  });

  final bool available;
  final String server;
  final RelayUser? user;
  final List<RelayHost> hosts;

  /// Providers the Server offers for browser sign-in ([RelayAuthProvider.id]
  /// is what [RelayAccountController.login] takes).
  final List<RelayAuthProvider> providers;

  /// A browser login is waiting for the account to authorize this device.
  final bool loggingIn;
  final Uri? loginUrl;
  final bool refreshing;

  /// The last host listing failed: [hosts] is stale, or empty without
  /// meaning "no hosts".
  final bool hostsFailed;
  final String? error;

  bool get signedIn => user != null;

  RelayHost? hostById(String id) {
    for (final h in hosts) {
      if (h.id == id) return h;
    }
    return null;
  }

  RelayAccountState copyWith({
    RelayUser? Function()? user,
    List<RelayHost>? hosts,
    List<RelayAuthProvider>? providers,
    bool? loggingIn,
    Uri? Function()? loginUrl,
    bool? refreshing,
    bool? hostsFailed,
    String? Function()? error,
  }) => RelayAccountState(
    available: available,
    server: server,
    user: user != null ? user() : this.user,
    hosts: hosts ?? this.hosts,
    providers: providers ?? this.providers,
    loggingIn: loggingIn ?? this.loggingIn,
    loginUrl: loginUrl != null ? loginUrl() : this.loginUrl,
    refreshing: refreshing ?? this.refreshing,
    hostsFailed: hostsFailed ?? this.hostsFailed,
    error: error != null ? error() : this.error,
  );
}

/// DSH Remote account: login via browser + polling, host list with presence.
class RelayAccountController extends AsyncNotifier<RelayAccountState> {
  RelayLoginSession? _login;
  int _epoch = 0;

  RelayBackend get _backend => ref.read(relayBackendProvider);

  @override
  Future<RelayAccountState> build() async {
    final backend = ref.watch(relayBackendProvider);
    _cancelPendingLogin();
    ref.onDispose(_cancelPendingLogin);
    final base = RelayAccountState(available: backend.available, server: backend.serverLabel);
    if (!backend.available) return base;
    final RelayUser? user;
    try {
      user = await backend.currentUser();
    } catch (_) {
      // Unreadable credentials (or no Keystore, in tests): signed out.
      return base;
    }
    if (user == null) return base.copyWith(providers: await _loginProviders(backend));
    try {
      return base.copyWith(user: () => user, hosts: await backend.listHosts());
    } catch (_) {
      return base.copyWith(user: () => user, hostsFailed: true);
    }
  }

  RelayAccountState get _now => state.value ?? const RelayAccountState();

  bool _isCurrent(int epoch, RelayBackend backend) => ref.mounted && epoch == _epoch && identical(backend, _backend);

  void _cancelPendingLogin() {
    _epoch++;
    final session = _login;
    _login = null;
    session?.cancel();
  }

  Future<void> _signedOut(int epoch, RelayBackend backend) async {
    state = AsyncData(
      _now.copyWith(user: () => null, hosts: const [], loggingIn: false, loginUrl: () => null, refreshing: false),
    );
    final providers = await _loginProviders(backend);
    if (_isCurrent(epoch, backend)) state = AsyncData(_now.copyWith(providers: providers));
  }

  /// The Server's sign-in providers; an unreachable Server (or one too old
  /// to list them) just means the email sign-in path.
  static Future<List<RelayAuthProvider>> _loginProviders(RelayBackend backend) async {
    try {
      return await backend.loginProviders();
    } catch (_) {
      return const [];
    }
  }

  /// Opens the sign-in page of [providerId] (default: the Server's first
  /// provider) and waits for the account to authorize this device.
  Future<void> login({String? providerId}) async {
    if (_now.loggingIn) return;
    final backend = _backend;
    final epoch = ++_epoch;
    ref.read(readListCredentialEpochProvider.notifier).advance();
    state = AsyncData(_now.copyWith(loggingIn: true, error: () => null));
    try {
      final session = await backend.login(providerId: providerId);
      // Cancellation may finish this future before the browser returns, or
      // while an obsolete login is still creating its server session.
      session.completed.ignore();
      if (!_isCurrent(epoch, backend)) {
        session.cancel();
        return;
      }
      _login = session;
      state = AsyncData(_now.copyWith(loginUrl: () => session.loginUrl));
      final opened = await ref.read(urlOpenerProvider)(session.loginUrl);
      if (!_isCurrent(epoch, backend)) return;
      if (!opened) {
        state = AsyncData(_now.copyWith(error: () => appL10n.stateHostBrowserFailed));
      }
      final user = await session.completed;
      if (!_isCurrent(epoch, backend)) return;
      var failed = false;
      final hosts = await backend.listHosts(refresh: true).catchError((Object _) {
        failed = true;
        return const <RelayHost>[];
      });
      if (!_isCurrent(epoch, backend)) return;
      state = AsyncData(
        _now.copyWith(user: () => user, hosts: hosts, hostsFailed: failed, loggingIn: false, loginUrl: () => null),
      );
    } catch (e) {
      if (!_isCurrent(epoch, backend)) return;
      state = AsyncData(
        _now.copyWith(
          loggingIn: false,
          loginUrl: () => null,
          error: () => e is HostLinkError ? e.message : appL10n.stateSignInFailed,
        ),
      );
    } finally {
      if (_isCurrent(epoch, backend)) _login = null;
    }
  }

  void cancelLogin() {
    _cancelPendingLogin();
    state = AsyncData(_now.copyWith(loggingIn: false, loginUrl: () => null));
  }

  Future<void> logout() async {
    final backend = _backend;
    _cancelPendingLogin();
    final epoch = _epoch;
    ref.read(readListCredentialEpochProvider.notifier).advance();
    await backend.logout();
    if (!_isCurrent(epoch, backend)) return;
    unawaited(ref.read(activeHostProvider.notifier).forget((h) => h.kind == HostKind.relay));
    await _signedOut(epoch, backend);
  }

  /// After the relay refused the login: back to the login card if the
  /// account really is signed out.
  Future<void> recheck() async {
    if (_now.loggingIn) return;
    final backend = _backend;
    final epoch = _epoch;
    final RelayUser? user;
    try {
      user = await backend.currentUser();
    } catch (_) {
      return; // unreadable credentials don't prove a sign-out
    }
    if (_isCurrent(epoch, backend) && user == null) await _signedOut(epoch, backend);
  }

  Future<void> refresh() async {
    if (!_now.signedIn) return;
    final backend = _backend;
    final epoch = _epoch;
    state = AsyncData(_now.copyWith(refreshing: true));
    try {
      final hosts = await backend.listHosts(refresh: true);
      if (!_isCurrent(epoch, backend)) return;
      state = AsyncData(_now.copyWith(hosts: hosts, hostsFailed: false, refreshing: false, error: () => null));
    } catch (_) {
      if (!_isCurrent(epoch, backend)) return;
      await recheck();
      if (_isCurrent(epoch, backend)) state = AsyncData(_now.copyWith(refreshing: false, hostsFailed: true));
    }
  }
}

final relayAccountProvider = AsyncNotifierProvider<RelayAccountController, RelayAccountState>(
  RelayAccountController.new,
);
