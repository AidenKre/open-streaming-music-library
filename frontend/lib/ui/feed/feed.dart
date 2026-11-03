import 'package:flutter/material.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/artist_card.dart';
import 'package:frontend/ui/widgets/track_card.dart';

/// One item of a feed rail (a presentation type; SC-26 keeps it in ui/).
/// Every entity has a stable key — (type, backend identity), so artist 7
/// and album 7 never collide — and its [LibraryScope] (SC-06): menu actions
/// come from `LibraryActions` for that scope, never from the visible label.
sealed class FeedEntity {
  const FeedEntity();

  Key get key;

  LibraryScope get scope;
}

final class ArtistEntity extends FeedEntity {
  const ArtistEntity(this.artist);
  final ArtistUI artist;

  @override
  Key get key => ValueKey('artist:${artist.id}');

  @override
  LibraryScope get scope => ArtistScope(artistId: artist.id);
}

final class AlbumEntity extends FeedEntity {
  const AlbumEntity(this.album);
  final AlbumUI album;

  @override
  Key get key => ValueKey('album:${album.id}');

  @override
  LibraryScope get scope =>
      AlbumScope(artistId: album.artistId, albumId: album.id);
}

final class TrackEntity extends FeedEntity {
  const TrackEntity(this.track);
  final TrackUI track;

  @override
  Key get key => ValueKey('track:${track.uuidId}');

  @override
  LibraryScope get scope => TrackScope(track);
}

/// The surface's primary tap for an entity (open detail / play this list /
/// play one track). Cards never decide it.
typedef FeedCardTap = void Function(FeedEntity entity, int index);

/// The card for [entity]. [onTap] is the surface's primary action.
Widget cardFor(FeedEntity entity, {VoidCallback? onTap}) => switch (entity) {
  ArtistEntity(:final artist) => ArtistCard(
    artist: artist,
    onTap: onTap ?? () {},
  ),
  AlbumEntity(:final album) => AlbumCard(album: album, onTap: onTap ?? () {}),
  TrackEntity(:final track) => TrackCard(track: track, onTap: onTap),
};

/// One rail card's size: 160 logical pixels wide at standard text scale and
/// one common height from square art, two text rows and margins at the
/// current text scale (larger text grows the extent instead of clipping).
class FeedCardExtent {
  const FeedCardExtent(this.width, this.height);

  final double width;
  final double height;

  static const cardWidth = 160.0;

  static FeedCardExtent of(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    double lineHeight(TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: 'Ag', style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    const cardMargin = 4.0; // Card default margin, each side.
    const art = cardWidth - 2 * cardMargin;
    final text =
        8 + // padding top
        lineHeight(theme.textTheme.titleSmall) +
        4 +
        lineHeight(theme.textTheme.bodySmall) + // subtitle row, reserved
        8; // padding bottom
    // The desktop overflow button (32) sits beside the text column.
    final textBlock = text < 32 + 16 ? 32.0 + 16 : text;
    return FeedCardExtent(cardWidth, 2 * cardMargin + art + textBlock + 2);
  }
}

/// A section of a [SectionedFeedView]: returns one sliver, keyed by [id].
abstract class FeedSection {
  const FeedSection();

  /// Stable within its feed.
  String get id;

  Widget buildSliver(BuildContext context);
}

enum RailState { loading, ready, error }

/// A titled horizontal rail of entity cards with explicit loading / ready /
/// error state. A loading or failed rail keeps its normal extent; an empty
/// ready rail disappears entirely, title included. The rail's horizontal
/// position is stored under its section id, so adding, removing or
/// reordering sections never transplants it.
class EntityRailSection extends FeedSection {
  const EntityRailSection({
    required this.id,
    required this.title,
    required this.entities,
    this.state = RailState.ready,
    this.onTap,
    this.onRetry,
    this.errorText = 'Couldn’t load.',
    this.footer,
    this.resetToken,
  });

  @override
  final String id;
  final String title;
  final List<FeedEntity> entities;

  /// When this changes (e.g. a new committed query), the rail starts at its
  /// beginning instead of restoring the previous horizontal position.
  final Object? resetToken;
  final RailState state;
  final FeedCardTap? onTap;
  final VoidCallback? onRetry;
  final String errorText;

