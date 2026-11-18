// Phase 9 spec §7.5: the opt-in confirmation. States the seven points in
// plain words; nothing is sent until the explicit tap on "Start scrobbling".
// The application is named from the status `app_name` (operator setting
// LASTFM_APP_NAME) in points 1, 6 and 7; without it the wording is unchanged
// ("the application you approved on last.fm").
import 'package:flutter/material.dart';

class IntegrationsOptIn extends StatelessWidget {
  const IntegrationsOptIn({
    super.key,
    required this.accountName,
    this.appName,
    required this.busy,
    required this.onConfirm,
    required this.onTerms,
    required this.onPrivacy,
  });

  final String accountName;
  final String? appName;
  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback onTerms;
  final VoidCallback onPrivacy;

  Widget _point(
    BuildContext context,
    int n,
    String title,
    String body, {
    List<Widget> extra = const [],
  }) {
    final theme = Theme.of(context).textTheme;
    return Padding(
      key: Key('integrations.optIn.point.$n'),
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.titleSmall),
          const SizedBox(height: 2),
          Text(body),
          ...extra,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final app = appName == null
        ? 'the application'
        : 'the application “$appName”';
    return Column(
      key: const Key('integrations.optIn'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Scrobble to $accountName?', style: theme.titleMedium),
        const SizedBox(height: 4),
        const Text('Nothing is sent until you confirm.'),
        _point(
          context,
          1,
          'What is sent',
          'For each listen that counts: the artist, title, album, album '
              'artist, track length and the time it started; and, while you '
              'listen online, the track that is playing now. No files, no '
              'list of your library, and not your OSML username. Last.fm '
              'also sees this server’s network address and $app '
              'you approved on last.fm, which belongs to whoever runs this '
              'server.',
        ),
        _point(
          context,
          2,
          'Where it goes',
          'To the Last.fm profile $accountName, visible according to that '
              'account’s Last.fm privacy settings. Last.fm’s own terms and '
              'privacy policy apply.',
          extra: [
            Wrap(
              children: [
                KeyedSubtree(
                  key: const Key('integrations.terms'),
                  child: TextButton(
                    onPressed: onTerms,
                    child: const Text('Last.fm Terms of Use'),
                  ),
                ),
                KeyedSubtree(
                  key: const Key('integrations.privacy'),
                  child: TextButton(
                    onPressed: onPrivacy,
                    child: const Text('Last.fm Privacy Policy'),
                  ),
                ),
              ],
            ),
          ],
        ),
        _point(
          context,
          3,
          'Which listens',
          'Only listens the server receives after you confirm, including one '
              'made earlier on an offline device that syncs later. Listens '
              'received while whoever runs this server has the integration '
              'switched off, or while this connection needs repairing, are '
              'never sent.',
        ),
        _point(
          context,
          4,
          'OSML can’t take it back',
          'Last.fm’s API cannot delete a scrobble. You remove it on '
              'last.fm.',
        ),
        _point(
          context,
          5,
          'Not every listen arrives',
          'OSML tries a few times and then gives up; Last.fm refuses some '
              'listens (for example ones older than about two weeks); '
              'occasionally one is recorded more than once. This page lists '
              'the ones that did not go through.',
        ),
        _point(
          context,
          6,
          'Who holds the access',
          'This server stores a key that gives whoever runs it write access '
              'to your Last.fm account through Last.fm’s API, until you '
              'disconnect here or remove $app under Last.fm '
              'settings → Applications.',
        ),
        _point(
          context,
          7,
          'How to stop',
          'Disconnect. It discards what is waiting, and coming back needs a '
              'new approval and a new confirmation. Removing $app '
              'on last.fm also stops it, until you reconnect.',
        ),
        const SizedBox(height: 12),
        KeyedSubtree(
          key: const Key('integrations.optIn.confirm'),
          child: FilledButton(
            onPressed: busy ? null : onConfirm,
            child: const Text('Start scrobbling'),
          ),
        ),
      ],
    );
  }
}
