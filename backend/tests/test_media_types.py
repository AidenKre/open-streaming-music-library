from __future__ import annotations

import pytest

from app.core.media_types import (
    CODEC_MIME,
    CODEC_TO_EXT,
    LOSSLESS_CODECS,
    LOSSY_CODECS,
    MIME_EXTENSION,
    is_lossless,
    is_lossy,
)

# Every codec transcode()'s _CODEC_FLAGS supports as a conversion target.
CONVERTIBLE_TARGET_CODECS = ("aac", "alac", "flac", "mp3")


class TestLosslessLossyPredicates:
    @pytest.mark.parametrize("codec", sorted(LOSSLESS_CODECS))
    def test_is_lossless__lossless_codec__returns_true(self, codec):
        assert is_lossless(codec) is True

    @pytest.mark.parametrize("codec", sorted(LOSSY_CODECS))
    def test_is_lossless__lossy_codec__returns_false(self, codec):
        assert is_lossless(codec) is False

    @pytest.mark.parametrize("codec", sorted(LOSSY_CODECS))
    def test_is_lossy__lossy_codec__returns_true(self, codec):
        assert is_lossy(codec) is True

    @pytest.mark.parametrize("codec", sorted(LOSSLESS_CODECS))
    def test_is_lossy__lossless_codec__returns_false(self, codec):
        assert is_lossy(codec) is False

    def test_is_lossless__unknown_codec__returns_false(self):
        assert is_lossless("opus") is False

    def test_is_lossy__unknown_codec__returns_false(self):
        assert is_lossy("opus") is False

    def test_lossless_and_lossy_codecs__are_disjoint(self):
        assert LOSSLESS_CODECS.isdisjoint(LOSSY_CODECS)


class TestCodecToExt:
    @pytest.mark.parametrize("codec", CONVERTIBLE_TARGET_CODECS)
    def test_codec_to_ext__every_convertible_target__has_entry(self, codec):
        assert codec in CODEC_TO_EXT

    def test_codec_to_ext__aac_and_alac__both_map_to_m4a(self):
        assert CODEC_TO_EXT["aac"] == "m4a"
        assert CODEC_TO_EXT["alac"] == "m4a"

    def test_codec_to_ext__flac_and_mp3__map_to_own_extension(self):
        assert CODEC_TO_EXT["flac"] == "flac"
        assert CODEC_TO_EXT["mp3"] == "mp3"


class TestCodecMime:
    @pytest.mark.parametrize("codec", CONVERTIBLE_TARGET_CODECS)
    def test_codec_mime__every_convertible_target__has_entry(self, codec):
        assert codec in CODEC_MIME

    def test_codec_mime__every_value__resolves_via_mime_extension(self):
        # Every mime CODEC_MIME can produce should be resolvable back to an
        # extension via MIME_EXTENSION, or stream_track's X-Audio-Extension
        # header silently falls back to the source suffix.
        for codec, mime in CODEC_MIME.items():
            assert mime in MIME_EXTENSION, f"{codec} -> {mime} has no MIME_EXTENSION entry"
