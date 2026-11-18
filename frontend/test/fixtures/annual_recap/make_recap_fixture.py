#!/usr/bin/env python3
"""Writes the annual-recap fixture (recap_fixture.json) and its golden exports.

Phase 9 review §3 / 9-U06: every expected value and the golden JSON text are
computed here from the measurement contract (spec §2) and the recap rules
(spec §6), sharing nothing with the app's SQL or Dart. Run
`python3 make_recap_fixture.py` from this folder after changing the data; the
Dart tests only read what it writes.

Rules applied:
- a counted listen: kind 'play', entity_type 'track', seconds positive and
  finite, local_id <= the boundary, start in [1 Jan, next 1 Jan) UTC and
  strictly before capturedNow;
- qualified: seconds >= min(30, length / 2) when length is positive and
  finite, else seconds >= 30;
- resolvable: the track has catalog rows; anything else is unavailable;
- ranks: seconds DESC, qualified DESC, id ASC; a recap shows the top five;
- months: January to the month before the counted end, zero-filled;
- busiest month: absent when the year's time is 0, else the most time, the
  earliest month on a tie;
- "Year so far": the year is capturedNow's UTC year;
- generated: capturedNow.

The fixture seconds are multiples of 0.5, so every sum is exact in binary
floating point and the golden text does not depend on summation order.
"""

import json
import math
from datetime import datetime, timezone

UTC = timezone.utc

SCHEMA = 1
KIND = "osml-annual-recap"
NOTES = [
    "All times are UTC. A listen counts in the day, month and year in which "
    "it started.",
    "Listening time is recorded playback time. Rewinding and playing on two "
    "devices at once both add time, and a listen cut short when the app was "
    "stopped may lose its last seconds.",
    "A qualified play is a listen of at least 30 seconds, or of at least half "
    "the track when the track is shorter than a minute. This is OSML's own "
    "threshold.",
    "Names are the library's current metadata when the recap was generated, "
    "not the names at the time of listening.",
    "Unavailable time is listening to tracks that were deleted or are not in "
    "this device's library. It is included in the totals but in no top list.",
    "Counted from the listening history on this device when the recap was "
    "generated. Listens from other devices that had not synced yet are not "
    "included.",
]
YEAR_SO_FAR_NOTE = ("Year so far: listens are counted up to the generated "
                    "time.")


def ms(iso_text):
    return int(datetime.strptime(iso_text, "%Y-%m-%dT%H:%M:%S.%fZ")
               .replace(tzinfo=UTC).timestamp() * 1000)


