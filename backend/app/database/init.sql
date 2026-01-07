CREATE TABLE IF NOT EXISTS tracks (
    "id" INTEGER PRIMARY KEY,
    "uuid_id" TEXT UNIQUE NOT NULL,
    "file_path" TEXT NOT NULL,
    "file_hash" TEXT UNIQUE,
    "created_at" INTEGER NOT NULL DEFAULT (unixepoch()),
    "last_updated" INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS trackmetadata (
    "track_id" INTEGER UNIQUE NOT NULL,
    "uuid_id" TEXT UNIQUE NOT NULL,
    "title" TEXT,
    "artist" TEXT,
    "album" TEXT,
    "album_artist" TEXT,
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
    FOREIGN KEY ("track_id") REFERENCES tracks("id"),
    FOREIGN KEY ("uuid_id") REFERENCES tracks("uuid_id")
);

CREATE INDEX idx_title ON trackmetadata("title");
CREATE INDEX idx_artist ON trackmetadata("artist");
CREATE INDEX idx_album ON trackmetadata("album");
CREATE INDEX idx_album_artist ON trackmetadata("album_artist");
CREATE INDEX idx_year ON trackmetadata("year");
CREATE INDEX idx_date ON trackmetadata("date");
CREATE INDEX idx_genre ON trackmetadata("genre");
CREATE INDEX idx_track_number ON trackmetadata("track_number");
CREATE INDEX idx_disc_number ON trackmetadata("disc_number");
CREATE INDEX idx_codec ON trackmetadata("codec");
CREATE INDEX idx_duration ON trackmetadata("duration");
CREATE INDEX idx_bitrate_kbps ON trackmetadata("bitrate_kbps");
CREATE INDEX idx_sample_rate_hz ON trackmetadata("sample_rate_hz");
CREATE INDEX idx_channels ON trackmetadata("channels");
CREATE INDEX idx_has_album_art ON trackmetadata("has_album_art");