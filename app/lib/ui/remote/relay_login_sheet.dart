import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/hosts_state.dart';
import '../../state/relay_server_entry.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Without an explicit origin, open the saved accounts first. An explicit
/// add or re-login starts on the form. Only a new password sign-in returns
/// true; using an existing account or choosing a server returns false.
Future<bool?> showSelfHostedLogin(
  BuildContext context, {
  String? initialServer,
  String? initialEmail,
  bool addServer = false,
}) async {
  if (initialServer == null && !addServer) {
    final container = ProviderScope.containerOf(context, listen: false);
    await container.read(relayAccountsProvider.notifier).ready;
    if (!context.mounted) return null;
  }
  return showAppSheet<bool>(
    context,
    dismissal: SheetDismissal.button,
    isScrollControlled: true,
    builder: (_) =>
        SelfHostedLoginSheet(initialServer: initialServer, initialEmail: initialEmail, addServer: addServer),
  );
}

class SelfHostedLoginSheet extends ConsumerStatefulWidget {
  const SelfHostedLoginSheet({super.key, this.initialServer, this.initialEmail, this.addServer = false});

  final String? initialServer;
  final String? initialEmail;
  final bool addServer;

  @override
  ConsumerState<SelfHostedLoginSheet> createState() => _SelfHostedLoginSheetState();
}

class _SelfHostedLoginSheetState extends ConsumerState<SelfHostedLoginSheet> {
  late final _server = TextEditingController(text: widget.initialServer ?? '');
  late final _email = TextEditingController(text: widget.initialEmail ?? '');
  final _password = TextEditingController();
  late bool _editing = widget.addServer || widget.initialServer != null;
  late bool _fixedServer = widget.initialServer != null;
  bool _needsSignIn = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _edit({String? origin, String? email, bool needsSignIn = false}) {
    setState(() {
      _editing = true;
      _fixedServer = origin != null;
      _needsSignIn = needsSignIn;
      _error = null;
      _server.text = origin ?? '';
      _email.text = email ?? '';
      _password.clear();
    });
  }