def iso(m):
    return datetime.fromtimestamp(m / 1000, UTC).strftime(
        "%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


ARTISTS = [
    {"id": 1, "name": "Aria"},
    {"id": 2, "name": 'Bram "B" Lee'},
    {"id": 3, "name": "Cléo"},
]
ALBUMS = [
    {"id": 10, "artistId": 1, "name": "First Light"},
    {"id": 20, "artistId": 2, "name": "Second Wind"},
    {"id": 30, "artistId": 3, "name": "Third/Last"},
]
ARTIST_NAME = {a["id"]: a["name"] for a in ARTISTS}
ALBUM_BY_ID = {a["id"]: a for a in ALBUMS}


def t(uuid, artist, album, title):
    return {"uuid": uuid, "artistId": artist, "albumId": album,
            "title": title, "artistName": ARTIST_NAME[artist],
            "albumName": ALBUM_BY_ID[album]["name"]}


TRACKS = [
    t("t-a", 1, 10, "Alpha"),
    t("t-b", 1, 10, "Beta"),
    t("t-c", 2, 20, "Gamma"),
    t("t-d", 2, 20, "Delta"),
    t("t-e", 3, 30, "Epsilon"),
    t("t-f", 3, 30, "Zeta"),
    t("t-g", 3, 30, "Eta"),
]
TRACK_BY_UUID = {x["uuid"]: x for x in TRACKS}
CATALOG = {"artists": ARTISTS, "albums": ALBUMS, "tracks": TRACKS,
           "tracksWithoutMetadata": []}

E = []


def ev(uuid, at, seconds, ref, length=200.0, kind="play", note=""):
    E.append({"uuid": uuid, "kind": kind, "entityType": "track", "ref": ref,
              "at": at, "seconds": seconds, "length": length,
              "pendingUpload": False, "serverRevision": None, "note": note})


# 2025, the prior year. March and July tie at 600 s (March wins); t-e and
# t-f tie at 250 s and one qualified play across the top-five cut (t-e wins).
ev("r-01", "2025-01-01T00:00:00.000Z", 120.5, "t-a", note="first ms of 2025")
ev("r-02", "2025-03-10T09:00:00.000Z", 300.0, "t-a")
ev("r-03", "2025-03-20T21:30:00.000Z", 300.0, "t-b")
ev("r-04", "2025-05-01T08:00:00.000Z", 250.0, "t-e")
ev("r-05", "2025-07-04T18:00:00.000Z", 350.0, "t-c")
ev("r-06", "2025-07-05T18:00:00.000Z", 250.0, "t-f")
ev("r-07", "2025-09-09T07:00:00.000Z", 280.0, "t-d")
ev("r-08", "2025-09-10T07:00:00.000Z", 20.0, "t-g", note="not qualified")
ev("r-09", "2025-11-11T10:00:00.000Z", 90.0, "t-gone",
   note="deleted track: unavailable, qualified")
ev("r-10", "2025-11-12T10:00:00.000Z", 10.0, "t-gone",
   note="deleted track: unavailable, not qualified")
ev("r-11", "2025-12-31T23:59:59.999Z", 50.0, "t-c", note="last ms of 2025")
ev("r-12", "2025-06-01T12:00:00.000Z", 500.0, "t-a", kind="clicked",
   note="a click is not a listen")
ev("r-13", "2025-06-02T12:00:00.000Z", None, "t-a",
   note="unknown seconds: not a listen")
# Outside 2025.
ev("r-14", "2024-12-31T23:59:59.999Z", 999.0, "t-a", note="last ms of 2024")
# 2026, the current year (capturedNow 2026-03-15T12:00Z).
ev("r-15", "2026-01-01T00:00:00.000Z", 60.0, "t-b", note="first ms of 2026")
ev("r-16", "2026-02-14T12:00:00.000Z", 200.0, "t-d")
ev("r-17", "2026-03-15T11:59:59.999Z", 30.0, "t-b", note="1 ms before now")
ev("r-18", "2026-03-15T12:00:00.000Z", 500.0, "t-a",
   note="at capturedNow: future, not counted")
ev("r-19", "2026-06-01T00:00:00.000Z", 500.0, "t-a", note="future")
# Above every case's boundary: never counted.
ev("r-20", "2025-08-08T08:00:00.000Z", 1000.0, "t-a",
   note="local_id above the boundary")

for i, e in enumerate(E):
    e["localId"] = i + 1
    e["atMs"] = ms(e["at"])

NOW = "2026-03-15T12:00:00.000Z"
BOUNDARY = len(E) - 1


def finite_pos(x):
    return x is not None and math.isfinite(x) and x > 0


def qualifies(e):
    length = e["length"]
    need = min(30.0, length / 2) if finite_pos(length) else 30.0
    return e["seconds"] >= need


def year_start(y):
    return ms(f"{y:04d}-01-01T00:00:00.000Z")


def month_start(y, mo):
    return ms(f"{y:04d}-{mo:02d}-01T00:00:00.000Z")


def ranked(groups):
    rows = [{"id": k, "seconds": v[0], "qualifiedPlays": v[1]}
            for k, v in groups.items()]
    rows.sort(key=lambda r: r["id"])
    rows.sort(key=lambda r: r["qualifiedPlays"], reverse=True)
    rows.sort(key=lambda r: r["seconds"], reverse=True)
    return rows[:5]


def recap(year, now, boundary):
    start, end = year_start(year), year_start(year + 1)
    counted_end = min(end, now)
    inr = [e for e in E
           if e["kind"] == "play" and e["entityType"] == "track"
           and finite_pos(e["seconds"]) and e["localId"] <= boundary
           and start <= e["atMs"] < counted_end]
    qual = [e for e in inr if qualifies(e)]
    unavail = [e for e in inr if e["ref"] not in TRACK_BY_UUID]
    tracks, artists, albums = {}, {}, {}
    for e in inr:
        tr = TRACK_BY_UUID.get(e["ref"])
        if tr is None:
            continue
        q = 1 if qualifies(e) else 0
        for groups, key in ((tracks, tr["uuid"]), (artists, tr["artistId"]),
                            (albums, tr["albumId"])):
            g = groups.setdefault(key, [0.0, 0])
            g[0] += e["seconds"]
            g[1] += q
    months = []
    if start < counted_end:
        last = datetime.fromtimestamp((counted_end - 1) / 1000, UTC)
        for mo in range(1, last.month + 1):
            s = month_start(year, mo)
            n = month_start(year + 1, 1) if mo == 12 else month_start(year,
                                                                       mo + 1)
            secs = sum(e["seconds"] for e in inr if s <= e["atMs"] < n)
            months.append({"month": f"{year:04d}-{mo:02d}", "startMs": s,
                           "endMs": n, "seconds": float(secs)})
    total = float(sum(e["seconds"] for e in inr))
    busiest = None
    if total > 0:
        for m in months:  # earliest wins: only a strictly larger one replaces
            if busiest is None or m["seconds"] > busiest["seconds"]:
                busiest = m
    year_so_far = datetime.fromtimestamp(now / 1000, UTC).year == year
    return {
        "year": year,
        "yearSoFar": year_so_far,
        "startMs": start, "endMs": end, "countedEndMs": counted_end,
        "generatedMs": now,
        "listeningSeconds": total,
        "qualifiedPlays": len(qual),
        "uniqueTracks": len({e["ref"] for e in qual}),
        "activeDays": len({datetime.fromtimestamp(e["atMs"] / 1000, UTC)
                           .date() for e in inr}),
        "unavailable": {
            "listeningSeconds": float(sum(e["seconds"] for e in unavail)),
            "qualifiedPlays": len([e for e in unavail if qualifies(e)]),
        },
        "months": months,
        "busiestMonth": busiest["month"] if busiest else None,
        "topTracks": ranked(tracks),
        "topArtists": ranked(artists),
        "topAlbums": ranked(albums),
    }


def export(r):
    """The golden export of one recap: schema 1, keys in this fixed order."""
    def secs(x):
        return float(x)

    busiest = None
    if r["busiestMonth"] is not None:
        m = next(m for m in r["months"] if m["month"] == r["busiestMonth"])
        busiest = {"month": m["month"], "start_utc": iso(m["startMs"]),
                   "end_utc": iso(m["endMs"]),
                   "listening_seconds": secs(m["seconds"])}
    out = {
        "schema": SCHEMA,
        "kind": KIND,
        "year": r["year"],
        "year_so_far": r["yearSoFar"],
        "time_zone": "UTC",
        "range": {
            "start_utc": iso(r["startMs"]),
            "end_utc": iso(r["endMs"]),
            "counted_until_utc": iso(r["countedEndMs"]),
        },
        "generated_at_utc": iso(r["generatedMs"]),
        "metrics": {
            "listening_seconds": secs(r["listeningSeconds"]),
            "qualified_plays": r["qualifiedPlays"],
            "unique_tracks": r["uniqueTracks"],
            "active_days": r["activeDays"],
        },
        "unavailable": {
            "listening_seconds": secs(r["unavailable"]["listeningSeconds"]),
            "qualified_plays": r["unavailable"]["qualifiedPlays"],
        },
        "busiest_month": busiest,
        "months": [{"month": m["month"],
                    "listening_seconds": secs(m["seconds"])}
                   for m in r["months"]],
        "top_tracks": [
            {"rank": i + 1, "uuid": row["id"],
             "title": TRACK_BY_UUID[row["id"]]["title"],
             "artist": TRACK_BY_UUID[row["id"]]["artistName"],
             "album": TRACK_BY_UUID[row["id"]]["albumName"],
             "listening_seconds": secs(row["seconds"]),
             "qualified_plays": row["qualifiedPlays"]}
            for i, row in enumerate(r["topTracks"])],
        "top_artists": [
            {"rank": i + 1, "id": row["id"], "name": ARTIST_NAME[row["id"]],
             "listening_seconds": secs(row["seconds"]),
             "qualified_plays": row["qualifiedPlays"]}
            for i, row in enumerate(r["topArtists"])],
        "top_albums": [
            {"rank": i + 1, "id": row["id"],
             "title": ALBUM_BY_ID[row["id"]]["name"],
             "artist": ARTIST_NAME[ALBUM_BY_ID[row["id"]]["artistId"]],
             "listening_seconds": secs(row["seconds"]),
             "qualified_plays": row["qualifiedPlays"]}
            for i, row in enumerate(r["topAlbums"])],
        "notes": NOTES + ([YEAR_SO_FAR_NOTE] if r["yearSoFar"] else []),
    }
    return json.dumps(out, indent=2, ensure_ascii=False) + "\n"


CASES = [
    {"name": "prior year 2025", "year": 2025, "golden": "recap_2025.json"},
    {"name": "current year 2026 (Year so far)", "year": 2026,
     "golden": "recap_2026.json"},
    {"name": "empty year 2023", "year": 2023, "golden": "recap_2023.json"},
]
for c in CASES:
    c["capturedNow"] = NOW
    c["capturedNowMs"] = ms(NOW)
    c["boundary"] = BOUNDARY
    c["expected"] = recap(c["year"], c["capturedNowMs"], BOUNDARY)
    with open(c["golden"], "w", encoding="utf-8") as f:
        f.write(export(c["expected"]))

# Years with a counted listen at NOW and BOUNDARY, newest first.
YEARS = sorted({datetime.fromtimestamp(e["atMs"] / 1000, UTC).year
                for e in E
                if e["kind"] == "play" and finite_pos(e["seconds"])
                and e["localId"] <= BOUNDARY and e["atMs"] < ms(NOW)},
               reverse=True)

out = {
    "about": __doc__.strip().splitlines()[0],
    "catalog": CATALOG,
    "events": E,
    "cases": CASES,
    "yearsWithListening": YEARS,
}
with open("recap_fixture.json", "w", encoding="utf-8") as f:
    json.dump(out, f, indent=1, ensure_ascii=False)
    f.write("\n")
print(f"{len(E)} events, {len(CASES)} cases, years {YEARS}")
