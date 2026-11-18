import 'package:flutter/material.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/feed/new_activity_notice.dart';
import 'package:frontend/ui/feed/rail_anchor.dart';
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

/// The feed entity for a read model (`TrackUI` / `AlbumUI` / `ArtistUI`);
/// null for anything else.
FeedEntity? feedEntityOf(Object entity) => switch (entity) {
  TrackUI t => TrackEntity(t),
  AlbumUI a => AlbumEntity(a),
  ArtistUI a => ArtistEntity(a),
  _ => null,
};

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

/// Whether the user is looking into a rail (Phase 9 §5): at its start offset
/// or scrolled in, and whether a pointer is down on it.
@immutable
class RailEngagement {
  const RailEngagement({required this.atStart, required this.pointerDown});

  final bool atStart;
  final bool pointerDown;

  /// At the start with no pointer down: changing the items moves nothing
  /// under the user.
  bool get atRest => atStart && !pointerDown;

  @override
  bool operator ==(Object other) =>
      other is RailEngagement &&
      other.atStart == atStart &&
      other.pointerDown == pointerDown;

  @override
  int get hashCode => Object.hash(atStart, pointerDown);

  @override
  String toString() =>
      'RailEngagement(atStart: $atStart, pointerDown: $pointerDown)';
}

/// A surface-supplied notice floated over a rail ([NewActivityNotice]).
@immutable
class RailNotice {
  const RailNotice({required this.message, this.actionLabel, required this.onTap});

  final String message;
  final String? actionLabel;
  final VoidCallback onTap;
}

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
    this.newActivityLabel,
    this.emptyMessage,
    this.trailing,
    this.subtitle,
    this.onEngagementChanged,
    this.notice,
  });

  /// A caption under the title (what the rail is).
  final String? subtitle;

  /// Opt-in: told whenever the rail's [RailEngagement] changes.
  final ValueChanged<RailEngagement>? onEngagementChanged;

  /// Shown over the ready rail while non-null; drawn by the surface.
  final RailNotice? notice;

  /// A header action drawn at the end of the title row (e.g. See all).
  final Widget? trailing;

  /// Shown under the title when the ready rail is empty (e.g. emptied by a
  /// filter); null hides an empty rail entirely.
  final String? emptyMessage;

  /// Copy of the notice that returns a scrolled rail to its start when newer
  /// entities arrived before the kept anchor; null shows none.
  final String? newActivityLabel;

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
      final message = emptyMessage;
      if (message == null) {
        return const SliverToBoxAdapter(child: SizedBox.shrink());
      }
      // Empty because of the filter: say why, without reserving a card row.
      final theme = Theme.of(context);
      return SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: _titleRow(
                Text(title, style: theme.textTheme.titleMedium),
                trailing,
              ),
            ),
            if (subtitle != null) _caption(theme, subtitle!),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(message, style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      );
    }
    return SliverToBoxAdapter(child: _EntityRail(section: this));
  }
}

Widget _caption(ThemeData theme, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
  child: Text(text, style: theme.textTheme.bodySmall),
);

/// A rail's title, with its optional header action at the end of the row.
Widget _titleRow(Widget title, Widget? trailing) => trailing == null
    ? title
    : Row(
        children: [
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: title),
          ),
          trailing,
        ],
      );

class _RailController extends ScrollController {
  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _RailPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _RailPosition extends ScrollPositionWithSingleContext {
  _RailPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  /// Moves to [offset] without a visible jump or notification: the list
  /// relayouts with its new children this frame. A running fling's simulation
  /// would overwrite the correction on its next tick, so it restarts from the
  /// corrected position once the frame is built (starting an activity
  /// notifies, which is not allowed during build).
  void reanchor(double offset) {
    final current = activity;
    final velocity = current is BallisticScrollActivity ? current.velocity : 0.0;
    correctBy(offset - pixels);
    if (velocity == 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (hasPixels) goBallistic(velocity);
    });
  }
}

/// The rail's live body. Owns the horizontal controller so that, when the
/// entities change while scrolled, the first visible entity stays at the same
/// pixel ([RailAnchor]); a kept anchor that hides newer activity raises the
/// optional [NewActivityNotice].
class _EntityRail extends StatefulWidget {
  const _EntityRail({required this.section});

  final EntityRailSection section;

  @override
  State<_EntityRail> createState() => _EntityRailState();
}

class _EntityRailState extends State<_EntityRail> {
  static const _padding = 8.0;

  final _controller = _RailController();
  bool _newActivity = false;

  /// Pointers (and trackpad pans) currently down on the rail; only tracked
  /// when the section opts in to engagement reports.
  final _pointers = <int>{};
  RailEngagement? _reported;

  /// A horizontal scroll is under way; its start and end are reported even
  /// when the [RailEngagement] value is unchanged (the user acted).
  bool _scrolling = false;
  bool _reportedScrolling = false;
  /// Bumped when the rail leaves `ready`, so the next ready list does not
  /// restore a stored offset meant for the previous result set.
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _scheduleEngagementCheck();
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  RailEngagement _engagement() {
    final atStart =
        !_controller.hasClients || _controller.position.pixels <= 0.5;
    return RailEngagement(atStart: atStart, pointerDown: _pointers.isNotEmpty);
  }

