"""``audio_end_candidates`` on small byte files, without ffmpeg.

The strict-decode retry tries each candidate end in turn. Without a trailer
there is nothing to retry. After a trailer it starts at the end without the
trailers; when the last stripped trailer was a run of zeros, it also tries one
and two bytes further (a last frame can end in a 0x00 CRC byte), never more
than the zeros stripped. A file that cannot be read gives no candidates.
"""

from app.services.audio_identity import audio_end_candidates

# Stands in for the audio: ends in a non-zero byte, has no "TAG" 128 bytes
# from its end and no APEv2 footer.
AUDIO = b"fLaC" + bytes(range(1, 200))
END = len(AUDIO)


def _id3v1() -> bytes:
    """128 bytes starting ``TAG``; the last byte is a genre (17), not zero."""
    tag = b"TAG" + b"Title".ljust(30, b"\0") + b"Artist".ljust(30, b"\0")
    return tag.ljust(127, b"\0") + bytes([17])


def _file(tmp_path, data: bytes):
    path = tmp_path / "track.flac"
    path.write_bytes(data)
    return path


def test_a_file_without_a_trailer_gives_no_candidates(tmp_path):
    assert audio_end_candidates(_file(tmp_path, AUDIO)) == ()


def test_an_id3v1_tag_gives_only_the_end_before_it(tmp_path):
    assert audio_end_candidates(_file(tmp_path, AUDIO + _id3v1())) == (END,)


def test_one_zero_byte_gives_the_end_and_one_byte_further(tmp_path):
    assert audio_end_candidates(_file(tmp_path, AUDIO + b"\0")) == (END, END + 1)


def test_five_zero_bytes_give_at_most_two_bytes_further(tmp_path):
    assert audio_end_candidates(_file(tmp_path, AUDIO + b"\0" * 5)) == (END, END + 1, END + 2)


def test_zeros_stripped_last_count_though_a_tag_came_after_them(tmp_path):
    # Stripped from the end: the tag first, then the zeros before it.
    data = AUDIO + b"\0" * 3 + _id3v1()
    assert audio_end_candidates(_file(tmp_path, data)) == (END, END + 1, END + 2)


def test_a_tag_stripped_last_gives_only_its_start_though_zeros_followed_it(tmp_path):
    # Stripped from the end: the zeros first, then the tag before them.
    data = AUDIO + _id3v1() + b"\0" * 4
    assert audio_end_candidates(_file(tmp_path, data)) == (END,)


def test_a_file_of_only_zeros_gives_no_candidates(tmp_path):
    assert audio_end_candidates(_file(tmp_path, b"\0" * 64)) == ()


def test_a_missing_file_gives_no_candidates(tmp_path):
    assert audio_end_candidates(tmp_path / "absent.flac") == ()