  void _backToAccounts() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _editing = false;
      _error = null;
      _password.clear();
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e is HostLinkError ? e.message : context.l10n.remoteErrSignIn);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _switchTo(List<RelayAccountEntry> entries) => _run(() async {
    final switched = await ref.read(relayServerProvider.notifier).useSavedAccounts(entries);
    if (!mounted) return;
    if (switched) {
      Navigator.of(context).pop(false);
    } else {
      // This is the only saved-row path to the form; a usable session never
      // turns into prefilled fields or a request to enter the password again.
      final entry = entries.first;
      _edit(origin: entry.origin, email: entry.account, needsSignIn: !entry.needsAccount);
    }
  });

  Future<void> _submit({bool withPassword = true}) async {
    if (_busy) return;
    final origin = _server.text.trim();
    final email = _email.text.trim();
    final password = _password.text;
    if (origin.isEmpty || (withPassword && (email.isEmpty || password.isEmpty))) {
      setState(() {
        _error = origin.isEmpty ? context.l10n.remoteErrInvalidServer : context.l10n.remoteRelayLoginRequired;
      });
      return;
    }
    await _run(() async {
      final relay = ref.read(relayServerProvider.notifier);
      if (withPassword) {
        await relay.loginWithPassword(server: origin, email: email, password: password);
      } else {
        await relay.useServer(origin);
      }
      if (mounted) Navigator.of(context).pop(withPassword);
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
    final byOrigin = <String, List<RelayAccountEntry>>{};
    for (final entry in saved) {
      (byOrigin[entry.origin] ??= []).add(entry);
    }
    final editing = _editing || saved.isEmpty;
    final error = _error ?? (editing && _needsSignIn ? l10n.remoteAccountMissing : null);
    return PopScope(
      canPop: !_busy,
      child: Padding(
        padding: EdgeInsets.only(bottom: insets),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetTitleBar(editing ? l10n.remoteSelfHostedServer : l10n.remoteSignedInAccounts),
                Padding(
                  padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 16),
                  child: editing
                      ? AutofillGroup(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: 12,
                            children: [
                              if (saved.isNotEmpty)
                                Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: TextButton.icon(
                                    onPressed: _busy ? null : _backToAccounts,
                                    icon: const Icon(AppIcons.back, size: 18),
                                    label: Text(l10n.remoteSignedInAccounts),
                                  ),
                                ),
                              if (!_fixedServer)
                                Text(
                                  l10n.remoteSelfHostedSignInHelp,
                                  style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
                                ),
                              TextField(
                                key: const ValueKey('relay-server-address'),
                                controller: _server,
                                enabled: !_busy,
                                readOnly: _fixedServer,
                                keyboardType: TextInputType.url,
                                autocorrect: false,
                                textInputAction: TextInputAction.next,
                                style: AppType.mono(size: 14, color: theme.colorScheme.onSurface, height: 1.4),
                                decoration: InputDecoration(
                                  labelText: l10n.remoteServerAddress,
                                  hintText: 'https://remote.example.com',
                                ),
                              ),
                              TextField(
                                key: const ValueKey('relay-server-email'),
                                controller: _email,
                                enabled: !_busy,
                                keyboardType: TextInputType.emailAddress,
                                autocorrect: false,
                                textInputAction: TextInputAction.next,
                                autofillHints: const [AutofillHints.username],
                                decoration: InputDecoration(labelText: l10n.remoteEmail),
                              ),
                              TextField(
                                key: const ValueKey('relay-server-password'),
                                controller: _password,
                                enabled: !_busy,
                                obscureText: true,
                                autocorrect: false,
                                enableSuggestions: false,
                                textInputAction: TextInputAction.done,
                                autofillHints: const [AutofillHints.password],
                                onSubmitted: (_) => _submit(),
                                decoration: InputDecoration(labelText: l10n.remotePassword),
                              ),
                              if (error != null) _message(context, error),
                              FilledButton(
                                onPressed: _busy ? null : _submit,
                                child: _busy
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : Text(l10n.commonSignIn),
                              ),
                              if (!_fixedServer)
                                TextButton(
                                  onPressed: _busy ? null : () => _submit(withPassword: false),
                                  child: Text(l10n.remoteUseServer),
                                ),
                            ],
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: 8,
                          children: [
                            for (final group in byOrigin.entries) ...[
                              Row(
                                children: [
                                  Expanded(
                                    child: TextButton.icon(
                                      onPressed: _busy ? null : () => _switchTo(group.value),
                                      style: TextButton.styleFrom(alignment: AlignmentDirectional.centerStart),
                                      icon: const Icon(AppIcons.cloud, size: 18),
                                      label: Text(group.key, maxLines: 2, overflow: TextOverflow.ellipsis),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: _busy ? null : () => _edit(origin: group.key),
                                    icon: const Icon(AppIcons.add, size: 20),
                                    tooltip: l10n.remoteAddAccountHere,
                                  ),
                                ],
                              ),
                              for (final entry in group.value)
                                ListTile(
                                  key: ValueKey('relay-saved-${entry.id}'),
                                  contentPadding: const EdgeInsetsDirectional.only(start: 8),
                                  selected: selection?.id == entry.id,
                                  leading: Icon(selection?.id == entry.id ? AppIcons.done : AppIcons.cloud, size: 20),
                                  title: Text(entry.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  onTap: _busy ? null : () => _switchTo([entry]),
                                  trailing: IconButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _run(() => ref.read(relayAccountsProvider.notifier).forget(entry.id)),
                                    icon: const Icon(AppIcons.remove, size: 18),
                                    tooltip: l10n.remoteForgetServer,
                                  ),
                                ),
                            ],
                            if (error != null) _message(context, error),
                            if (_busy) const LinearProgressIndicator(),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : () => _edit(),
                              icon: const Icon(AppIcons.add, size: 18),
                              label: Text(l10n.remoteAddServer),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _message(BuildContext context, String text) =>
      Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).danger));
}