  void _reportEngagement() {
    final callback = widget.section.onEngagementChanged;
    if (callback == null) return;
    final now = _engagement();
    if (now == _reported && _scrolling == _reportedScrolling) return;
    _reported = now;
    _reportedScrolling = _scrolling;
    callback(now);
  }

  /// After a frame: the list may have been replaced (a new reset token or
  /// state) and is then back at offset 0 without a scroll notification.
  void _scheduleEngagementCheck() {
    if (widget.section.onEngagementChanged == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reportEngagement();
    });
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n.metrics.axis != Axis.horizontal) return false;
    if (n is ScrollStartNotification) {
      // A drag, fling or animation: not a jump, which starts and ends in the
      // same call with the position idle and changes no value without a report.
      if (!_controller.hasClients || !_controller.position.isScrollingNotifier.value) {
        return false;
      }
      _scrolling = true;
    } else if (n is ScrollEndNotification) {
      if (!_scrolling) return false;
      _scrolling = false;
    } else {
      return false;
    }
    _reportEngagement();
    return false;
  }

  void _pointerDown(int id) {
    _pointers.add(id);
    _reportEngagement();
  }

  void _pointerUp(int id) {
    _pointers.remove(id);
    _reportEngagement();
  }

  void _onScroll() {
    _reportEngagement();
    if (_newActivity && _controller.offset <= 0 && mounted) {
      setState(() => _newActivity = false);
    }
  }

  @override
  void didUpdateWidget(_EntityRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.section;
    final next = widget.section;
    if (next.onEngagementChanged == null) {
      _pointers.clear();
      _scrolling = false;
      _reportedScrolling = false;
      _reported = null;
    } else {
      _scheduleEngagementCheck();
    }
    if (old.resetToken != next.resetToken || next.state != RailState.ready) {
      _newActivity = false;
      // A new result set after loading/error starts at the start.
      if (next.state != RailState.ready) _epoch++;
      return;
    }
    if (old.state != RailState.ready ||
        identical(old.entities, next.entities) ||
        !_controller.hasClients) {
      return;
    }
    final position = _controller.position as _RailPosition;
    final extent = FeedCardExtent.of(context).width;
    final oldKeys = [for (final e in old.entities) e.key];
    final newKeys = [for (final e in next.entities) e.key];
    final anchor = RailAnchor.capture(
      keys: oldKeys,
      offset: position.pixels,
      itemExtent: extent,
      padding: _padding,
    );
    if (anchor == null) return;
    final restored = anchor.restore(
      oldKeys: oldKeys,
      newKeys: newKeys,
      itemExtent: extent,
      padding: _padding,
      viewportExtent: position.viewportDimension,
    );
    position.reanchor(restored.offset);
    if (restored.newBefore && restored.offset > 0) _newActivity = true;
  }

  void _backToStart() {
    setState(() => _newActivity = false);
    if (!_controller.hasClients) return;
    _controller.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final extent = FeedCardExtent.of(context);
    final onTap = section.onTap;
    final entities = section.entities;
    final Widget body = switch (section.state) {
      RailState.loading => const Center(child: CircularProgressIndicator()),
      RailState.error => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(section.errorText),
            if (section.onRetry != null)
              TextButton(
                onPressed: section.onRetry,
                child: const Text('Retry'),
              ),
          ],
        ),
      ),
      RailState.ready => KeyedSubtree(
        // Part of the stored position's identity: a new token, a new start.
        key: PageStorageKey<Object?>(('feed.rail.reset', section.resetToken, _epoch)),
        child: ListView.builder(
          key: PageStorageKey<String>('feed.rail.${section.id}'),
          controller: _controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: _padding),
          itemExtent: extent.width,
          itemCount: entities.length,
          itemBuilder: (context, index) {
            final entity = entities[index];
            return KeyedSubtree(
              key: entity.key,
              child: cardFor(
                entity,
                onTap: onTap == null ? null : () => onTap(entity, index),
              ),
            );
          },
        ),
      ),
    };
    final label = section.newActivityLabel;
    final notice = section.notice;
    final subtitle = section.subtitle;
    final Widget framed = section.onEngagementChanged == null
        ? body
        : Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) => _pointerDown(e.pointer),
            onPointerUp: (e) => _pointerUp(e.pointer),
            onPointerCancel: (e) => _pointerUp(e.pointer),
            onPointerPanZoomStart: (e) => _pointerDown(e.pointer),
            onPointerPanZoomEnd: (e) => _pointerUp(e.pointer),
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: body,
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: _titleRow(
            Text(
              section.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            section.trailing,
          ),
        ),
        if (subtitle != null) _caption(Theme.of(context), subtitle),
        SizedBox(
          key: ValueKey('feed.rail.${section.id}.body'),
          height: extent.height,
          // The notice floats over the rail's top-end corner and takes no
          // layout space, so showing it moves nothing.
          child: Stack(
            children: [
              Positioned.fill(child: framed),
              if (notice != null && section.state == RailState.ready)
                Positioned(
                  top: 8,
                  right: 16,
                  child: NewActivityNotice(
                    message: notice.message,
                    actionLabel: notice.actionLabel,
                    onRefresh: notice.onTap,
                  ),
                )
              else if (_newActivity && label != null)
                Positioned(
                  top: 8,
                  right: 16,
                  child: NewActivityNotice(
                    message: label,
                    onRefresh: _backToStart,
                  ),
                ),
            ],
          ),
        ),
        ?section.footer,
      ],
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
