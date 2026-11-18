#!/usr/bin/env python3
"""Writes suggestions.json, the independent fixture for 9B suggestions.

Phase 9 review §3 ("suggestion fixture") and 9-U05: every expected value here
is computed by this script from the rules of spec §2 (what a counted and a
qualified listen is) and §5 items 1-2 and para 3 (pools and selection). It
shares nothing with the repository's SQL or the Dart selection. Run
`python3 make_suggestions.py` from this folder after changing the data; the
Dart tests only read the JSON.

Rules applied:
- counted listen: kind 'play', entity_type 'track', seconds positive and
  finite, local_id <= boundary, start strictly before capturedNow (a future
  start is excluded until its time, as the statistics' all time);
- qualified: seconds >= min(30, length / 2) when length is positive and
  finite, else seconds >= 30;
- resolvable track: a tracks row and a trackmetadata row; the track's artist
  is its current artist_id when that artists row exists (else no artist:
  never grouped under an empty artist);
- Rediscover pool: resolvable tracks with >= 2 qualified counted listens, the
  latest qualified start <= now - 14 days; rank all-time counted seconds
  DESC, latest qualified start ASC, uuid ASC;
- artist pool: artists with >= 1 qualified counted listen started in
  [now - 30 days, now); rank their seconds in that window DESC, qualified
  plays in that window DESC, artist id ASC;
- artist candidates: resolvable catalog tracks of the artist with zero
  qualified counted listens in all time, ordered by title trimmed and
  lower-cased (unknown title last), then uuid;
- selection: drop the current track and, with the Downloaded filter, every
  track without a usable download, before any cap; Rediscover takes 20;
  artists without an eligible candidate are dropped, then 10 are taken, two
  candidates each, interleaved (all firsts in artist rank, then all
  seconds), capped at 20.
"""

import json
import math
from datetime import datetime, timezone

UTC = timezone.utc
DAY = 86_400_000
NOW = int(datetime(2026, 6, 15, 12, 0, tzinfo=UTC).timestamp() * 1000)

ARTISTS = [{"id": i, "name": f"Artist {i:02d}"} for i in range(1, 15)]
ARTISTS.append({"id": 20, "name": "Old favourites"})
# Artist 99 has no artists row (orphan parent).

TRACKS = []  # {uuid, artistId, title, downloaded}
NO_META = ["t-nometa"]  # tracks row without trackmetadata
EVENTS = []


def track(uuid, artist, title, downloaded=False, damaged=False):
    # A damaged download keeps its file but is not a usable download.
    TRACKS.append({"uuid": uuid, "artistId": artist, "title": title,
                   "downloaded": downloaded and not damaged,
                   "damaged": damaged})


def ev(ref, at, seconds, length=200.0, kind="play", etype="track", note=""):
    EVENTS.append({"ref": ref, "atMs": at, "seconds": seconds,
                   "length": length, "kind": kind, "entityType": etype,
                   "note": note})


# --- Rediscover ---------------------------------------------------------------
# rd01..rd24, artist 20, all listens long ago (60..120 days). Seconds give the
# rank; ties on seconds are broken by the latest qualified start, then uuid.
for i in range(1, 25):
    uuid = f"rd{i:02d}"
    track(uuid, 20, f"Favourite {i:02d}", downloaded=i in (3, 22, 23))
    base = NOW - (60 + i) * DAY
    # Two qualified listens; rd05/rd06 tie on seconds, rd07/rd08 tie on
    # seconds and latest start (uuid decides).
    secs = 1000 - 10 * i
    if i == 6:
        secs = 1000 - 10 * 5
    if i == 8:
        secs = 1000 - 10 * 7
    last = base
    if i == 8:
        last = NOW - (60 + 7) * DAY
    if i == 6:
        last = NOW - (60 + 5) * DAY - 1  # earlier than rd05's: ranks first
    ev(uuid, last - DAY, secs / 2)
    ev(uuid, last, secs / 2)

# Boundaries of the 14-day rule and of "at least two".
track("rd-at14", 20, "Exactly fourteen days", downloaded=True)
ev("rd-at14", NOW - 30 * DAY, 100.0)
ev("rd-at14", NOW - 14 * DAY, 100.0, note="exactly 14 days before now: in")
track("rd-in14", 20, "One ms short")
ev("rd-in14", NOW - 30 * DAY, 100.0)
ev("rd-in14", NOW - 14 * DAY + 1, 100.0, note="14 days minus 1 ms: out")
track("rd-one", 20, "One qualified")
ev("rd-one", NOW - 90 * DAY, 300.0)
for k in range(5):
    ev("rd-one", NOW - (80 + k) * DAY, 29.0, note="short: not qualified")