  /// Optional line under the rail (e.g. a cap hint).
  final Widget? footer;

  @override
  Widget buildSliver(BuildContext context) {
    if (state == RailState.ready && entities.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final extent = FeedCardExtent.of(context);
    final Widget body = switch (state) {
      RailState.loading => const Center(child: CircularProgressIndicator()),
      RailState.error => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(errorText),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
      RailState.ready => KeyedSubtree(
        // Part of the stored position's identity: a new token, a new start.
        key: PageStorageKey<Object?>(('feed.rail.reset', resetToken)),
        child: ListView.builder(
          key: PageStorageKey<String>('feed.rail.$id'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemExtent: extent.width,
          itemCount: entities.length,
          itemBuilder: (context, index) {
            final entity = entities[index];
            final tap = onTap;
            return KeyedSubtree(
              key: entity.key,
              child: cardFor(
                entity,
                onTap: tap == null ? null : () => tap(entity, index),
              ),
            );
          },
        ),
      ),
    };
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          SizedBox(
            key: ValueKey('feed.rail.$id.body'),
            height: extent.height,
            child: body,
          ),
          ?footer,
        ],
      ),
    );
  }
}

/// Page-supplied instruction, loading, no-result, cap or retry content.
class FeedStatusSection extends FeedSection {
  const FeedStatusSection({required this.id, required this.child});

  @override
  final String id;
  final Widget child;

  @override
  Widget buildSliver(BuildContext context) => SliverToBoxAdapter(child: child);
}

/// The one reusable sectioned feed (Home, Search; Phase 6 recents): a single
/// vertical [CustomScrollView] with an optional header and ordered sections,
/// each returning a sliver keyed by its id. Never nests a vertical
/// shrink-wrapped list. [bottomPadding] is the shell's chrome inset.
class SectionedFeedView extends StatefulWidget {
  const SectionedFeedView({
    super.key,
    required this.sections,
    this.header,
    this.topPadding = 0,
    this.bottomPadding = 0,
  });

  final List<FeedSection> sections;
  final Widget? header;

  /// The shell's chrome insets: the first and last content stay reachable
  /// while the rest scrolls behind the floating bars.
  final double topPadding;
  final double bottomPadding;

  @override
  State<SectionedFeedView> createState() => SectionedFeedViewState();
}

class SectionedFeedViewState extends State<SectionedFeedView> {
  final _controller = ScrollController();

  /// Scrolls the feed back to its top (shell re-tap on a visible root).
  void scrollToTop() {
    if (!_controller.hasClients) return;
    _controller.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: _controller,
      slivers: [
        SliverPadding(padding: EdgeInsets.only(top: widget.topPadding)),
        if (widget.header != null)
          SliverToBoxAdapter(
            key: const ValueKey('feed.header'),
            child: widget.header,
          ),
        for (final section in widget.sections)
          KeyedSubtree(
            key: ValueKey('feed.section.${section.id}'),
            child: section.buildSliver(context),
          ),
        SliverPadding(padding: EdgeInsets.only(bottom: widget.bottomPadding)),
      ],
    );
  }
}

/// One navigation action of an [EntryPointsSection].
@immutable
class FeedEntryPoint {
  const FeedEntryPoint({
    required this.id,
    required this.label,
    required this.icon,
    required this.onSelected,
  });

  final String id;
  final String label;
  final IconData icon;
  final VoidCallback onSelected;
}

/// A responsive list/grid of navigation actions (Home's Artists, Albums,
/// Tracks, Downloaded). Pure navigation: available offline too.
class EntryPointsSection extends FeedSection {
  const EntryPointsSection({required this.id, required this.entries});

  @override
  final String id;
  final List<FeedEntryPoint> entries;

  @override
  Widget buildSliver(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 420,
          mainAxisExtent: 64,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final entry = entries[index];
          return Card(
            key: ValueKey('entry.${entry.id}'),
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(entry.icon),
              title: Text(entry.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: entry.onSelected,
            ),
          );
        }, childCount: entries.length),
      ),
    );
  }
}
