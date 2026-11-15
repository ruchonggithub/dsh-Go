import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/hosts_state.dart';
import '../../state/relay_server_entry.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Select a saved DSH Remote server, add a new one, or sign in with email and
/// password. Returns true only after password sign-in, not after selecting a
/// server.
Future<bool?> showSelfHostedLogin(BuildContext context, {String? initialServer}) {
  return showAppSheet<bool>(
    context,
    dismissal: SheetDismissal.button,
    isScrollControlled: true,
    builder: (_) => SelfHostedLoginSheet(initialServer: initialServer),
  );
}

class SelfHostedLoginSheet extends ConsumerStatefulWidget {
  const SelfHostedLoginSheet({super.key, this.initialServer});

  final String? initialServer;

  @override
  ConsumerState<SelfHostedLoginSheet> createState() => _SelfHostedLoginSheetState();
}

class _SelfHostedLoginSheetState extends ConsumerState<SelfHostedLoginSheet> {
  late final _server = TextEditingController(text: widget.initialServer ?? ref.read(relayServerProvider) ?? '');
  final _email = TextEditingController();
  final _password = TextEditingController();

  /// The saved row being signed in to; null when the address was typed.
  String? _chosen;

  /// The address form is open because the person is adding a server.
  bool _adding = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // A pre-filled address means the caller wants that server, not the list.
    _adding = (widget.initialServer ?? '').trim().isNotEmpty;
  }

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  /// The origin a submit would act on: what was typed, or the row chosen from
  /// the saved list when the address field is showing it read-only.
  String get _target => (_chosen ?? _server.text).trim();

  Future<void> _signInSaved(RelayServerEntry entry) async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _chosen = entry.origin;
    });
    try {
      final server = ref.read(relayServerProvider.notifier);
      // Already signed in on this server? Selecting it restores that session;
      // the account panel asks for a password only when the token is gone.
      await server.useServer(entry.origin);
      if (mounted) Navigator.of(context).pop(false);
    } on HostLinkError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.remoteErrSignIn);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _login({bool withPassword = true}) async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (withPassword && (_target.isEmpty || _email.text.trim().isEmpty || _password.text.isEmpty)) {
      setState(() => _error = context.l10n.remoteRelayLoginRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final server = ref.read(relayServerProvider.notifier);
      if (withPassword) {
        await server.loginWithPassword(server: _target, email: _email.text, password: _password.text);
        // Remembering which account signed in where is bookkeeping for the
        // next visit: it must not delay closing the sheet or turn a successful
        // sign-in into a failure.
        final origin = ref.read(relayServerProvider);
        if (origin != null && origin != defaultRelayServer) {
          unawaited(
            ref.read(relayServersProvider.notifier).noteAccount(origin, _email.text.trim()).catchError((Object _) {}),
          );
        }
      } else {
        // An empty or invalid address is reported by the normalizer, so the
        // person sees the same message whichever button they used.
        await server.useServer(_target);
      }
      if (mounted) Navigator.of(context).pop(withPassword);
    } on HostLinkError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = context.l10n.remoteErrSignIn);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget(RelayServerEntry entry) async {
    if (_busy) return;
    await ref.read(relayServersProvider.notifier).forget(entry.origin);
    if (!mounted) return;
    if (_chosen == entry.origin) setState(() => _chosen = null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final saved = ref.watch(relayServersProvider);
    final current = ref.watch(relayServerProvider);
    // The server in use is always offered, even on a fresh install where the
    // list has not recorded it yet. That keeps this sheet useful without a
    // write racing the selection.
    final rows = <RelayServerEntry>[
      if (current != null && current != defaultRelayServer && saved.every((e) => e.origin != current))
        RelayServerEntry(origin: current),
      ...saved,
    ];
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    // The address field stays on screen: this sheet is where a server is typed,
    // and the saved rows above are a shortcut, not a replacement for it.
    final chosenEntry = _chosen == null ? null : saved.where((e) => e.origin == _chosen).firstOrNull;
    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.remoteSelfHostedServer),
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 16),
                child: Text(
                  l10n.remoteSelfHostedSignInHelp,
                  style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
                ),
              ),
              if (rows.isNotEmpty)
                for (final entry in rows)
                  _ServerRow(
                    entry: entry,
                    selected: entry.origin == _chosen,
                    active: entry.origin == current,
                    busy: _busy,
                    onTap: () {
                      // Tapping an already-chosen row signs in to it.
                      if (_chosen == entry.origin) {
                        _signInSaved(entry);
                      } else {
                        setState(() {
                          _chosen = entry.origin;
                          _adding = false;
                          _error = null;
                        });
                        _server.text = entry.origin;
                      }
                    },
                    onForget: () => _forget(entry),
                  ),
              if (rows.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 8, SheetTitleBar.inset, 0),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _adding = !_adding;
                              _chosen = null;
                              _error = null;
                              if (_adding) _server.clear();
                            }),
                      icon: Icon(_adding ? AppIcons.collapse : AppIcons.add, size: 18),
                      label: Text(_adding ? l10n.commonCancel : l10n.remoteAddServer),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: SheetTitleBar.inset),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    TextField(
                      controller: _server,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      style: AppType.mono(size: 14, color: theme.colorScheme.onSurface, height: 1.4),
                      // Always editable: picking a saved row fills this in, and
                      // editing it switches to whatever was typed.
                      decoration: InputDecoration(
                        labelText: l10n.remoteServerAddress,
                        hintText: 'https://remote.example.com',
                        helperText: chosenEntry?.account == null
                            ? null
                            : l10n.remoteLastAccount(chosenEntry!.account!),
                      ),
                    ),
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      decoration: InputDecoration(labelText: l10n.remoteEmail),
                    ),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      obscuringCharacter: '•',
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _login(),
                      decoration: InputDecoration(labelText: l10n.remotePassword),
                    ),
                    if (_error case final e?) Text(e, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
                    FilledButton(
                      onPressed: _busy ? null : _login,
                      child: _busy
                          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(l10n.commonSignIn),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => _login(withPassword: false),
                      child: Text(l10n.remoteUseServer),
                    ),
                    if (current != null && saved.every((e) => e.origin != current))
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                final navigator = Navigator.of(context);
                                await ref.read(relayServerProvider.notifier).useDefault();
                                navigator.pop();
                              },
                        child: Text(l10n.remoteRestoreServer),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// One saved server: address, the account last used there, and a way to
/// forget the shortcut.
class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.entry,
    required this.selected,
    required this.active,
    required this.busy,
    required this.onTap,
    required this.onForget,
  });

  final RelayServerEntry entry;
  final bool selected;
  final bool active;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final subtitle = [
      if (entry.isDefault) l10n.remoteServerHosted else entry.hostLabel,
      if (entry.account != null) entry.account!,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 8),
      child: Material(
        color: selected ? theme.colorScheme.surfaceContainerHighest : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(
              children: [
                Icon(
                  active ? AppIcons.done : AppIcons.cloud,
                  size: 20,
                  color: active ? theme.colorScheme.primary : colors.textTertiary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.displayName,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: AppType.mono(size: 12, color: colors.textTertiary, height: 1.3),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: busy ? null : onForget,
                  icon: Icon(AppIcons.remove, size: 18),
                  color: colors.textTertiary,
                  tooltip: l10n.remoteForgetServer,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
