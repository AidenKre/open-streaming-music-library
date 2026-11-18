// Phase 9 §7.12: the Integrations page (SC-26 view). Renders the
// controller's view, busy flag and message only; every tap calls the
// controller; a control shows exactly when the offer allows it. All
// server-supplied strings are plain Text.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/services/lastfm/lastfm_errors.dart';
import 'package:frontend/ui/integrations/integrations_controller.dart';
import 'package:frontend/ui/integrations/integrations_opt_in.dart';

const _reminder =
    'You can also remove the application under Last.fm settings → '
    'Applications on last.fm.';

class IntegrationsPage extends ConsumerStatefulWidget {
  const IntegrationsPage({super.key});

  @override
  ConsumerState<IntegrationsPage> createState() => _IntegrationsPageState();
}

class _IntegrationsPageState extends ConsumerState<IntegrationsPage> {
  late final IntegrationsControls _controls;

  @override
  void initState() {
    super.initState();
    _controls = ref.read(integrationsControllerFactoryProvider)();
  }

  @override
  void dispose() {
    _controls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Integrations')),
    body: ListenableBuilder(
      listenable: _controls,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [..._body(context), const SizedBox(height: 16), _credit()],
      ),
    ),
  );

  Widget _credit() => Align(
    alignment: Alignment.centerLeft,
    child: KeyedSubtree(
      key: const Key('integrations.credit'),
      child: TextButton(
        onPressed: _controls.openCredit,
        child: const Text('Scrobbling powered by Last.fm'),
      ),
    ),
  );

  List<Widget> _body(BuildContext context) {
    final view = _controls.view;
    switch (view.load) {
      case IntegrationsLoad.loading:
        return const [
          Center(
            child: CircularProgressIndicator(key: Key('integrations.loading')),
          ),
        ];
      case IntegrationsLoad.failed:
        return [
          ?_messageRow(context),
          Text(view.loadError ?? lastfmProblemText(LastfmProblem.failed)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: KeyedSubtree(
              key: const Key('integrations.retry'),
              child: FilledButton(
                onPressed: _controls.refresh,
                child: const Text('Retry'),
              ),
            ),
          ),
        ];
      case IntegrationsLoad.notOffered:
        return [
          ?_messageRow(context),
          Text(lastfmProblemText(LastfmProblem.notOffered)),
        ];
      case IntegrationsLoad.unreachable:
        return [
          ?_messageRow(context),
          Text(lastfmProblemText(LastfmProblem.unreachable)),
        ];
      case IntegrationsLoad.known:
        return _known(context, view);
    }
  }

  List<Widget> _known(BuildContext context, IntegrationsView view) {
    final status = view.status!;
    final offer = view.offer!;
    final busy = _controls.busy;
    final theme = Theme.of(context).textTheme;
    final name = status.accountName;
    final state = status.state;

    String connectLabel() => offer.showReconnect
        ? 'Reconnect'
        : state == LastfmAccountState.awaitingAuthorization
        ? 'Start again'
        : 'Connect Last.fm';

    return [
      if (busy)
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: LinearProgressIndicator(key: Key('integrations.busy')),
        ),
      ?_messageRow(context),
      if (offer.showTurnedOff)
        _note(lastfmProblemText(LastfmProblem.disabled)),
      if (offer.showStopped)
        KeyedSubtree(
          key: const Key('integrations.stopped'),
          child: _note(lastfmProblemText(LastfmProblem.stopped)),
        ),
      if (!view.online)
        _note(
          "You're offline. Changing your Last.fm connection needs your "
          'server.',
        ),
      if (offer.showReconnect)
        KeyedSubtree(
          key: const Key('integrations.reconnect'),
          child: _note(
            'Last.fm no longer accepts this connection. Reconnect to keep '
            'scrobbling.',
          ),
        ),
      if (state == LastfmAccountState.unknown ||
          status.service == LastfmServerState.unknown)
        _note(lastfmProblemText(LastfmProblem.badAnswer)),
      if (offer.canFinish)
        _note(
          'Approve the access on last.fm, then come back and tap Finish '
          'connecting.',
        ),
      if (status.isConnected) ...[
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              state == LastfmAccountState.enabled
                  ? 'Scrobbling to'
                  : 'Connected to',
            ),
            const SizedBox(width: 4),
            if (name != null)
              KeyedSubtree(
                key: const Key('integrations.profile'),
                child: TextButton(
                  onPressed: _controls.openProfile,
                  child: Text(name),
                ),
              )
            else
              const Text('your Last.fm account'),
          ],
        ),
        if (state == LastfmAccountState.connectedDisabled &&
            !offer.canOptIn)
          _note('Connected, not scrobbling yet.'),
      ],
      if (offer.canOptIn && name != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: IntegrationsOptIn(
            accountName: name,
            appName: status.appName,
            busy: busy,
            onConfirm: _controls.enable,
            onTerms: _controls.openTerms,
            onPrivacy: _controls.openPrivacy,
          ),
        ),
      Wrap(
        spacing: 8,
        children: [
          if (offer.canConnect)
            KeyedSubtree(
              key: const Key('integrations.connect'),
              child: FilledButton(
                onPressed: busy ? null : _controls.connect,
                child: Text(connectLabel()),
              ),
            ),
          if (offer.canFinish)
            KeyedSubtree(
              key: const Key('integrations.finish'),
              child: FilledButton(
                onPressed: busy ? null : _controls.finish,
                child: const Text('Finish connecting'),
              ),
            ),
          if (offer.canDisconnect)
            KeyedSubtree(
              key: const Key('integrations.disconnect'),
              child: OutlinedButton(
                onPressed: busy ? null : () => _confirmDisconnect(context),
                child: const Text('Disconnect'),
              ),
            ),
        ],
      ),
      if (status.isConnected) ...[
        const SizedBox(height: 8),
        const Text(_reminder),
        const SizedBox(height: 16),
        _counts(status),
        if (status.lastSuccessAt != null)
          Padding(
            key: const Key('integrations.lastSuccess'),
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Last went through: ${_date(status.lastSuccessAt!)}',
            ),
          ),
        const SizedBox(height: 16),
        Text("Didn't go through", style: theme.titleMedium),
        if (view.problems.isEmpty)
          const Text('None in the last 30 days.')
        else
          for (final (i, p) in view.problems.indexed)
            ListTile(
              key: Key('integrations.problem.$i'),
              contentPadding: EdgeInsets.zero,
              title: Text(p.track),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${p.artist} · ${_date(p.listenedAt)}'),
                  Text(p.reason),
                ],
              ),
            ),
      ],
    ];
  }

  /// The last action's outcome, shown in every branch that has one.
  Widget? _messageRow(BuildContext context) {
    final message = _controls.message;
    if (message == null) return null;
    return Padding(
      key: const Key('integrations.message'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }

  Widget _note(String text) =>
      Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(text));

  Widget _counts(LastfmStatus status) {
    final c = status.counts;
    String n(int? v) => v == null ? 'Unknown' : '$v';
    Widget row(String kind, String label, int? v) => Row(
      key: Key('integrations.count.$kind'),
      children: [
        Expanded(child: Text(label)),
        Text(n(v)),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('pending', 'Waiting', c.pending),
        row('sent', 'Sent', c.sent),
        row('ignored', 'Ignored', c.ignored),
        row('failed', 'Refused', c.failed),
        row('dropped', 'Not sent', c.dropped),
        const SizedBox(height: 4),
        const Text('Counts cover the last 30 days.'),
      ],
    );
  }

  String _date(int ms) => DateFormat(
    'd MMM y, HH:mm',
  ).format(DateTime.fromMillisecondsSinceEpoch(ms));

  Future<void> _confirmDisconnect(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect Last.fm?'),
        content: const Text(
          'Scrobbles still waiting are discarded. Coming back needs a new '
          'approval and a new confirmation. $_reminder',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          KeyedSubtree(
            key: const Key('integrations.disconnect.confirm'),
            child: FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Disconnect'),
            ),
          ),
        ],
      ),
    );
    if (ok == true) await _controls.disconnect();
  }
}
