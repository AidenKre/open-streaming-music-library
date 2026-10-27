# Phase 3 — Filter chips + in-page search: implementation plan

> **Authoritative source of truth for Phase 3.** Read this file first when
> resuming. Progress lives in §9 *Progress tracker*; every substantive change
> to the plan is recorded in §10 *Decision log*.
>
> Branch: `phase-3` (cut from `main` @ `c6c44ed`, "Phase 2: format conversion
> and stale downloads (#12)"). Frontend-only phase; no backend changes.
>
> Original design doc: `temp/roadmap/phase-3-filter-chips.md` (**gitignored** —
> it may not exist on another machine; everything needed from it is restated
> here). The design doc was written before Phases 1–2 landed, so §2.3 lists
> where the as-built code differs from it and how this plan resolves each
> difference.

---

## 1. Objectives

Deliver, on the root browse pages, a reusable **capsule filter-chip bar** and an
**in-page entity search**, shipping the **Downloaded** filter. Architect it so
new filters (genre, favorited, …) are additive and the Phase 4 Home page can
reuse the same components.

### 1.1 Requirements (from the design doc, as reconciled in §2.3)

| ID | Requirement |
| --- | --- |
| R1 | An immutable, typed **`BrowseFilters`** value object (`downloaded` for now) with `copyWith`, value equality, and the rule **effective downloaded = user toggle ‖ offline**. Minimal but extensible — no generic filter framework. |
| R2 | A stateless **`FilterBar`** widget: a horizontally scrollable row of **capsule** (`StadiumBorder`) `FilterChip`s. Props: `BrowseFilters filters`, `ValueChanged<BrowseFilters> onChanged`, `bool isOffline`. The page owns the state. |
| R3 | **Offline lock**: while offline the Downloaded chip renders **selected and disabled** (`onSelected: null`). The user's own value is preserved underneath, so going back online restores the last explicit setting. |
| R4 | The FilterBar **replaces `DownloadedOnlyBadge`** on pages that show it. A page never shows both. |
| R5 | Filter state is **per-page, session-only**: it lives in the page `State`, is not global, and is not persisted. The tab `IndexedStack` keeps `State` alive across tab switches. |
| R6 | The FilterBar (and in-page search) attach **only to root tab instances** (`isRoot: true`), never to the `TracksPage`/`AlbumsPage` pushed as album/artist **detail** sub-routes. |
| R7 | The chip **filters uniformly** on every root browse tab. The **Tracks tab changes from offline row-dimming to filtering** (deliberate and confirmed in the design doc). |
| R8 | A **single unified search method**: `BrowseRepository.search(query, {Set<SearchType> types, int limitPerType, bool downloadedOnly})`. It is a superset of today's signature. The global Search page uses all types and the in-page search uses one type. No separate `searchOne`. |
| R9 | **One shared search primitive** used by the global Search page and the in-page search, and reusable by Phase 4. It owns the 300 ms debounce, the generation stale-guard, the capped FTS fetch, empty/capped state and dispose-cancel. |
| R10 | In-page search behaviour: an **empty query means browse mode** (the existing reactive pagination, unchanged). A **non-empty query means capped FTS mode**, with `types: {thisPageType}`, a cap of **100** (well under 999), and the effective downloaded filter. Empty results show an empty state. A **"showing first N — refine to narrow"** hint appears when `results.length == cap`. |
| R11 | The **browse↔search mode switch** must not race. Entering search mode suspends the reactive browse window (no `setState` from the live watch underneath the search UI, and no scroll-driven re-subscribe). Returning to an empty query goes **through `refresh()`**. |
| R12 | Search mode **composes with the Downloaded filter, offline mode, and `downloadStatusVersionProvider`**. A chip toggle or offline flip re-runs the search. On a download-status change the page re-searches when the result set is download-filtered, otherwise it patches the rows in place. Without this, a delete mid-search leaves a dead row. |
| R13 | The debounce `Timer` is cancelled in `dispose()`, and no late completion touches a disposed page. |
| R14 | No backend changes. The existing `downloadedOnly` plumbing (drift queries and FTS) is reused. |
| R15 | No regressions. The full frontend suite and `flutter analyze` stay green, and the existing global Search page behaviour is preserved apart from deliberate improvements logged in §10. |

### 1.2 Non-goals (explicitly out of scope)

- Genre / favorited filters (only the UI seam). See the design doc's
  "Extensibility" notes: genre needs query clauses, and favorited likely needs a
  new synced column.
- Phase 4 Home page, nav collapse, and Home's one-`BrowseFilters`-fans-out wiring.
- Infinite scroll in search mode (capped by design).
- Live re-query of search results on metadata edits or sync. Results are a
  snapshot, the same as today's global Search page. See risk K3.
- Persisting filter state across app restarts.

---

## 2. Current state analysis (verified against `main` @ `c6c44ed`)

### 2.1 Relevant existing code

| Area | File | Facts that matter for Phase 3 |
| --- | --- | --- |
| App shell | `frontend/lib/main.dart` (`AppShell`) | 4 tabs in an `IndexedStack`, each with its own `Navigator`: **Artists** (`ArtistsPage(isRoot: true)`), **Tracks** (`TracksPage(key: _tracksKey, isRoot: true)`), **Downloads** (`DownloadedTracksPage`), **Search** (`SearchPage`). **There is no root Albums tab.** |
| Artists tab | `frontend/lib/ui/artist_page.dart` | `CursorPaginationMixin<ArtistUI>`. `watchPage` passes `downloadedOnly: ref.read(offlineModeProvider)`. Listens to `offlineModeProvider` and calls `refresh()`. Shows `DownloadedOnlyBadge` when offline. Tapping an artist pushes `AlbumsPage(artistId:)` (a detail route). |
| Tracks tab / album detail | `frontend/lib/ui/tracks_page.dart` | `CursorPaginationMixin<TrackUI>`. Used as the root tab (`isRoot: true`) **and** as the album-detail body (`isRoot: false`, `artistId`/`albumId` set). It **never** passes `downloadedOnly`. Offline it **dims and disables** non-downloaded rows. Tap → `audioProvider.playFromQueue(... downloadedOnly: false)` (the coordinator forces the filter when offline). Also hosts `buildTopBarActions`. |
| Albums | `frontend/lib/ui/albums_page.dart` | **Detail-only** (artist → albums). Has no `isRoot` parameter. Filters by `offlineModeProvider` and shows the badge offline. |
| Global search | `frontend/lib/ui/search_page.dart` | Has its own 300 ms debounce, `_searchGeneration` guard, `limitPerType: 5`, `downloadedOnly: offline`, and two `ref.listen`s (offline flip → re-search; download version → re-search when offline, else `_patchDownloadStates`). It shows the badge offline and has offline vs online empty-state copy. Clear is debounced. |
| Pagination | `frontend/lib/ui/mixins/cursor_pagination_mixin.dart` | **Reactive growing window**. `watchPage(limit)` is a drift `.watch()`, and `_subscribe()` (re)subscribes. `loadMore()` grows the window and re-subscribes; the scroll listener calls it. `refresh()` cancels the quiet timer, clears items, resets the window and re-subscribes. `disposePagination()` cancels the subscription and timer, but **does not** stop `loadMore()` from re-subscribing via scroll. Emissions are coalesced by a 150 ms leading+trailing quiet timer. |
| Repository | `frontend/lib/repositories/browse_repository.dart` | `watchAlbums/watchArtists/watchTracks({downloadedOnly})`. `search(query, {limitPerType = 5, downloadedOnly})` has **no type selection**. |
| DB search | `frontend/lib/database/database.dart` `getSearchResults` | Already supports `searchTracks/searchArtists/searchAlbums`, `limitPerType`, `downloadedOnly` (applied **inside** the FTS query, before `LIMIT`). Hydration uses `WHERE id IN (?, …)`, one bound variable per hit, and a `?? 999` sort fallback. `prepareFtsQuery` does per-token prefix matching and short-circuits an empty query. |
| Download state | `AppDatabase.getTrackDownloadStates(uuids)` | Returns per-uuid download columns. SearchPage uses it to patch result rows. |
| Download version | `frontend/lib/services/download_providers.dart` | `downloadStatusVersionProvider` (`StreamProvider<int>`) bumps on every download or delete. |
| Offline | `frontend/lib/providers/offline_mode_provider.dart` | `offlineModeProvider` (`bool`). |
| Badge | `frontend/lib/ui/widgets/downloaded_only_badge.dart` | "Showing downloaded only" strip. |
| Track tile | `frontend/lib/ui/widgets/track_tile.dart` | `isDimmed`, `isInteractive` flags. |

### 2.2 Baseline (measured on `phase-3` before any change)

- `flutter test` (frontend): **883 passed, 0 failed**.
- `flutter analyze`: **No issues found**.
- Flutter 3.44.0 (stable), Dart SDK ^3.11. Riverpod 3, drift 2.

### 2.3 Design doc vs as-built code — reconciliation

| # | Design doc says | As-built reality | Resolution |
| --- | --- | --- | --- |
| G1 | "Three browse pages (artists/albums/tracks)", with the chip on root tabs only. | **No root Albums tab exists.** `AlbumsPage` is only ever the artist-detail sub-route. | Follow the doc's explicit R6 rule: the chip bar and in-page search go on the **two root browse tabs, Artists and Tracks**. `AlbumsPage` (detail) keeps its current offline filtering and badge. Adding an Albums tab would be nav work, and Phase 4 is collapsing the nav anyway. The components are page-agnostic, so a future root Albums surface wires them the same way. See D1. |
| G2 | Mixin has `_generation`, `watchItemCount`, `_startWatching`, `loadMore()` awaits. | The mixin was rewritten into a reactive window: `watchPage` + `_subscribe` + quiet-timer coalescing, with no count stream and no generation counter. | The race is the same in spirit: the live window `setState`s underneath search mode, and **scroll can re-subscribe after `disposePagination()`**. Add an explicit `suspendPagination()` that `refresh()` clears. See D3 and T1.3. |
| G3 | `getSearchResults` has per-type flags and `BrowseRepository.search` "already supports" it. | The DB layer does, but `BrowseRepository.search` doesn't expose types. | Add `Set<SearchType> types` to `BrowseRepository.search` (default: all). This is backward compatible. See T3.1. |
| G4 | `BrowseFilters { bool downloaded; String query }`. | n/a | `query` lives in the shared search controller, not `BrowseFilters`. See D2. |
| G5 | Cap "~50–100, well under 999". | Hydration binds one SQL variable per hit (and old SQLite builds cap variables at 999). | Cap = **100** (`kInPageSearchCap`). See D5. |
| G6 | Search page "re-search when offline / patch when online". | Same. | Generalised: re-search when the visible set is **download-filtered** (`effective downloaded`), otherwise patch. In-page search with the chip on, but online, must also re-search. See D6. |

### 2.4 Dependencies on earlier phases

- Phase 1 and 2 data fields on `TrackUI` (revision, `downloadedAtRevision`,
  `downloadedCodec`, `staleDismissedAtRevision`) must be patched **together** on
  a download-state refresh, or staleness reads inconsistently. The existing
  SearchPage comment says the same, and T3.2 preserves it.
- Phase 2 convert-flow wiring on `TracksPage` rows (conversion job trailing,
  `canConvertTrack`, the `startConversion` page-context rule) must keep working
  for **search-mode rows** too. Search rows are built by the same tile builder
  (T4.2).
- No drift schema change, so no migration (schema stays `1`).

---

## 3. Architecture and design

### 3.1 New and changed modules

```
frontend/lib/
  models/browse_filters.dart            NEW  BrowseFilters value object (R1)
  ui/widgets/filter_bar.dart            NEW  FilterBar capsule-chip row (R2, R3)
  ui/widgets/library_search_field.dart  NEW  shared search TextField + clear (R9)
  ui/widgets/search_status.dart         NEW  empty-state / capped-hint widgets + copy (R10)
  ui/utils/library_search_controller.dart NEW shared search primitive (R9, R12, R13)
  ui/mixins/cursor_pagination_mixin.dart CHG  + suspendPagination / isPaginationSuspended (R11)
  repositories/browse_repository.dart   CHG  search(types:), withFreshDownloadState() (R8, R12)
  ui/artist_page.dart                   CHG  root: FilterBar + in-page search
  ui/tracks_page.dart                   CHG  root: FilterBar + in-page search, uniform filtering
  ui/search_page.dart                   CHG  refactored onto the shared primitive (R9)
```

### 3.2 `BrowseFilters` (`lib/models/browse_filters.dart`)

```dart
@immutable
class BrowseFilters {
  const BrowseFilters({this.downloaded = false});
  /// The user's explicit Downloaded choice. Preserved while offline.
  final bool downloaded;
  BrowseFilters copyWith({bool? downloaded});
  /// What the queries actually use: offline forces downloaded-only.
  bool effectiveDownloaded({required bool isOffline}) => downloaded || isOffline;
  // ==, hashCode, toString
}
```

Adding a filter later means adding a field, a `copyWith` arg, a chip in
`FilterBar`, and the query clause. No framework.

### 3.3 `FilterBar` (`lib/ui/widgets/filter_bar.dart`)

`StatelessWidget(filters, onChanged, isOffline)` builds a
`SingleChildScrollView(scrollDirection: Axis.horizontal)` of chips. The Downloaded
chip is `FilterChip(label: 'Downloaded', shape: StadiumBorder(), selected:
filters.effectiveDownloaded(isOffline), onSelected: isOffline ? null : (v) =>
onChanged(filters.copyWith(downloaded: v)))`. When offline it is wrapped in a
`Tooltip` ("Offline — only downloaded music is available"). That tooltip
carries the information the removed badge used to give. Each chip has a stable
`Key` (`FilterBar.downloadedChipKey`) for tests and Phase 4.

### 3.4 Unified search

- `enum SearchType { artists, albums, tracks }` lives in `browse_repository.dart`.
- `BrowseRepository.search(String query, {Set<SearchType> types =
  SearchType.values-as-set, int limitPerType = 5, bool downloadedOnly = false})`
  maps types onto `getSearchResults`'s three bool flags. An empty `types` set
  returns empty results without touching the DB.
- `typedef LibrarySearchResults = ({List<ArtistUI> artists, List<AlbumUI>
  albums, List<TrackUI> tracks})` (the record shape it already returns).
- `BrowseRepository.withFreshDownloadState(List<TrackUI>)` takes the row-patch
  logic out of `SearchPage._patchDownloadStates`. It re-reads
  `getTrackDownloadStates` and copies all eight download/staleness fields.

### 3.5 `LibrarySearchController` (`lib/ui/utils/library_search_controller.dart`)

A `ChangeNotifier`, owned by the page `State` and disposed in `dispose()`.

```dart
LibrarySearchController({
  required BrowseRepository repository,
  required Set<SearchType> types,
  required int limitPerType,
  required bool Function() downloadedOnly, // read at fetch time
  Duration debounce = const Duration(milliseconds: 300),
});
String get query;            // committed (debounced, trimmed) query
bool get isActive;           // query.isNotEmpty  → page is in search mode
bool get isSearching;        // a fetch for the current generation is in flight
LibrarySearchResults get results;
bool get isCapped;           // any requested type returned == limitPerType rows
void onQueryChanged(String raw);   // debounced commit + search
void clear();                      // immediate: cancel debounce, commit '' (→ browse)
Future<void> rerun();              // re-fetch current query now (filter/offline flip)
Future<void> onDownloadStatusChanged(); // downloadedOnly() ? rerun : patch rows
void dispose();                    // cancels the timer; late completions dropped
```

Invariants:

- Every fetch captures `++_generation`. A completion whose generation is stale
  (a newer query, `clear()`, `rerun()`) or that lands after `dispose()` is
  dropped. The same applies to a row patch.
- Committing an **empty** query bumps the generation (which cancels in-flight
  fetches), clears the results, sets `isSearching = false` and notifies, so the
  page returns to browse mode.
- A commit equal to the current query does nothing (no duplicate fetch),
  **unless** it comes through `rerun()`.
- `notifyListeners` is never called after `dispose()`.

### 3.6 Browse↔search mode switch (`CursorPaginationMixin` + pages)

New mixin API:

- `suspendPagination()` cancels the window subscription and the quiet timer,
  drops any pending emission, and sets `_suspended = true`. While suspended,
  `loadMore()` and the scroll listener are no-ops. The paginated items stay in
  memory but are not rendered.
- `bool get isPaginationSuspended`.
- `refresh()` clears `_suspended` and re-subscribes from page 1. This is the
  **only** way back.

Page logic, the same for Artists and Tracks (root only), driven by a listener on
the controller:

```
controller becomes active   (''  → 'q') : suspendPagination(); setState
controller becomes inactive ('q' → '' ) : refresh()            // never a bare rebuild
chip toggled / offline flip             : controller.isActive ? controller.rerun() : refresh()
downloadStatusVersion bump              : controller.isActive ? controller.onDownloadStatusChanged() : (nothing — the window is reactive)
```

Search results render in a **separate list** with its own (or no)
`ScrollController`, so scrolling search results can never reach the browse
scroll listener.

### 3.7 Page wiring

- **ArtistsPage (root)**:
  - Header: `LibrarySearchField(hint: 'Search artists')` and a `FilterBar`.
  - Browse: `watchArtists(downloadedOnly: _filters.effectiveDownloaded(...))`.
  - Search: a grid of `ArtistCard`s built by the same card builder.
  - Non-root `ArtistsPage` (only used by tests today) keeps the badge behaviour.
- **TracksPage (root)**:
  - Header: `LibrarySearchField(hint: 'Search tracks')` and a `FilterBar`.
  - Browse: `watchTracks(downloadedOnly: effective)`.
  - Tapping a browse row calls `playFromQueue(..., downloadedOnly: effective)`,
    so **the queue matches the visible filtered list** (see D7).
  - Search: a list of `TrackTile`s from one shared `_buildTrackTile`. Tapping a
    row calls `playFromTrackList(resultUuids, track, sourceType: 'search')`,
    the same as the global search.
  - Rows no longer need dimming (offline means everything is downloaded).
- **TracksPage (detail, `isRoot: false`)**: **unchanged**. No header, no
  `downloadedOnly`, offline dimming kept, `playFromQueue(downloadedOnly:
  false)`.
- **Browse empty state** (T2.3): when the effective Downloaded filter is on and
  the window settled empty (`!hasMore && items.isEmpty`), show "No downloaded
  artists/tracks yet". This keeps the badge's old guarantee that an empty
  filtered list never reads like a wiped library.
- **SearchPage (global)**: uses `LibrarySearchController(types: all,
  limitPerType: 5, downloadedOnly: () => offline)` and `LibrarySearchField`.
  It keeps the badge (it has no chip bar), the existing empty-state copy and
  the long-press actions.

### 3.8 Search status copy (`lib/ui/widgets/search_status.dart`)

`String noSearchResultsMessage({required String noun, required String query,
required bool downloadedOnly, required bool isOffline})`:

- online, unfiltered: `No <noun> match "<q>".`
- download-filtered: `No downloaded <noun> match "<q>".`
- offline adds: ` Reconnect to the server to search the full library.`

The global Search page keeps its exact existing strings (pinned by existing
tests): `No results found`, and `No downloaded results match "<q>". Reconnect to
the server to search the full library.`

`SearchCappedHint(cap)` reads: `Showing the first <cap> matches — refine your
search to narrow them down.`

---

## 4. Milestones and tasks

Tasks are in dependency order. Every task follows **RED → GREEN → REFACTOR →
COMMIT** (§5). "Verify" names the exact command(s) whose passing output marks
the task complete. All paths are relative to `frontend/` unless noted.

### M0 — Planning

#### T0.1 — Create branch and plan
- **What:** create branch `phase-3` and write and commit this document.
- **Files:** `PHASE_3_PLAN.md` (repo root).
- **Deps:** none.
- **Acceptance:** the branch exists; the plan is committed before any code.
- **Tests:** n/a (documentation). Baseline recorded in §2.2.
- **Verify:** `git log -1 --stat` shows only `PHASE_3_PLAN.md`.

### M1 — Foundations

#### T1.1 — `BrowseFilters` model
- **What:** the §3.2 value object.
- **Files:** `lib/models/browse_filters.dart`; `test/models/browse_filters_test.dart`.
- **Deps:** T0.1.
- **Acceptance:**
  - Defaults to `downloaded: false`.
  - `copyWith` changes only the given field.
  - Value equality and `hashCode` hold.
  - `effectiveDownloaded` truth table: (false, online) → false; (true, online) → true; (false, offline) → true; (true, offline) → true.
  - The user value survives an offline period: `copyWith` is never applied by the offline lock.
- **Tests:** a unit test for each bullet.
- **Verify:** `flutter test test/models/browse_filters_test.dart`.

#### T1.2 — `FilterBar` widget
- **What:** the §3.3 widget.
- **Files:** `lib/ui/widgets/filter_bar.dart`; `test/ui/widgets/filter_bar_test.dart`.
- **Deps:** T1.1.
- **Acceptance:**
  - Renders a `FilterChip` labelled "Downloaded" with a `StadiumBorder` shape.
  - Online and unselected: tapping calls `onChanged` with `downloaded: true`. When selected, tapping calls it with `false`.
  - Offline: the chip is selected **and** disabled (`onSelected == null`). Tapping does not call `onChanged`. A tooltip explains why.
  - Offline with the user value false: still shown selected (lock), and `onChanged` is never called (the user value is untouched).
  - Horizontally scrollable (a `SingleChildScrollView` on `Axis.horizontal`).
- **Edge cases:** rebuilding with a new `isOffline` flips the lock without any state of its own (the widget is stateless).
- **Verify:** `flutter test test/ui/widgets/filter_bar_test.dart`.

#### T1.3 — Pagination suspend/resume
- **What:** `suspendPagination()`, `isPaginationSuspended`, and `refresh()`
  resuming (§3.6).
- **Files:** `lib/ui/mixins/cursor_pagination_mixin.dart`; `test/ui/mixins/cursor_pagination_mixin_test.dart`.
- **Deps:** T0.1.
- **Acceptance:**
  - After suspend, window emissions are not delivered (items unchanged).
  - A pending trailing-edge emission held by the quiet timer is dropped.
  - `loadMore()` is a no-op while suspended (no re-subscribe; `watchPage` call count unchanged).
  - `refresh()` resumes: a new subscription from page 1, items delivered, `isPaginationSuspended == false`.
  - Existing mixin tests still pass.
- **Verify:** `flutter test test/ui/mixins/cursor_pagination_mixin_test.dart`.

### M2 — Downloaded chip on the root browse tabs

#### T2.1 — ArtistsPage root: FilterBar + effective downloaded filter
- **What:** the root `ArtistsPage` holds `BrowseFilters _filters`. A `FilterBar`
  replaces the badge. `watchPage` uses
  `_filters.effectiveDownloaded(isOffline: ref.read(offlineModeProvider))`. A
  chip change triggers `setState` and `refresh()`. The offline flip still
  triggers `refresh()`. Non-root keeps the badge.
- **Files:** `lib/ui/artist_page.dart`; `test/ui/artists_page_filters_test.dart` (new).
- **Deps:** T1.1, T1.2.
- **Acceptance (widget tests, real in-memory drift DB, seeded with one downloaded artist and one streaming-only artist):**
  1. Online root shows the FilterBar with the chip unselected. Both artists are visible. No badge.
  2. Tapping the chip leaves only the downloaded artist visible.
  3. Tapping it again shows both again.
  4. Offline root: the chip is selected and disabled, only the downloaded artist is shown, and there is no `DownloadedOnlyBadge`.
  5. **Restore:** online with the chip off → offline (locked on, filtered) → online gives the chip unselected and both artists. With the chip on before going offline, it is still on after coming back.
  6. A non-root `ArtistsPage` shows no FilterBar (existing badge tests are kept).
- **Verify:** `flutter test test/ui/artists_page_filters_test.dart test/ui/offline_downloaded_only_badge_test.dart`.

#### T2.2 — TracksPage root: FilterBar + uniform filtering; detail unchanged
- **What:** the same wiring as T2.1 on the root `TracksPage`. `watchTracks`
  passes `downloadedOnly: effective` (root only). A browse-row tap passes
  `downloadedOnly: effective` to `playFromQueue` (root only). The detail
  route is untouched.
- **Files:** `lib/ui/tracks_page.dart`; `test/ui/tracks_page_filters_test.dart` (new).
- **Deps:** T1.1, T1.2.
- **Acceptance:**
  1. Root, online: chip off shows both tracks and no dimming. Chip on shows only the downloaded track.
  2. Root, offline: the chip is locked on and only the downloaded track is listed (**filtering, not dimming**).
  3. Root: tapping a row with the chip on calls `playFromQueue(downloadedOnly: true)`. With the chip off, `false`. Recorded via an `AudioCoordinator` test subclass.
  4. Detail (`isRoot: false`, `artistId`/`albumId`), offline: no FilterBar, both tracks listed, and the non-downloaded one is dimmed (`TrackTile.isDimmed == true`). This is the existing behaviour, kept.
  5. Detail: a row tap passes `downloadedOnly: false` (unchanged).
  6. The restore semantics from T2.1 hold.
- **Regression:** `test/ui/tracks_page_convert_flow_test.dart` (pumps a non-root `TracksPage`) still passes.
- **Verify:** `flutter test test/ui/tracks_page_filters_test.dart test/ui/tracks_page_convert_flow_test.dart`.

#### T2.3 — Empty state for a filtered browse list
- **What:** in a root page with the effective Downloaded filter on and a
  settled-empty window (`!hasMore && paginatedItems.isEmpty`), show "No
  downloaded artists yet." or "No downloaded tracks yet.".
- **Files:** `lib/ui/artist_page.dart`, `lib/ui/tracks_page.dart`, the two test files from T2.1/T2.2.
- **Deps:** T2.1, T2.2.
- **Acceptance:**
  - Shown when filtering with nothing downloaded.
  - Not shown when unfiltered and the library is empty (the pre-existing blank behaviour is kept).
  - Not shown while the first window is still loading.
- **Verify:** both page test files.

### M3 — Unified search primitive

#### T3.1 — `BrowseRepository.search` gains `types`
- **What:** `enum SearchType`, a `types` param defaulting to all, the
  `LibrarySearchResults` typedef, and an empty `types` set that short-circuits.
- **Files:** `lib/repositories/browse_repository.dart`; `test/repositories/browse_repository_test.dart`.
- **Deps:** T0.1.
- **Acceptance:**
  - `types: {SearchType.tracks}` returns only tracks (artists and albums are empty) even when the query matches all three.
  - `{artists}` and `{albums}` likewise.
  - The default returns all three (the existing tests stay unchanged).
  - `downloadedOnly` and `limitPerType` still apply per type.
  - Empty `types` returns empty results.
  - A cap of 100 with more than 100 matches returns exactly 100, in rank order.
- **Verify:** `flutter test test/repositories/browse_repository_test.dart`.

#### T3.2 — `BrowseRepository.withFreshDownloadState`
- **What:** move SearchPage's row-patch logic into the repository (§3.4).
- **Files:** `lib/repositories/browse_repository.dart`; `test/repositories/browse_repository_test.dart`.
- **Deps:** T0.1.
- **Acceptance:**
  - Re-reads `filePath`, `downloadedBitrateKbps`, `fileSizeBytes`, `downloadedQuality`, `revision`, `downloadedAtRevision`, `downloadedCodec` and `staleDismissedAtRevision` for every row.
  - Preserves order and length.
  - A row whose track vanished from the DB is returned unchanged.
  - An empty list returns empty without a query.
  - A download being cleared (`filePath → null`) is reflected.
- **Verify:** as T3.1.

#### T3.3 — `LibrarySearchController`
- **What:** §3.5.
- **Files:** `lib/ui/utils/library_search_controller.dart`; `test/ui/utils/library_search_controller_test.dart`.
- **Deps:** T3.1, T3.2.
- **Acceptance (real in-memory DB and repository; fake async/timers via `fakeAsync` or real short delays; a gated fake repo only for the race tests):**
  1. **Debounce:** several `onQueryChanged` calls within 300 ms produce one fetch, using the last value, trimmed.
  2. Results populate and `isActive` becomes true. `isSearching` is true while in flight and false afterwards.
  3. **Stale guard:** query A in flight, then query B commits and completes, then A completes. The results are B's.
  4. `clear()` acts immediately (no 300 ms wait). It cancels the pending debounce and drops in-flight results. `isActive` becomes false and the results are empty.
  5. `rerun()` re-fetches the same query and picks up a changed `downloadedOnly()`.
  6. `onDownloadStatusChanged()`: with `downloadedOnly()` true it re-fetches (a deleted download drops out of the results). With false it patches the track rows in place (a download appearing shows `filePath`).
  7. `isCapped` is true when a type returns exactly `limitPerType` rows and false below that.
  8. **Dispose:** a pending debounce never fires a fetch, an in-flight completion is dropped, and no listener is notified after dispose (no exception).
  9. A commit equal to the current query does not re-fetch.
  10. A whitespace-only query behaves like empty.
- **Verify:** `flutter test test/ui/utils/library_search_controller_test.dart`.

#### T3.4 — `LibrarySearchField` and search-status widgets
- **What:**
  - A shared `TextField` widget (search icon, a clear button shown only when the text is non-empty, rounded border, `hintText`, `autofocus` param) with `onChanged`/`onCleared`.
  - `noSearchResultsMessage(...)` and `SearchCappedHint`.
- **Files:** `lib/ui/widgets/library_search_field.dart`, `lib/ui/widgets/search_status.dart`; tests `test/ui/widgets/library_search_field_test.dart`, `test/ui/widgets/search_status_test.dart`.
- **Deps:** T0.1.
- **Acceptance:**
  - Typing calls `onChanged`.
  - The clear button appears only with text. Tapping it empties the field and calls `onCleared`.
  - The message truth table matches §3.8.
  - The capped hint renders the cap number.
- **Verify:** both test files.

#### T3.5 — Refactor the global `SearchPage` onto the shared primitive
- **What:** replace the bespoke debounce, generation, patch and TextField with
  `LibrarySearchController` and `LibrarySearchField`. Keep the badge, the
  section layout, the empty copy, the long-press actions and
  `playFromTrackList(sourceType: 'search')`. The two `ref.listen`s become
  `controller.rerun()` (offline flip) and `controller.onDownloadStatusChanged()`.
- **Files:** `lib/ui/search_page.dart`; `test/ui/search_page_test.dart` (add regression tests).
- **Deps:** T3.3, T3.4.
- **Acceptance:**
  - All existing SearchPage tests (`search_page_test.dart`, `offline_downloaded_only_badge_test.dart`) pass unmodified.
  - New: results still limited to 5 per type.
  - The clear button returns to the blank state immediately.
  - An offline flip mid-query re-runs the search with `downloadedOnly`. Verified with a real DB containing one downloaded and one streaming-only match.
- **Verify:** `flutter test test/ui/search_page_test.dart test/ui/offline_downloaded_only_badge_test.dart`.

### M4 — In-page search on the root browse tabs

#### T4.1 — ArtistsPage in-page search and mode switch
- **What:** a root header with `LibrarySearchField(hint: 'Search artists')`
  above the FilterBar. A controller with `types: {artists}`,
  `limitPerType: kInPageSearchCap`, and `downloadedOnly: () =>
  _filters.effectiveDownloaded(...)`. The mode switch follows §3.6. Search mode
  renders a grid of cards, the empty message and the capped hint.
- **Files:** `lib/ui/artist_page.dart`; `test/ui/artists_page_filters_test.dart`.
- **Deps:** T1.3, T2.1, T3.3, T3.4.
- **Acceptance:**
  1. Typing a query shows only matching artists after the debounce. The browse grid is hidden, `isPaginationSuspended` is true, and a DB write while searching causes no browse `setState` (asserted via the suspended flag and the absence of browse items).
  2. Clearing returns to browse through `refresh()`: all artists are back and pagination is resumed.
  3. No match shows `No artists match "q".`. With the chip on, `No downloaded artists match "q".`.
  4. Chip toggled while searching: the search re-runs with the new filter (a streaming-only match disappears and reappears). Browse stays suspended.
  5. Offline flip while searching: the search re-runs filtered, and the offline copy appears on an empty result.
  6. Download status change while filtering: an artist whose last download was deleted disappears from the results (requires the re-run).
  7. Capped: with more than 100 matching artists seeded, the hint shows and exactly 100 cards render (the grid is lazily built, so the result count is asserted on state).
  8. Disposing the page with a pending debounce throws no exception and leaves no pending timers.
- **Verify:** `flutter test test/ui/artists_page_filters_test.dart`.

#### T4.2 — TracksPage in-page search and mode switch
- **What:** the same as T4.1 for `types: {tracks}`, root only. Search rows reuse
  the shared `_buildTrackTile` (download progress trailing, conversion job,
  convert action). Tapping a row calls `playFromTrackList(results, track,
  sourceType: 'search')`.
- **Files:** `lib/ui/tracks_page.dart`; `test/ui/tracks_page_filters_test.dart`.
- **Deps:** T1.3, T2.2, T3.3, T3.4.
- **Acceptance:**
  - The T4.1 items 1–5 and 8, applied to tracks.
  - Download status change, **online with the chip off**: a row patches in place (downloaded state updates, the row stays).
  - With the chip on: a deleted download drops out of the results.
  - Tapping a search row calls `playFromTrackList` with the result uuids, in order.
  - Detail `TracksPage` has no search field.
- **Verify:** `flutter test test/ui/tracks_page_filters_test.dart`.

### M5 — Final verification

#### T5.1 — Full suite, analyzer, formatting
- **Acceptance:**
  - `flutter test` passes in full (count ≥ baseline 883 plus the new tests).
  - `flutter analyze` reports no issues.
  - Every **new** file is `dart format`-clean (see D8).
  - Backend `pytest` still passes. No backend files changed, so this is a sanity check only.

#### T5.2 — Shell-level integration test
- **What:** pump the real `AppShell`, with the providers it needs overridden and a real in-memory DB.
- **Files:** `test/ui/app_shell_filters_test.dart`.
- **Acceptance:**
  - The Artists and Tracks root tabs each show a FilterBar and search field.
  - Toggling Downloaded on Artists doesn't affect Tracks (per-page state).
  - Switching tabs and back preserves each tab's chip value (IndexedStack).
  - Pushing an album detail from Artists → Albums → Tracks shows no FilterBar.

#### T5.3 — Live app smoke test (best effort)
- **What:** build and run the macOS app (`flutter build macos` at minimum) to
  confirm it compiles and launches. If a backend can be started locally, also
  exercise the chips and search by hand or with integration_test. Record
  exactly what ran. If something couldn't be done, say so honestly in §11.

#### T5.4 — Requirements trace and plan close-out
- **What:**
  - Re-read §1.1 and record, for every R-id, the code and test that satisfies it (§11).
  - Confirm the working tree is clean on `phase-3`.
  - Record the final results.

---

## 5. Development process (applies to every task)

1. **RED:**
   - Write the tests for the task's acceptance criteria.
   - Run them and confirm they fail **for the expected reason**: a missing symbol counts only for a brand-new file's API; otherwise it must be a wrong value or missing behaviour.
   - When a missing class makes compilation fail, first add a minimal stub that compiles (an empty class or method returning a wrong value), so the RED run shows a behavioural failure.
2. **GREEN:** write the minimum production code. Run the task's tests, then the related suites.
3. **REFACTOR:** clean up and rerun.
4. **COMMIT:**
   - Update §9 (status and the test evidence line) and §10 if a decision changed.
   - Stage only the task's files and commit, with a message of the form `Phase 3 T<id>: <summary>`.

Commands are run from `frontend/`: `flutter test <paths>`, `flutter analyze`,
`dart format <files>`.

## 6. Testing strategy

- **Unit:**
  - `BrowseFilters`.
  - Copy helpers.
  - The `BrowseRepository` search/patch tests run against a **real in-memory drift DB** with FTS rebuilt, never a mocked DB.
  - The controller tests use the real repository. A gated fake is used only where a test needs to control completion order (race tests).
- **Widget:**
  - `FilterBar` and `LibrarySearchField` are tested in isolation.
  - The pages are pumped with real in-memory DBs.
  - Providers are overridden only where a real one would hit the network or the audio stack: `trackSyncProvider`, `appInfoProvider`, `conversionJobsProvider`, `offlineModeProvider`, `downloadManagerProvider` (a real `DownloadManager` on a temp dir), and `audioProvider` (a recording subclass, for assertions on play calls).
- **Mixin:** direct host tests (the existing pattern).
- **Integration:** `AppShell`-level widget test (T5.2), plus a live app build and run (T5.3).
- **Hygiene:** every widget test that mounts a drift `.watch()` page tears down by pumping an empty tree inside the test body (the existing `teardownTree` pattern), so no pending timers leak.
- **Regression:** the full suite runs at each milestone boundary and in T5.1.

## 7. Risks and mitigations

| ID | Risk | Mitigation |
| --- | --- | --- |
| K1 | The browse window `setState`s underneath search mode, or a scroll re-subscribes it. | Mixin-level suspend (T1.3), a separate search list, and the T4.1 #1 test. |
| K2 | A late async search completion overwrites newer results or touches a disposed page. | The generation guard and the disposed flag (T3.3 #3 and #8). |
| K3 | Search results are a snapshot, so metadata edits or a sync while searching aren't reflected. | Same as today's global Search. Download-state changes are handled (R12). Documented as a known limitation. |
| K4 | A stale dead row after a delete mid-search. | Re-run whenever the result set is download-filtered (D6). |
| K5 | Tracks-tab behaviour change (dim → filter) surprises users. | Confirmed in the design doc. The detail routes keep dimming. The locked chip and tooltip explain the offline state. |
| K6 | Queue/visible-list mismatch: the chip is on, but tapping a track queues streaming-only tracks. | Pass `downloadedOnly: effective` to `playFromQueue` (D7), tested in T2.2 #3. |
| K7 | Cap ≥ 999 breaks the hydrate `IN (…)` / sort fallback. | Cap = 100, a constant, plus a repository test at the cap. |
| K8 | Refactoring SearchPage regresses it. | Existing tests stay unmodified, plus new regression tests (T3.5). |
| K9 | Widget tests leak drift stream timers. | The `teardownTree` pattern. |
| K10 | The design doc is gitignored and may vanish. | This plan restates every requirement (§1.1). |

## 8. Completion criteria

Phase 3 is complete when **all** of the following hold:

1. Every task in §9 is `DONE`, with its acceptance criteria verified by the named tests.
2. Every requirement R1–R15 is traced to code and tests in §11.
3. `flutter test` (full) passes, `flutter analyze` is clean, and new files are `dart format`-clean (D8).
4. The backend test suite still passes (sanity; no backend changes).
5. T5.3 is recorded truthfully: what ran, and what couldn't.
6. All work is committed on `phase-3` with a clean working tree. Nothing is pushed and no PR is opened (not requested).

## 9. Progress tracker

Status: `TODO` · `IN PROGRESS` · `BLOCKED` · `DONE`

Commits are found with `git log --grep 'T<id>:'` (every task commit is titled `Phase 3 T<id>: …`).

| Task | Status | Commit | Evidence |
| --- | --- | --- | --- |
| T0.1 Branch + plan | DONE | (this commit) | Baseline 883 tests passing, analyze clean |
| T1.1 BrowseFilters | DONE | 8e8b79c | RED: 5/6 failed on stub (wrong values); GREEN: `browse_filters_test.dart` 6/6 |
| T1.2 FilterBar | DONE | 0934862 | RED: 5/5 failed on stub (no shape/selection/scroll/tooltip); GREEN: `filter_bar_test.dart` 5/5 |
| T1.3 Pagination suspend | DONE | `git log --grep T1.3:` | RED: 3/4 new failed on no-op stub (emissions delivered, trailing delivered, loadMore re-subscribed); 4th (resume) is a guard on existing refresh(). GREEN: mixin test 10/10; `test/ui` all pass |
| T2.1 Artists root chip | TODO | | |
| T2.2 Tracks root chip | TODO | | |
| T2.3 Filtered empty state | TODO | | |
| T3.1 search(types) | TODO | | |
| T3.2 withFreshDownloadState | TODO | | |
| T3.3 LibrarySearchController | TODO | | |
| T3.4 Search field + status | TODO | | |
| T3.5 SearchPage refactor | TODO | | |
| T4.1 Artists in-page search | TODO | | |
| T4.2 Tracks in-page search | TODO | | |
| T5.1 Full verification | TODO | | |
| T5.2 AppShell integration | TODO | | |
| T5.3 Live app smoke | TODO | | |
| T5.4 Trace + close-out | TODO | | |

**Next action:** T2.1.

## 10. Decision log

| ID | Decision | Why |
| --- | --- | --- |
| D1 | Chip bar and in-page search on the **Artists and Tracks root tabs** only. `AlbumsPage` stays detail-only and unchanged. | No root Albums tab exists (G1). The design doc explicitly forbids the chip bar on detail sub-routes (R6). Adding a tab is nav work that Phase 4 replaces. The components are page-agnostic. |
| D2 | `BrowseFilters` holds only filter-chip state (`downloaded`). The query is owned by `LibrarySearchController`. | Avoids two sources of truth for the query (raw text, debounced commit, and filters). The design doc's `{downloaded, query}` was an "e.g.". Phase 4's Home search is tap-to-navigate per the doc, so Home doesn't need the query in `BrowseFilters`. |
| D3 | A new `suspendPagination()` in the mixin, rather than reusing `disposePagination()`. | `disposePagination()` leaves the scroll listener able to call `loadMore()`, which re-subscribes (G2). |
| D4 | Global SearchPage "clear" becomes immediate instead of debounced. | A shared primitive gives one clear path. Clearing has no keystroke burst to coalesce. This is a deliberate improvement, logged per R15. |
| D5 | In-page search cap = 100 (`kInPageSearchCap`). | Inside the doc's 50–100 range and far below the 999 variable/sort-fallback limit (G5). |
| D6 | Re-search vs patch keys on "is the visible set download-filtered", not on "is offline". | The in-page chip can filter while online. Patching would leave a deleted download visible (G6). |
| D7 | Root Tracks tab passes the effective filter into `playFromQueue`. | The play queue must match the visible filtered list. The detail route keeps `false` (unchanged). |
| D8 | `dart format` is enforced on **new** files. In pre-existing files, new code follows the surrounding style and unrelated lines are never reformatted. | The existing tree isn't uniformly formatted, and running the formatter over a pre-existing file rewraps untouched code (discovered in T1.3), which bloats diffs. |
| D9 | A non-root `ArtistsPage` keeps the badge behaviour. | Only tests use it today. Keeps the R6 rule uniform (FilterBar iff `isRoot`) and the existing badge tests valid. |

## 11. Final verification results

_To be filled in by T5.x._
