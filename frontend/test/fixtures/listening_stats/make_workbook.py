#!/usr/bin/env python3
"""Writes workbook.json, the independent fixture workbook for listening stats.

Phase 9 review §3: every expected value here is computed from the measurement
contract (spec §2) by this script, which shares nothing with the repository's
SQL. Run `python3 make_workbook.py` from this folder after changing the data;
the Dart tests only read the JSON.

Definitions applied (spec §2, §3 and the 9A.1a plan):
- a counted listen: kind 'play', entity_type 'track', seconds positive and
  finite, local_id <= the case boundary, start inside the half-open range and
  strictly before capturedNow;
- qualified: seconds >= min(30, length / 2) when length is positive and
  finite, else seconds >= 30 (unknown, zero or negative length);
- resolvable: the track has both a tracks row and a trackmetadata row;
  anything else is unavailable (counted in totals, absent from rankings);
- artist group: the track's current artist_id when that artist row exists;
  album group: the track's current album_id when the album row and its album
  artist row exist (the SC-12 projections' joins);
- ranks: seconds DESC, qualified DESC, id ASC; top 10;
- future: a would-be counted listen (kind, type, seconds, boundary) whose
  start is >= capturedNow, counted whatever the range;
- buckets: UTC days for rolling ranges, UTC months for years and all time,
  covering [range start, min(range end, now)); all time starts at the month
  of the earliest counted listen and is capped to the latest 24 months.
"""

import json
import math
from datetime import datetime, timedelta, timezone

UTC = timezone.utc


def ms(iso):
    return int(datetime.strptime(iso, "%Y-%m-%dT%H:%M:%S.%fZ")
               .replace(tzinfo=UTC).timestamp() * 1000)


