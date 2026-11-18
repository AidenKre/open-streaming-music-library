"""Portable on-disk names (spec phase-m §3 M-P1; SC-28 rule 5; review M-U01).

Every name the server creates under the music library must be legal on
Windows, macOS and Linux, so a library copied to exFAT/NTFS still works.
"""

import pytest

from app.services.path_sanitize import (
    UnsafePathComponent,
    sanitize_file_name,
    sanitize_path_component,
)


class TestWindowsReservedCharacters:
    @pytest.mark.parametrize("char", [":", "*", "?", '"', "<", ">", "|"])
    def test_each_reserved_character_becomes_underscore(self, char):
        assert sanitize_path_component(f"a{char}b") == "a_b"

    def test_re_colon_stacks(self):
        assert sanitize_path_component("Re: Stacks") == "Re_ Stacks"

    def test_all_reserved_characters_at_once(self):
        assert sanitize_path_component('w:x*y?"z<>|') == "w_x_y__z___"


_DEVICE_STEMS = (
    ["con", "prn", "aux", "nul"]
    + [f"com{i}" for i in range(1, 10)]
    + [f"lpt{i}" for i in range(1, 10)]
)


class TestWindowsDeviceNames:
    @pytest.mark.parametrize("stem", _DEVICE_STEMS)
    def test_device_name_gets_underscore_appended(self, stem):
        assert sanitize_path_component(stem) == f"{stem}_"

    @pytest.mark.parametrize("value", ["CON", "Con", "cOn", "AUX", "Lpt9", "COM1"])
    def test_any_case(self, value):
        assert sanitize_path_component(value) == f"{value}_"

    def test_trailing_dots_and_spaces_stripped_before_the_check(self):
        # Windows ignores trailing dots/spaces, so "CON. " is the device too.
        assert sanitize_path_component("CON. ") == "CON_"
        assert sanitize_path_component("nul...") == "nul_"

    def test_device_stem_with_extension_gets_underscore_on_the_stem(self):
        # Windows reserves "CON.anything", not just "CON".
        assert sanitize_path_component("aux.mp3") == "aux_.mp3"
        assert sanitize_path_component("con.tar.gz") == "con_.tar.gz"

    @pytest.mark.parametrize(
        "value", ["console", "com0", "com10", "lpt", "auxiliary", "xcon", "nul_", "my aux"]
    )
    def test_lookalikes_are_unchanged(self, value):
        assert sanitize_path_component(value) == value

    def test_device_rule_respects_the_length_cap(self):
        long_ext = "con." + "x" * 400
        result = sanitize_path_component(long_ext)
        assert result.startswith("con_.")
        assert len(result) <= 200


class TestExistingRulesStillHold:
    def test_separators_controls_and_specials(self):
        assert sanitize_path_component("../x") == ".._x"
        assert sanitize_path_component("/abs") == "_abs"
        assert sanitize_path_component("..\\x") == ".._x"
        assert sanitize_path_component("a\nb") == "a_b"
        for bad in (".", "..", "", "  "):
            with pytest.raises(UnsafePathComponent):
                sanitize_path_component(bad)

    def test_plain_names_unchanged(self):
        assert sanitize_path_component("OK Computer") == "OK Computer"


class TestSanitizeFileName:
    def test_device_stem_gets_underscore_and_keeps_extension(self):
        assert sanitize_file_name("AUX.mp3") == "AUX_.mp3"
        assert sanitize_file_name("aux.mp3") == "aux_.mp3"
        assert sanitize_file_name("lpt1.flac") == "lpt1_.flac"

    def test_plain_name_unchanged(self):
        assert sanitize_file_name("01 - Airbag.m4a") == "01 - Airbag.m4a"

    def test_reserved_characters_in_stem(self):
        assert sanitize_file_name("Re: Stacks?.mp3") == "Re_ Stacks_.mp3"

    def test_separators_and_controls_in_stem(self):
        assert sanitize_file_name("a/b\\c\x00d\ne.mp3") == "a_b_c_d_e.mp3"

    def test_long_stem_is_cut_but_extension_is_kept(self):
        result = sanitize_file_name("x" * 500 + ".flac")
        assert len(result) == 200
        assert result.endswith(".flac")
        assert result == "x" * 195 + ".flac"

    def test_cut_stem_does_not_end_in_dot_or_space(self):
        # The cap lands on a run of spaces/dots; they are stripped, the
        # extension stays.
        result = sanitize_file_name("a" * 190 + " ." * 20 + ".mp3")
        assert result == "a" * 190 + ".mp3"

    def test_name_without_extension(self):
        assert sanitize_file_name("CON") == "CON_"
        assert len(sanitize_file_name("y" * 300)) == 200

    def test_trailing_dots_and_spaces_on_the_whole_name_are_stripped(self):
        assert sanitize_file_name("song.mp3. ") == "song.mp3"

    @pytest.mark.parametrize("bad", ["", ".", "..", "...", "  "])
    def test_unusable_names_raise(self, bad):
        with pytest.raises(UnsafePathComponent):
            sanitize_file_name(bad)


