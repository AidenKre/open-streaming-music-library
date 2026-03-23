CREATE TABLE IF NOT EXISTS artists (
    "id" INTEGER PRIMARY KEY,
    "name" TEXT NOT NULL,
    "name_lower" TEXT NOT NULL GENERATED ALWAYS AS (LOWER("name")) STORED UNIQUE
);

CREATE INDEX IF NOT EXISTS idx_artists_name_lower ON artists("name_lower");

CREATE TABLE IF NOT EXISTS albums (
    "id" INTEGER PRIMARY KEY,
    "name" TEXT,
    "name_lower" TEXT GENERATED ALWAYS AS (LOWER("name")) STORED,
    "artist_id" INTEGER NOT NULL,
    "year" INTEGER,
    "is_single_grouping" INTEGER NOT NULL DEFAULT 0 CHECK ("is_single_grouping" IN (0,1)),
    FOREIGN KEY ("artist_id") REFERENCES artists("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_albums_regular
    ON albums("name_lower", "artist_id") WHERE "is_single_grouping" = 0;

CREATE UNIQUE INDEX IF NOT EXISTS idx_albums_singles
    ON albums("artist_id", COALESCE("year", -1)) WHERE "is_single_grouping" = 1;

CREATE INDEX IF NOT EXISTS idx_albums_name_lower ON albums("name_lower");
CREATE INDEX IF NOT EXISTS idx_albums_artist_id ON albums("artist_id");

CREATE TABLE IF NOT EXISTS tracks (
    "id" INTEGER PRIMARY KEY,
    "uuid_id" TEXT UNIQUE NOT NULL,
    "file_path" TEXT NOT NULL,
    "file_hash" TEXT UNIQUE,
    "created_at" INTEGER NOT NULL DEFAULT (unixepoch()),
    "last_updated" INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS cover_arts (
    "id" INTEGER PRIMARY KEY,
    "sha256" TEXT UNIQUE NOT NULL,
    "phash" TEXT NOT NULL,
    "phash_prefix" TEXT NOT NULL,
    "file_path" TEXT UNIQUE NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_cover_arts_phash_prefix ON cover_arts("phash_prefix");

CREATE TABLE IF NOT EXISTS trackmetadata (
    "track_id" INTEGER UNIQUE NOT NULL,
    "uuid_id" TEXT UNIQUE NOT NULL,
    "title" TEXT,
    "artist" TEXT,
    "album" TEXT,
    "album_artist" TEXT,
    "artist_id" INTEGER,
    "album_id" INTEGER,
    "year" INTEGER,
    "date" TEXT,
    "genre" TEXT,
    "track_number" INTEGER,
    "disc_number" INTEGER,
    "codec" TEXT,
    "duration" FLOAT,
    "bitrate_kbps" FLOAT,
    "sample_rate_hz" INTEGER,
    "channels" INTEGER,
    "has_album_art" INTEGER NOT NULL CHECK ("has_album_art" IN (0,1)),
    "cover_art_id" INTEGER,
    FOREIGN KEY ("track_id") REFERENCES tracks("id"),
    FOREIGN KEY ("uuid_id") REFERENCES tracks("uuid_id"),
    FOREIGN KEY ("artist_id") REFERENCES artists("id"),
    FOREIGN KEY ("album_id") REFERENCES albums("id"),
    FOREIGN KEY ("cover_art_id") REFERENCES cover_arts("id") ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_title ON trackmetadata("title");
CREATE INDEX IF NOT EXISTS idx_artist ON trackmetadata("artist");
CREATE INDEX IF NOT EXISTS idx_album ON trackmetadata("album");
CREATE INDEX IF NOT EXISTS idx_album_artist ON trackmetadata("album_artist");
CREATE INDEX IF NOT EXISTS idx_tm_artist_id ON trackmetadata("artist_id");
CREATE INDEX IF NOT EXISTS idx_tm_album_id ON trackmetadata("album_id");
CREATE INDEX IF NOT EXISTS idx_year ON trackmetadata("year");
CREATE INDEX IF NOT EXISTS idx_date ON trackmetadata("date");
CREATE INDEX IF NOT EXISTS idx_genre ON trackmetadata("genre");
CREATE INDEX IF NOT EXISTS idx_track_number ON trackmetadata("track_number");
CREATE INDEX IF NOT EXISTS idx_disc_number ON trackmetadata("disc_number");
CREATE INDEX IF NOT EXISTS idx_codec ON trackmetadata("codec");
CREATE INDEX IF NOT EXISTS idx_duration ON trackmetadata("duration");
CREATE INDEX IF NOT EXISTS idx_bitrate_kbps ON trackmetadata("bitrate_kbps");
CREATE INDEX IF NOT EXISTS idx_sample_rate_hz ON trackmetadata("sample_rate_hz");
CREATE INDEX IF NOT EXISTS idx_channels ON trackmetadata("channels");
CREATE INDEX IF NOT EXISTS idx_has_album_art ON trackmetadata("has_album_art");

CREATE VIRTUAL TABLE IF NOT EXISTS fts_tracks USING fts5(
    title, artist_name, album_name,
    content='', content_rowid='id', tokenize='unicode61'
);

CREATE VIRTUAL TABLE IF NOT EXISTS fts_artists USING fts5(
    name,
    content='', content_rowid='id', tokenize='unicode61'
);

CREATE VIRTUAL TABLE IF NOT EXISTS fts_albums USING fts5(
    name, artist_name,
    content='', content_rowid='id', tokenize='unicode61'
);