def iso(m):
    return datetime.fromtimestamp(m / 1000, UTC).strftime(
        "%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


CATALOG = {
    "artists": [
        {"id": 1, "name": "Aria"},
        {"id": 2, "name": "Bram"},
        {"id": 3, "name": "Cleo"},
    ],
    "albums": [
        {"id": 10, "artistId": 1, "name": "One"},
        {"id": 11, "artistId": 1, "name": "Two"},
        {"id": 20, "artistId": 2, "name": "Same"},
        {"id": 30, "artistId": 3, "name": "Fillers"},
        # Album whose album artist row is missing: not a resolvable album.
        {"id": 40, "artistId": 98, "name": "Orphaned album"},
    ],
    "tracks": [
        {"uuid": "t-a", "artistId": 1, "albumId": 10, "title": "Song"},
        {"uuid": "t-b", "artistId": 1, "albumId": 11, "title": "Song"},
        {"uuid": "t-c", "artistId": 2, "albumId": 20, "title": "Other"},
        {"uuid": "t-d", "artistId": 2, "albumId": 20, "title": "Tie"},
        {"uuid": "t-e", "artistId": 3, "albumId": 30, "title": "Tie"},
        # Orphan parents: artist row 99 does not exist; no parents at all.
        {"uuid": "t-0rph", "artistId": 99, "albumId": 10, "title": "Orphan"},
        {"uuid": "t-none", "artistId": None, "albumId": None, "title": "Bare"},
        {"uuid": "t-oalb", "artistId": 3, "albumId": 40, "title": "Lost album"},
    ] + [
        {"uuid": f"t-f{i:02d}", "artistId": 3, "albumId": 30,
         "title": f"Filler {i}"}
        for i in range(1, 12)
    ],
    # A tracks row without trackmetadata: unresolved.
    "tracksWithoutMetadata": ["t-nometa"],
}
# Events for t-gone (deleted by a tombstone) and t-never (never synced) have
# no catalog rows at all.

E = []


def ev(uuid, at, seconds, length=200.0, ref="t-a", kind="play",
       etype="track", pending=False, revision=None, note=""):
    E.append({"uuid": uuid, "kind": kind, "entityType": etype, "ref": ref,
              "at": at, "seconds": seconds, "length": length,
              "pendingUpload": pending, "serverRevision": revision,
              "note": note})


# --- 2025-12-28 .. 2026-01-03: the rolling-window week -----------------------
# Thresholds with a 40 s track (threshold 20) and a 200 s track (30).
ev("e-thr-below-40", "2025-12-28T10:00:00.000Z", 19.999, 40.0, "t-c",
   note="below min(30, 40/2) = 20")
ev("e-thr-equal-40", "2025-12-28T11:00:00.000Z", 20.0, 40.0, "t-c",
   note="exactly 20: qualifies")
ev("e-thr-above-40", "2025-12-28T12:00:00.000Z", 20.001, 40.0, "t-c")
ev("e-thr-below-200", "2025-12-29T10:00:00.000Z", 29.999, 200.0, "t-a")
ev("e-thr-equal-200", "2025-12-29T11:00:00.000Z", 30.0, 200.0, "t-a")
# Unknown, zero and negative lengths all require 30 s; never treated as 0.
ev("e-unk-below", "2025-12-29T12:00:00.000Z", 29.5, None, "t-b",
   note="unknown length: needs 30")
ev("e-unk-equal", "2025-12-29T13:00:00.000Z", 30.0, None, "t-b")
ev("e-zero-len", "2025-12-29T14:00:00.000Z", 25.0, 0.0, "t-b",
   note="zero length is not a positive known duration: needs 30")
ev("e-neg-len", "2025-12-29T15:00:00.000Z", 25.0, -10.0, "t-b")
ev("e-inf-len", "2025-12-29T16:00:00.000Z", 29.0, math.inf, "t-b",
   note="infinite length is not finite: needs 30")
# Seconds that never count.
ev("e-zero-sec", "2025-12-30T10:00:00.000Z", 0.0, 200.0, "t-a")
ev("e-neg-sec", "2025-12-30T11:00:00.000Z", -5.0, 200.0, "t-a")
ev("e-null-sec", "2025-12-30T12:00:00.000Z", None, 200.0, "t-a")
ev("e-inf-sec", "2025-12-30T13:00:00.000Z", math.inf, 200.0, "t-a")
# Rewind: more seconds than the length is still one listen.
ev("e-rewind", "2025-12-30T14:00:00.000Z", 450.0, 200.0, "t-c",
   note="rewinds: 450 s of a 200 s track is 1 qualified play")
# Two devices at the same moment: both count; one pulled, one pending upload.
# Equal rank with t-d (below): t-e gets the same seconds and qualified
# count, inserted first so insertion order cannot pass for uuid order.
ev("e-tie-e1", "2025-12-30T16:00:00.000Z", 100.0, 200.0, "t-e")
ev("e-tie-e2", "2025-12-30T17:00:00.000Z", 100.0, 200.0, "t-e")
ev("e-dev1", "2025-12-30T15:00:00.000Z", 100.0, 200.0, "t-d", pending=True,
   note="device 1, not yet uploaded")
ev("e-dev2", "2025-12-30T15:00:00.000Z", 100.0, 200.0, "t-d", revision=7,
   note="device 2, pulled")
# Same seconds as the t-d/t-e pair, fewer qualified plays; its uuid sorts
# first, so only the qualified-plays tie-break puts it after them.
ev("e-tie-orph", "2025-12-30T18:00:00.000Z", 200.0, 200.0, "t-0rph")
ev("e-none", "2025-12-30T19:00:00.000Z", 60.0, 200.0, "t-none")
ev("e-oalb", "2025-12-30T20:00:00.000Z", 60.0, 200.0, "t-oalb")
# Not metrics: other kinds and entity types, even with seconds.
ev("e-clicked", "2025-12-31T09:00:00.000Z", 500.0, 200.0, "t-a",
   kind="clicked")
ev("e-skip", "2025-12-31T09:30:00.000Z", 500.0, 200.0, "t-a", kind="skip")
ev("e-album-play", "2025-12-31T10:00:00.000Z", 500.0, 200.0, "srv:10",
   etype="album")
# Unavailable: deleted, never synced, and a tracks row without metadata.
ev("e-gone-1", "2025-12-31T11:00:00.000Z", 40.0, 200.0, "t-gone")
ev("e-gone-2", "2025-12-31T12:00:00.000Z", 10.0, 200.0, "t-gone")
ev("e-never", "2025-12-31T13:00:00.000Z", 35.0, None, "t-never")
ev("e-nometa", "2025-12-31T14:00:00.000Z", 31.0, 60.0, "t-nometa")
# Year change: the last millisecond of 2025 and the first of 2026.
ev("e-dec31", "2025-12-31T23:59:59.999Z", 50.0, 200.0, "t-a")
ev("e-jan1", "2026-01-01T00:00:00.000Z", 60.0, 200.0, "t-a")
# UTC midnight: a long listen just before midnight stays on its start day.
ev("e-pre-midnight", "2026-01-01T23:59:00.000Z", 600.0, 200.0, "t-b",
   note="crosses midnight; belongs entirely to 2026-01-01")
ev("e-midnight", "2026-01-02T00:00:00.000Z", 45.0, 90.0, "t-b",
   note="exactly at midnight: 2026-01-02")
ev("e-jan3", "2026-01-03T11:59:59.999Z", 70.0, 200.0, "t-c",
   note="1 ms before the main capturedNow")
# Rolling-window edge for the main capturedNow (2026-01-03T12:00Z):
# exactly now - 7 days is inside, 1 ms earlier is outside.
ev("e-7d-edge-in", "2025-12-27T12:00:00.000Z", 33.0, 200.0, "t-none")
ev("e-7d-edge-out", "2025-12-27T11:59:59.999Z", 34.0, 200.0, "t-none")
# Future: exactly capturedNow and later are excluded and counted.
ev("e-at-now", "2026-01-03T12:00:00.000Z", 80.0, 200.0, "t-a")
ev("e-future", "2026-02-01T00:00:00.000Z", 90.0, 200.0, "t-a")
ev("e-future-click", "2026-02-01T00:00:00.000Z", 90.0, 200.0, "t-a",
   kind="clicked", note="not a play: not in the future diagnostic")

# --- Earlier history ---------------------------------------------------------
ev("e-30d-edge-in", "2025-12-04T12:00:00.000Z", 41.0, 200.0, "t-oalb")
ev("e-30d-edge-out", "2025-12-04T11:59:59.999Z", 42.0, 200.0, "t-oalb")
ev("e-jan2025", "2025-01-01T00:00:00.000Z", 300.0, 200.0, "t-c")
# 2024: t-e (artist 3, album 30) ties t-c (artist 2, album 20) exactly on
# every level; inserted first so only id order can put t-c, 2 and 20 first.
ev("e-2024-tie", "2024-07-01T00:00:00.000Z", 30.0, 200.0, "t-e")
ev("e-dec2024", "2024-12-31T23:59:59.999Z", 30.0, 200.0, "t-c")
ev("e-old", "2023-06-15T08:00:00.000Z", 1000.0, 200.0, "t-c",
   note="older than the 24-month chart window: totals only")
# Eleven filler tracks in June 2025: ties on seconds broken by uuid, and more
# than ten candidates.
for i in range(1, 12):
    ev(f"e-fill-{i:02d}", f"2025-06-{i:02d}T12:00:00.000Z", 120.0, 300.0,
       f"t-f{i:02d}")
# Late arrivals: inserted after the boundary used by the boundary case.
ev("e-late-1", "2025-12-29T09:00:00.000Z", 500.0, 200.0, "t-a",
   note="local_id above the boundary case's boundary")
ev("e-late-2", "2025-12-29T09:30:00.000Z", 500.0, 200.0, "t-b")

for i, e in enumerate(E):
    e["localId"] = i + 1
    e["atMs"] = ms(e["at"])

TRACKS = {t["uuid"]: t for t in CATALOG["tracks"]}
ARTISTS = {a["id"] for a in CATALOG["artists"]}
ALBUMS = {a["id"]: a for a in CATALOG["albums"]}


def finite_pos(x):
    return x is not None and math.isfinite(x) and x > 0


def is_metric(e):
    return (e["kind"] == "play" and e["entityType"] == "track"
            and finite_pos(e["seconds"]))


def qualifies(e):
    length = e["length"]
    need = min(30.0, length / 2) if finite_pos(length) else 30.0
    return e["seconds"] >= need


def artist_of(uuid):
    t = TRACKS.get(uuid)
    if t is None or t["artistId"] not in ARTISTS:
        return None
    return t["artistId"]


def album_of(uuid):
    t = TRACKS.get(uuid)
    if t is None or t["albumId"] not in ALBUMS:
        return None
    a = ALBUMS[t["albumId"]]
    return a["id"] if a["artistId"] in ARTISTS else None


def day(m):
    return datetime.fromtimestamp(m / 1000, UTC).strftime("%Y-%m-%d")


def month(m):
    return datetime.fromtimestamp(m / 1000, UTC).strftime("%Y-%m")


def month_start(y, mo):
    return int(datetime(y, mo, 1, tzinfo=UTC).timestamp() * 1000)


def add_months(y, mo, n):
    k = y * 12 + (mo - 1) + n
    return k // 12, k % 12 + 1


def window(rng, now):
    t = rng["type"]
    if t == "rolling":
        return now - rng["days"] * 86400000, now, "day"
    if t == "thisYear":
        y = datetime.fromtimestamp(now / 1000, UTC).year
        return month_start(y, 1), month_start(y + 1, 1), "month"
    if t == "year":
        return month_start(rng["year"], 1), month_start(rng["year"] + 1, 1), \
            "month"
    return None, now, "month"


def ranked(groups):
    rows = [{"id": k, "seconds": v[0], "qualifiedPlays": v[1]}
            for k, v in groups.items()]
    # id ASC, then qualified DESC, then seconds DESC (stable sorts).
    rows.sort(key=lambda r: r["id"])
    rows.sort(key=lambda r: r["qualifiedPlays"], reverse=True)
    rows.sort(key=lambda r: r["seconds"], reverse=True)
    return rows[:10]


def expect(case):
    now = case["capturedNowMs"]
    boundary = case["boundary"] if case["boundary"] is not None else len(E)
    start, end, unit = window(case["range"], now)
    eff_end = min(end, now)
    base = [e for e in E if is_metric(e) and e["localId"] <= boundary]
    future = [e for e in base if e["atMs"] >= now]
    inr = [e for e in base
           if (start is None or e["atMs"] >= start) and e["atMs"] < eff_end]
    secs = sum(e["seconds"] for e in inr)
    qual = [e for e in inr if qualifies(e)]
    unavail = [e for e in inr if e["ref"] not in TRACKS]
    tracks, artists, albums = {}, {}, {}
    for e in inr:
        q = 1 if qualifies(e) else 0
        if e["ref"] in TRACKS:
            g = tracks.setdefault(e["ref"], [0.0, 0])
            g[0] += e["seconds"]; g[1] += q
            ar = artist_of(e["ref"])
            if ar is not None:
                g = artists.setdefault(ar, [0.0, 0])
                g[0] += e["seconds"]; g[1] += q
            al = album_of(e["ref"])
            if al is not None:
                g = albums.setdefault(al, [0.0, 0])
                g[0] += e["seconds"]; g[1] += q
    # Buckets.
    buckets = []
    capped = False
    if unit == "day":
        d = datetime.fromtimestamp(start / 1000, UTC).replace(
            hour=0, minute=0, second=0, microsecond=0)
        last = datetime.fromtimestamp((eff_end - 1) / 1000, UTC)
        while d.date() <= last.date():
            buckets.append(d.strftime("%Y-%m-%d"))
            d += timedelta(days=1)
        key = day
    else:
        key = month
        if start is None:
            if inr:
                first = min(e["atMs"] for e in inr)
                fy, fm = map(int, month(first).split("-"))
            else:
                fy = None
            ly, lm = map(int, month(eff_end - 1).split("-"))
            cy, cm = add_months(ly, lm, -23)
            if fy is not None:
                if (fy, fm) < (cy, cm):
                    capped = True
                    fy, fm = cy, cm
                y, mo = fy, fm
                while (y, mo) <= (ly, lm):
                    buckets.append(f"{y:04d}-{mo:02d}")
                    y, mo = add_months(y, mo, 1)
        elif start < eff_end:
            y, mo = map(int, month(start).split("-"))
            ly, lm = map(int, month(eff_end - 1).split("-"))
            while (y, mo) <= (ly, lm):
                buckets.append(f"{y:04d}-{mo:02d}")
                y, mo = add_months(y, mo, 1)
    bsum = {b: 0.0 for b in buckets}
    for e in inr:
        k = key(e["atMs"])
        if k in bsum:
            bsum[k] += e["seconds"]
    return {
        "listeningSeconds": secs,
        "qualifiedPlays": len(qual),
        "uniqueTracks": len({e["ref"] for e in qual}),
        "activeDays": len({day(e["atMs"]) for e in inr}),
        "unavailable": {
            "listeningSeconds": sum(e["seconds"] for e in unavail),
            "qualifiedPlays": len([e for e in unavail if qualifies(e)]),
        },
        "futureTimestampCount": len(future),
        "bucketUnit": unit,
        "buckets": [{"label": b, "seconds": bsum[b]} for b in buckets],
        "chartCapped": capped,
        "topTracks": ranked(tracks),
        "topArtists": ranked(artists),
        "topAlbums": ranked(albums),
    }


NOW = "2026-01-03T12:00:00.000Z"
MIDNIGHT = "2026-01-02T00:00:00.000Z"
LATE_BOUNDARY = next(e["localId"] for e in E if e["uuid"] == "e-late-1") - 1
CASES = [
    {"name": "7 days", "capturedNow": NOW, "range": {"type": "rolling", "days": 7}},
    {"name": "30 days", "capturedNow": NOW, "range": {"type": "rolling", "days": 30}},
    {"name": "this UTC year (2026)", "capturedNow": NOW, "range": {"type": "thisYear"}},
    {"name": "chosen year 2025", "capturedNow": NOW, "range": {"type": "year", "year": 2025}},
    {"name": "chosen year 2024", "capturedNow": NOW, "range": {"type": "year", "year": 2024}},
    {"name": "chosen future year 2027", "capturedNow": NOW, "range": {"type": "year", "year": 2027}},
    {"name": "all time", "capturedNow": NOW, "range": {"type": "allTime"}},
    {"name": "7 days at UTC midnight", "capturedNow": MIDNIGHT, "range": {"type": "rolling", "days": 7}},
    {"name": "boundary excludes late arrivals (all time)", "capturedNow": NOW,
     "range": {"type": "allTime"}, "boundary": LATE_BOUNDARY},
    {"name": "boundary excludes late arrivals (7 days)", "capturedNow": NOW,
     "range": {"type": "rolling", "days": 7}, "boundary": LATE_BOUNDARY},
]
for c in CASES:
    c.setdefault("boundary", None)
    c["capturedNowMs"] = ms(c["capturedNow"])
    c["expected"] = expect(c)


def jnum(x):
    if x is None:
        return None
    if isinstance(x, float) and math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    return x


out = {
    "about": __doc__.strip().splitlines()[0],
    "definitions": __doc__.strip().split("\n\n", 2)[2],
    "catalog": CATALOG,
    "events": [
        {**e, "seconds": jnum(e["seconds"]), "length": jnum(e["length"]),
         "expect": {
             "metric": is_metric(e),
             "qualified": is_metric(e) and qualifies(e),
             "unavailable": is_metric(e) and e["ref"] not in TRACKS,
             "utcDay": day(e["atMs"]), "utcMonth": month(e["atMs"]),
         }}
        for e in E
    ],
    "cases": CASES,
}
with open("workbook.json", "w") as f:
    json.dump(out, f, indent=1)
    f.write("\n")
print(f"{len(E)} events, {len(CASES)} cases")