class TestInternalDirNames:
    """7-fix-r0 F0-2: a component named exactly like an internal dir of the
    music library (``.uploads``, ``.staging``) gets a ``_`` appended, like a
    Windows device name, so no library path can name an internal dir."""

    @pytest.mark.parametrize("name", [".uploads", ".staging"])
    def test_an_internal_dir_name_gets_an_underscore(self, name):
        assert sanitize_path_component(name) == f"{name}_"

    @pytest.mark.parametrize("name", [".uploads", ".staging"])
    def test_a_trailing_dot_or_space_that_collapses_onto_it_too(self, name):
        assert sanitize_path_component(f"{name}. ") == f"{name}_"

    @pytest.mark.parametrize("name", [".uploads", ".staging"])
    def test_a_file_named_exactly_like_it_too(self, name):
        assert sanitize_file_name(name) == f"{name}_"

    @pytest.mark.parametrize(
        "value", [".Uploads", ".STAGING", ".uploads2", "uploads", "x.uploads", ".hidden", ".staging_"]
    )
    def test_every_other_name_is_unchanged(self, value):
        assert sanitize_path_component(value) == value


class TestInternalDirNamesOnlyWholeNames:
    """7-fix-r0 review R0-2: only a whole name equal to an internal dir name
    changes; a file whose stem happens to be one keeps its name."""

    @pytest.mark.parametrize("name", [".uploads.mp3", ".staging.flac", ".uploads.tar.gz"])
    def test_a_file_whose_stem_is_an_internal_name_is_unchanged(self, name):
        assert sanitize_file_name(name) == name


class TestTheCapCountsBytes:
    """Bug row U05-A-12: the 200 cap is a budget of UTF-8 bytes, not of
    characters (a filesystem name holds 255 bytes; 90 CJK characters are 270).
    A cut lands on a character boundary and a file name keeps its last
    extension."""

    @staticmethod
    def _bytes(name: str) -> int:
        return len(name.encode("utf-8", "surrogateescape"))

    def test_an_artist_of_90_cjk_characters_fits_200_bytes(self):
        artist = "音" * 90  # 270 bytes

        result = sanitize_path_component(artist)

        assert self._bytes(result) <= 200
        assert result == "音" * 66  # 198 bytes: the 67th would pass the budget

    def test_a_file_name_of_90_cjk_characters_keeps_its_extension_within_200_bytes(self):
        result = sanitize_file_name("曲" * 90 + ".flac")

        assert self._bytes(result) <= 200
        assert result == "曲" * 65 + ".flac"  # 195 + 5 bytes

    def test_a_four_byte_character_is_never_cut_in_half(self):
        result = sanitize_path_component("a" + "🎵" * 60)  # 1 + 240 bytes

        assert result == "a" + "🎵" * 49  # 197 bytes; a 50th would make 201
        assert result.encode("utf-8").decode("utf-8") == result

    def test_a_name_with_undecodable_bytes_is_counted_as_its_bytes(self):
        import os

        name = os.fsdecode(b"\xff" * 250 + b".mp3")

        result = sanitize_file_name(name)

        assert self._bytes(result) <= 200
        assert result.endswith(".mp3")

    def test_ascii_names_keep_todays_cut(self):
        assert sanitize_file_name("x" * 500 + ".flac") == "x" * 195 + ".flac"
        assert sanitize_path_component("y" * 300) == "y" * 200

    def test_the_destination_folders_of_a_cjk_artist_and_album_fit(self, tmp_path):
        from app.models import TrackMetaData
        from app.services.organizer import sanitized_destination_path

        meta = TrackMetaData(title="t", artist="歌" * 90, album="盤" * 90, duration=1.0)

        # The organizer passes the sanitized source name (sanitize_file_name).
        path = sanitized_destination_path(sanitize_file_name("曲" * 90 + ".flac"), meta, tmp_path)

        parts = path.relative_to(tmp_path).parts
        assert len(parts) == 3
        assert all(self._bytes(p) <= 200 for p in parts)

    def test_an_upload_final_name_fits_the_byte_cap(self):
        from app.services.upload_commit import _MAX_FILE_NAME, _final_stem

        track_uuid = "0" * 32
        stem = _final_stem("曲" * 90 + ".flac", track_uuid, ".flac")

        assert self._bytes(f"{stem}-{track_uuid}.flac") <= _MAX_FILE_NAME
        assert stem and set(stem) == {"曲"}
