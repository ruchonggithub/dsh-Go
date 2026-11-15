import 'dart:convert';

/// Marker type for [RelayServerEntry.copyWith]'s `label` argument.
///
/// Two `const Object()` values are canonicalized to the same instance, so
/// `identical()` cannot tell "argument omitted" from "clear the label" with a
/// bare sentinel. Distinct subclasses can.
sealed class _LabelArg {
  const _LabelArg();
}

final class _Unset extends _LabelArg {
  const _Unset();
}

final class _Clear extends _LabelArg {
  const _Clear();
}

const _LabelArg _unset = _Unset();

/// Default for a [RelayServerEntry.copyWith] argument that was not passed.
const _LabelArg _clearLabel = _Clear();

/// The DSH Remote server the app talks to when nothing else is chosen.
///
/// Duplicated from `hosts_state.dart` rather than imported: that file imports
/// this one, and `isDefault` only needs the literal.
const String defaultRelayServerOrigin = 'https://dsh.r2049.cn';

/// One DSH Remote server the person has used, with its own sign-in.
///
/// Credentials are already kept per server inside `packages/dsh_remote`
/// (the storage key is scoped by a hash of the origin), so remembering the
/// list here only needs the address and a display hint: signing back in to a
/// server that was signed in before is immediate.
class RelayServerEntry {
  const RelayServerEntry({required this.origin, this.label, this.account, this.lastUsed});

  /// Normalized origin, exactly as [DshRemoteRelayBackend.normalizeServer]
  /// returns it and as `_scope` in `packages/dsh_remote` is derived from.
  final String origin;

  /// What the person called it, when they typed a name. Falls back to the
  /// host's label from the address.
  final String? label;

  /// The account name last signed in here, for the list subtitle. Null when
  /// this server was only selected, never signed in to.
  final String? account;

  final DateTime? lastUsed;

  bool get isDefault => origin == defaultRelayServerOrigin;

  /// The address without its scheme, for compact rows.
  String get hostLabel {
    final uri = Uri.tryParse(origin);
    return uri == null ? origin : uri.authority;
  }

  String get displayName => (label != null && label!.trim().isNotEmpty) ? label!.trim() : hostLabel;

  RelayServerEntry copyWith({
    /// The new label, a `String`, or one of the [_LabelArg] markers. Pass
    /// [clearLabel] to remove it; omitting the argument keeps the current one.
    /// A plain `String?` cannot express "clear it", because `null` already
    /// means "leave it alone".
    Object? label = _unset,
    String? Function()? account,
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
    return RelayServerEntry(
      origin: origin,
      label: nextLabel,
      account: account != null ? account() : this.account,
      lastUsed: lastUsed ?? this.lastUsed,
    );
  }

  /// Sentinel for [copyWith]'s `label`, meaning "remove the label".
  static const Object clearLabel = _clearLabel;

  /// Sets the label, or removes it when [value] is null or blank.
  RelayServerEntry withLabel(String? value) {
    final trimmed = value?.trim();
    return copyWith(label: (trimmed == null || trimmed.isEmpty) ? clearLabel : trimmed);
  }

  Map<String, Object?> toJson() => {
    'origin': origin,
    if (label != null) 'label': label,
    if (account != null) 'account': account,
    if (lastUsed != null) 'lastUsed': lastUsed!.toIso8601String(),
  };

  static RelayServerEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final origin = raw['origin'];
    if (origin is! String || origin.isEmpty) return null;
    final label = raw['label'];
    final account = raw['account'];
    final lastUsed = raw['lastUsed'];
    return RelayServerEntry(
      origin: origin,
      label: label is String && label.isNotEmpty ? label : null,
      account: account is String && account.isNotEmpty ? account : null,
      lastUsed: lastUsed is String ? DateTime.tryParse(lastUsed) : null,
    );
  }

  /// Decodes a stored list, dropping anything unreadable. A single bare string
  /// is accepted so a partially migrated value never loses the server.
  static List<RelayServerEntry> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
    if (decoded is String) {
      final entry = RelayServerEntry(origin: decoded);
      return entry.origin.isEmpty ? const [] : [entry];
    }
    if (decoded is! List) return const [];
    final entries = <RelayServerEntry>[];
    final seen = <String>{};
    for (final item in decoded) {
      final entry = fromJson(item);
      if (entry == null || !seen.add(entry.origin)) continue;
      entries.add(entry);
    }
    return entries;
  }

  static String encodeList(List<RelayServerEntry> entries) => jsonEncode([for (final e in entries) e.toJson()]);
}