track("rd-unk", 20, "Unknown length")
ev("rd-unk", NOW - 50 * DAY, 30.0, None, note="unknown length: 30 s qualifies")
ev("rd-unk", NOW - 49 * DAY, 30.0, None)
track("rd-unk-short", 20, "Unknown length short")
ev("rd-unk-short", NOW - 50 * DAY, 30.0, None)
ev("rd-unk-short", NOW - 49 * DAY, 29.9, None, note="29.9 s, unknown: no")
track("rd-future", 20, "Future dated")
ev("rd-future", NOW - 40 * DAY, 60.0)
ev("rd-future", NOW - 39 * DAY, 60.0)
ev("rd-future", NOW + DAY, 60.0, note="future: excluded, so last = -39 d")
track("rd-click", 20, "Clicks only")
ev("rd-click", NOW - 40 * DAY, 60.0)
ev("rd-click", NOW - 39 * DAY, 60.0, kind="clicked", note="not a play")
ev("rd-click", NOW - 38 * DAY, 60.0, etype="album", note="not a track")
# Review r1 F2: a recent skip neither resets the 14-day clock nor drops the
# track; its seconds still count in the all-time rank.
track("rd-skip", 20, "Recently skipped")
ev("rd-skip", NOW - 40 * DAY, 60.0)
ev("rd-skip", NOW - 39 * DAY, 60.0)
ev("rd-skip", NOW - 2 * DAY, 10.0, note="unqualified skip inside 14 days")
# Review r1 F3: listens starting exactly at now are future: rd02 keeps its
# old last play, u05-a stays unplayed, artist 5's window seconds unchanged.
ev("rd02", NOW, 100.0, note="exactly now: not counted")
ev("u05-a", NOW, 100.0, note="exactly now: not counted")
# A tombstoned track (no catalog rows) and one without metadata: not
# resolvable, never suggested.
for ref in ("t-gone", "t-nometa"):
    for k in range(3):
        ev(ref, NOW - (70 + k) * DAY, 200.0)

# --- More from your artists ---------------------------------------------------
# Artists 1..10: one played track p{k} with a qualified listen inside the
# window; unplayed u{k}-a/b/c. Seconds decide the rank: artist k gets
# 1000 - 50 k seconds, except 5 and 6 which tie (6 has more qualified plays)
# and 7 and 8 which tie fully (id decides).
SECS = {k: 1000 - 50 * k for k in range(1, 11)}
SECS[6] = SECS[5]
SECS[8] = SECS[7]
for k in range(1, 11):
    track(f"p{k:02d}", k, f"Played {k:02d}")
    if k == 6:
        ev(f"p{k:02d}", NOW - 5 * DAY, SECS[k] - 100)
        ev(f"p{k:02d}", NOW - 4 * DAY, 100.0)
    else:
        ev(f"p{k:02d}", NOW - 5 * DAY, float(SECS[k]))
    # Unplayed candidates; titles chosen so title order != uuid order.
    # Review r1 F4: u10-a's download is damaged (not usable).
    track(f"u{k:02d}-a", k, "Zulu", downloaded=k in (1, 2, 9, 10),
          damaged=k == 10)
    track(f"u{k:02d}-b", k, "  alpha", downloaded=k in (2, 9))
    track(f"u{k:02d}-c", k, "Mike", downloaded=k in (2, 4))

# Artist 3: u03-b was listened to, but only briefly: still a candidate.
ev("u03-b", NOW - 3 * DAY, 10.0, note="positive short listen: zero qualified")
ev("u03-b", NOW - 200 * DAY, 15.0)
# Artist 4: u04-a has one qualified listen long ago: not a candidate.
ev("u04-a", NOW - 200 * DAY, 120.0, note="qualified long ago: played")
# Artist 1: u01-c has a qualified listen beyond the boundary (see BOUNDARY):
# not in the snapshot, so still a candidate.
LATE = [("u01-c", NOW - 2 * DAY, 120.0)]
# Artist 11: its only qualified listen starts exactly 30 days before now.
track("p11", 11, "Played 11")
ev("p11", NOW - 30 * DAY, 60.0, note="exactly 30 days: in the window")
track("u11-a", 11, "Only one", downloaded=True)
# Artist 12: qualified 1 ms before the window, short listens inside: out.
track("p12", 12, "Played 12")
ev("p12", NOW - 30 * DAY - 1, 500.0, note="30 days + 1 ms: outside")
ev("p12", NOW - 2 * DAY, 20.0, note="inside but not qualified")
track("u12-a", 12, "Never", downloaded=True)
# Artist 13: only short listens in the window: out.
track("p13", 13, "Played 13")
ev("p13", NOW - 2 * DAY, 25.0)
ev("p13", NOW - 3 * DAY, 25.0)
track("u13-a", 13, "Never", downloaded=True)
# Artist 14: recent and qualified, but no unplayed track: dropped.
track("p14", 14, "Played 14")
ev("p14", NOW - 1 * DAY, 2000.0)
# A future-dated qualified listen for artist 9's p09 adds nothing.
ev("p09", NOW + 2 * DAY, 5000.0, note="future: excluded")
# Orphan artist and no artist: listened, never grouped.
track("x-orph", 99, "Orphan")
ev("x-orph", NOW - 1 * DAY, 3000.0)
track("u-orph", 99, "Orphan unplayed", downloaded=True)
track("x-none", None, "No artist")
ev("x-none", NOW - 1 * DAY, 3000.0)
track("u-none", None, "No artist unplayed", downloaded=True)

