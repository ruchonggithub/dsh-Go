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

/// Sign in to a DSH Remote server, or switch to an account already signed in.
///
/// Returns true only after a password sign-in actually happened, not after
/// merely switching to an account that was already signed in.
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

  /// The saved account row being signed in to or switched to; null when the
  /// address was typed by hand.
  String? _chosenId;

  /// The address form is open because the person is adding an account.
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

  /// The origin a submit would act on: the chosen row, or what was typed.
  String get _target => (_server.text).trim();

  /// Switches to an account that is already signed in. Its tokens are in
  /// secure storage under that account's scope, so no password is needed.
  Future<void> _switchTo(RelayAccountEntry entry) async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(relaySelectionProvider.notifier)
          .set(RelayAccountSelection(origin: entry.origin, account: entry.account));
      // Move to the front: the list is ordered by use.
      await ref
          .read(relayAccountsProvider.notifier)
          .remember(entry.origin, entry.account, label: entry.label, provider: entry.provider);
      if (mounted) Navigator.of(context).pop(false);
    } catch (e) {
      if (mounted) setState(() => _error = e is HostLinkError ? e.message : context.l10n.remoteErrSignIn);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _login({bool withPassword = true}) async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_target.isEmpty || (withPassword && (_email.text.trim().isEmpty || _password.text.isEmpty))) {
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
        final email = _email.text.trim();
        await server.loginWithPassword(server: _target, email: email, password: _password.text);
        // The account name is what the credential slot is keyed on, so record
        // it before anything else can overwrite that slot.
        final origin = ref.read(relayServerProvider) ?? defaultRelayServer;
        await ref.read(relayAccountsProvider.notifier).remember(origin, email, provider: 'password');
      } else {
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

  Future<void> _forget(RelayAccountEntry entry) async {
    if (_busy) return;
    await ref.read(relayAccountsProvider.notifier).forget(entry.id);
    if (!mounted) return;
    if (_chosenId == entry.id) setState(() => _chosenId = null);
  }

  /// Starts a fresh sign-in on an existing row's server: the point of a second
  /// account is that the first one stays signed in.
  void _addAccountOn(String origin) {
    setState(() {
      _chosenId = null;
      _adding = true;
      _error = null;
      _server.text = origin;
      _email.clear();
      _password.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final saved = ref.watch(relayAccountsProvider);
    final selection = ref.watch(relaySelectionProvider);
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final chosen = _chosenId == null ? null : saved.where((e) => e.id == _chosenId).firstOrNull;

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
              // Signed-in accounts first: switching is the common action once
              // there is more than one.
              if (saved.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 4),
                  child: Text(
                    l10n.remoteSignedInAccounts,
                    style: theme.textTheme.labelMedium?.copyWith(color: colors.textTertiary),
                  ),
                ),
              for (final entry in saved)
                _AccountRow(
                  entry: entry,
                  active: selection != null && selection.id == entry.id,
                  busy: _busy,
                  onSwitch: () => _switchTo(entry),
                  onAddAnother: entry.needsAccount ? null : () => _addAccountOn(entry.origin),
                  onForget: () => _forget(entry),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 8, SheetTitleBar.inset, 0),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _adding = !_adding;
                            _chosenId = null;
                            _error = null;
                            if (_adding) {
                              _server.clear();
                              _email.clear();
                              _password.clear();
                            }
                          }),
                    icon: Icon(_adding ? AppIcons.collapse : AppIcons.add, size: 18),
                    label: Text(_adding ? l10n.commonCancel : l10n.remoteAddServer),
                  ),
                ),
              ),
              // The address field stays available: this sheet is also how a
              // server gets added at all.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: SheetTitleBar.inset),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    TextField(
                      key: const ValueKey('relay-server-address'),
                      controller: _server,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      style: AppType.mono(size: 14, color: theme.colorScheme.onSurface, height: 1.4),
                      decoration: InputDecoration(
                        labelText: l10n.remoteServerAddress,
                        hintText: 'https://remote.example.com',
                        helperText: chosen?.account.trim().isNotEmpty ?? false
                            ? l10n.remoteLastAccount(chosen!.account)
                            : null,
                      ),
                    ),
                    TextField(
                      key: const ValueKey('relay-server-email'),
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      decoration: InputDecoration(labelText: l10n.remoteEmail, helperText: l10n.remoteEmailIsAccount),
                    ),
                    TextField(
                      key: const ValueKey('relay-server-password'),
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

/// One signed-in account: who it is, where, and what can be done with it.
class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.entry,
    required this.active,
    required this.busy,
    required this.onSwitch,
    required this.onAddAnother,
    required this.onForget,
  });

  final RelayAccountEntry entry;
  final bool active;
  final bool busy;
  final VoidCallback onSwitch;

  /// Null when the row cannot hold an account yet (a migrated address-only
  /// row); adding another account there is the same as signing in on it.
  final VoidCallback? onAddAnother;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final subtitle = [
      entry.hostLabel,
      if (entry.provider != null) entry.provider!,
      if (entry.needsAccount) l10n.remoteAccountMissing,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 8),
      child: Material(
        color: active ? theme.colorScheme.surfaceContainerHighest : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: busy ? null : onSwitch,
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
                if (onAddAnother != null)
                  IconButton(
                    onPressed: busy ? null : onAddAnother,
                    icon: const Icon(AppIcons.add, size: 18),
                    color: colors.textTertiary,
                    tooltip: l10n.remoteAddAccountHere,
                    visualDensity: VisualDensity.compact,
                  ),
                IconButton(
                  onPressed: busy ? null : onForget,
                  icon: const Icon(AppIcons.remove, size: 18),
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
