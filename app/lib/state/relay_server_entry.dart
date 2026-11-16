import 'dart:convert';

import '../links/removed_links.dart' show hostedRelayServerEnabled;

/// The DSH Remote server the app talks to when nothing else is chosen.
///
/// Duplicated from `hosts_state.dart` rather than imported: that file imports
/// this one, and `isDefault` only needs the literal.
const String defaultRelayServerOrigin = 'https://dsh.r2049.cn';

/// Marker for [RelayAccountEntry.copyWith]'s `label`.
///
/// Two `const Object()` values canonicalize to the same instance, so a bare
/// sentinel cannot distinguish "argument omitted" from "clear the label".
final class _ClearLabel {
  const _ClearLabel();
}

const Object _unset = _Unset();
const Object _clearLabel = _ClearLabel();

final class _Unset {
  const _Unset();
}

/// One signed-in account on one DSH Remote server.
///
/// A server can hold several accounts, and each has its own credentials: the
/// storage scope in `packages/dsh_remote` is derived from the origin *and* the
/// account, so switching between them does not sign one out to reach the other.
/// This record is the shortcut that makes them reachable — the tokens stay in
/// secure storage under that scope.
class RelayAccountEntry {
  const RelayAccountEntry({required this.origin, required this.account, this.label, this.provider, this.lastUsed});

  /// Normalized origin, exactly as `DshRemoteRelayBackend.normalizeServer`
  /// returns it and as the storage scope is derived from.
  final String origin;

  /// The account name the server reports: an email for password sign-in, an
  /// account id for the OAuth providers. Empty for a row migrated from a
  /// version that did not record accounts — such a row carries only the
  /// address until the person signs in on it.
  final String account;

  /// What the person called it, when they typed a name.
  final String? label;

  /// The sign-in method last used here (`password`, `github`, ...). Null for
  /// rows written before it was tracked.
  final String? provider;

  final DateTime? lastUsed;

  /// Identity of the row: one person per server is one row.
  String get id => '$origin\n${account.trim().toLowerCase()}';

  /// A migrated row that cannot address a credential slot yet.
  bool get needsAccount => account.trim().isEmpty;

  bool get isDefaultServer => hostedRelayServerEnabled && origin == defaultRelayServerOrigin;

  /// The address without its scheme, for compact rows.
  String get hostLabel {
    final uri = Uri.tryParse(origin);
    return uri == null ? origin : uri.authority;
  }

  String get displayName {
    if (label != null && label!.trim().isNotEmpty) return label!.trim();
    if (needsAccount) return hostLabel;
    return account;
  }

  RelayAccountEntry copyWith({
    /// The new label, or [clearLabel] to remove it. Omitting keeps the current
    /// one; a plain `String?` cannot express "clear it".
    Object? label = _unset,
    String? Function()? provider,
    DateTime? lastUsed,
  }) {
    final String? nextLabel;
    if (identical(label, _unset)) {
      nextLabel = this.label;
    } else if (identical(label, _clearLabel) || label == null) {
      nextLabel = null;
    } else {
      nextLabel = label as String;
    }
    return RelayAccountEntry(
      origin: origin,
      account: account,
      label: nextLabel,
      provider: provider != null ? provider() : this.provider,
      lastUsed: lastUsed ?? this.lastUsed,
    );
  }

  /// Sentinel for [copyWith]'s `label`, meaning "remove the label".
  static const Object clearLabel = _clearLabel;

  /// Sets the label, or removes it when [value] is null or blank.
  RelayAccountEntry withLabel(String? value) {
    final trimmed = value?.trim();
    return copyWith(label: (trimmed == null || trimmed.isEmpty) ? clearLabel : trimmed);
  }

  Map<String, Object?> toJson() => {
    'origin': origin,
    'account': account,
    if (label != null) 'label': label,
    if (provider != null) 'provider': provider,
    if (lastUsed != null) 'lastUsed': lastUsed!.toIso8601String(),
  };

  static RelayAccountEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final origin = raw['origin'];
    if (origin is! String || origin.isEmpty) return null;
    final account = raw['account'];
    // An absent account is a migrated row, not a broken one.
    final label = raw['label'];
    final provider = raw['provider'];
    final lastUsed = raw['lastUsed'];
    return RelayAccountEntry(
      origin: origin,
      account: account is String ? account : '',
      label: label is String && label.isNotEmpty ? label : null,
      provider: provider is String && provider.isNotEmpty ? provider : null,
      lastUsed: lastUsed is String ? DateTime.tryParse(lastUsed) : null,
    );
  }

  /// Decodes a stored list, dropping anything unreadable and collapsing
  /// duplicates to the first occurrence.
  static List<RelayAccountEntry> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    final entries = <RelayAccountEntry>[];
    final seen = <String>{};
    for (final item in decoded) {
      final entry = fromJson(item);
      if (entry == null || !seen.add(entry.id)) continue;
      entries.add(entry);
    }
    return entries;
  }

  static String encodeList(List<RelayAccountEntry> entries) => jsonEncode([for (final e in entries) e.toJson()]);

  /// Reads the server-only list an earlier version wrote
  /// (`remote_relay_servers`): one row per server, with the last account seen
  /// on it rather than one row per account.
  static List<LegacyServerRow> decodeLegacyServers(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    final out = <LegacyServerRow>[];
    final seen = <String>{};
    for (final item in decoded) {
      if (item is! Map) continue;
      final origin = item['origin'];
      if (origin is! String || origin.isEmpty || !seen.add(origin)) continue;
      final label = item['label'];
      final account = item['account'];
      final lastUsed = item['lastUsed'];
      out.add(
        LegacyServerRow(
          origin: origin,
          label: label is String && label.isNotEmpty ? label : null,
          account: account is String && account.isNotEmpty ? account : null,
          lastUsed: lastUsed is String ? DateTime.tryParse(lastUsed) : null,
        ),
      );
    }
    return out;
  }
}

/// One row of the server-only list an earlier version stored.
class LegacyServerRow {
  const LegacyServerRow({required this.origin, this.label, this.account, this.lastUsed});

  final String origin;
  final String? label;

  /// The account last seen on this server, if one was recorded.
  final String? account;

  final DateTime? lastUsed;
}