# Local ids: EVENTS in order, then LATE beyond the boundary.
for i, e in enumerate(EVENTS):
    e["localId"] = i + 1
BOUNDARY = len(EVENTS)
for ref, at, secs in LATE:
    ev(ref, at, secs, note="beyond the snapshot boundary")
    EVENTS[-1]["localId"] = len(EVENTS)

# --- The rules ----------------------------------------------------------------
BY_UUID = {t["uuid"]: t for t in TRACKS}
ARTIST_IDS = {a["id"] for a in ARTISTS}


def counted(e):
    s = e["seconds"]
    return (e["kind"] == "play" and e["entityType"] == "track"
            and s is not None and math.isfinite(s) and s > 0
            and e["localId"] <= BOUNDARY and e["atMs"] < NOW)


def qualified(e):
    length = e["length"]
    if length is not None and math.isfinite(length) and length > 0:
        return e["seconds"] >= min(30.0, length / 2)
    return e["seconds"] >= 30.0


def micros(seconds):
    return int(round(seconds * 1_000_000))


def artist_of(uuid):
    t = BY_UUID.get(uuid)
    if t is None or t["artistId"] not in ARTIST_IDS:
        return None
    return t["artistId"]


C = [e for e in EVENTS if counted(e)]

rediscover = []
for uuid, t in BY_UUID.items():
    mine = [e for e in C if e["ref"] == uuid]
    q = [e for e in mine if qualified(e)]
    if len(q) < 2:
        continue
    last = max(e["atMs"] for e in q)
    if last > NOW - 14 * DAY:
        continue
    rediscover.append({
        "uuid": uuid,
        "micros": sum(micros(e["seconds"]) for e in mine),
        "qualifiedPlays": len(q),
        "lastQualifiedAtMs": last,
        "downloaded": t["downloaded"],
    })
rediscover.sort(key=lambda r: (-r["micros"], r["lastQualifiedAtMs"],
                               r["uuid"]))

played = {e["ref"] for e in C if qualified(e)}
window = [e for e in C if NOW - 30 * DAY <= e["atMs"] < NOW]
artists = []
for a in sorted(ARTIST_IDS):
    mine = [e for e in window if artist_of(e["ref"]) == a]
    q = [e for e in mine if qualified(e)]
    if not q:
        continue
    cands = [t for t in TRACKS if t["artistId"] == a
             and t["uuid"] not in played]
    artists.append({
        "artistId": a,
        "micros": sum(micros(e["seconds"]) for e in mine),
        "qualifiedPlays": len(q),
        "candidates": [{"uuid": t["uuid"], "title": t["title"],
                        "downloaded": t["downloaded"]} for t in cands],
    })
artists.sort(key=lambda r: (-r["micros"], -r["qualifiedPlays"],
                            r["artistId"]))


def title_key(c):
    t = c["title"]
    return (1, "", c["uuid"]) if t is None else (0, t.strip().lower(),
                                                  c["uuid"])


def select(current, downloaded_only):
    def ok(uuid, dl):
        return uuid != current and (dl or not downloaded_only)

    rd = [r["uuid"] for r in rediscover if ok(r["uuid"], r["downloaded"])][:20]
    picks = []
    for a in artists:
        cands = sorted((c for c in a["candidates"]
                        if ok(c["uuid"], c["downloaded"])), key=title_key)
        if cands:
            picks.append([c["uuid"] for c in cands[:2]])
    picks = picks[:10]
    more = [p[0] for p in picks] + [p[1] for p in picks if len(p) > 1]
    return {"rediscover": rd, "moreFromArtists": more[:20]}


CASES = [
    {"name": "no current track, all music", "currentUuid": None,
     "downloaded": False},
    {"name": "Downloaded only", "currentUuid": None, "downloaded": True},
    {"name": "current track is the best Rediscover candidate",
     "currentUuid": "rd01", "downloaded": False},
    {"name": "current track is an artist's first downloaded candidate",
     "currentUuid": "u01-a", "downloaded": True},
    {"name": "current track removes an artist's only candidate",
     "currentUuid": "u11-a", "downloaded": True},
]
for c in CASES:
    c["expected"] = select(c["currentUuid"], c["downloaded"])

out = {
    "_doc": "Generated by make_suggestions.py; do not edit by hand.",
    "capturedNowMs": NOW,
    "boundary": BOUNDARY,
    "catalog": {"artists": ARTISTS, "tracks": TRACKS,
                "tracksWithoutMetadata": NO_META},
    "events": EVENTS,
    "expected": {"rediscover": rediscover, "artists": artists},
    "cases": CASES,
}
with open("suggestions.json", "w") as f:
    json.dump(out, f, indent=1, sort_keys=False)
    f.write("\n")

# A short readable summary for the reviewer.
print("boundary", BOUNDARY, "events", len(EVENTS))
print("rediscover", len(rediscover), [r["uuid"] for r in rediscover])
for a in artists:
    print("artist", a["artistId"], a["micros"], a["qualifiedPlays"],
          sorted(c["uuid"] for c in a["candidates"]))
for c in CASES:
    print(c["name"], json.dumps(c["expected"]))
