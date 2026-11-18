"""Sign-off DEV-7-14 point 1: the one archive inspection, for the formats the
upload path never sees (tar, tar.gz, RAR). The ZIP rules themselves are tested
once, in ``test_upload_zip_inspect.py``; both callers use that inspection.
Here: the extension decides the reader (a file whose real format differs is
invalid), the shared per-member rules reach the tar/RAR lister, link and
device entries are refused, and the compression ratio is checked for the whole
archive (tar and RAR give no per-entry compressed size) at each header,
before that entry's data is read."""

import gzip
import io
import tarfile
import zipfile

import pytest

from app.services import import_archive
from app.services.upload_validation import ValidationFailed
from app.services.upload_zip import ArchivePlan
from tests.archive_builders import rar4, rar5, tar_info, write_rar, write_tar
from tests.upload_zip_fixtures import tiny_limits

AUDIO = b"A" * 300


def _fail(path, code, **limit_overrides):
    with pytest.raises(ValidationFailed) as ei:
        import_archive.inspect(path, tiny_limits(**limit_overrides))
    assert ei.value.error.code == code
    return ei.value.error


def _names(plan: ArchivePlan):
    return [m.name for m in plan.members]


# --- the plan --------------------------------------------------------------

@pytest.mark.parametrize("name,mode", [("a.tar", "w"), ("a.tar.gz", "w:gz")])
def test_a_tar_lists_its_audio_entries_and_counts_the_rest(tmp_path, name, mode):
    path = write_tar(tmp_path / name, [
        tar_info("Album", kind=tarfile.DIRTYPE),
        ("Album/a.flac", AUDIO),
        ("Album/cover.jpg", b"jpeg"),
        ("Album/b.mp3", b"B" * 200),
        ("__MACOSX/Album/x.flac", b"junk"),
    ], mode=mode)

    plan = import_archive.inspect(path, tiny_limits())

    assert _names(plan) == ["Album/a.flac", "Album/b.mp3"]
    assert [m.declared_bytes for m in plan.members] == [300, 200]
    assert plan.skipped == 2


@pytest.mark.parametrize("build", [rar5, rar4], ids=["rar5", "rar4"])
def test_a_rar_lists_its_audio_entries(tmp_path, build):
    path = write_rar(tmp_path / "a.rar", [("a.mp3", AUDIO), ("notes.txt", b"x"), ("b.flac", AUDIO)],
                     build=build)

    plan = import_archive.inspect(path, tiny_limits())

    assert _names(plan) == ["a.mp3", "b.flac"]
    assert plan.skipped == 1


def test_a_zip_goes_through_the_shared_zip_inspection(tmp_path, monkeypatch):
    calls = []
    sentinel = ArchivePlan((), 0)
    monkeypatch.setattr(import_archive, "inspect_archive",
                        lambda path, limits: calls.append((path, limits)) or sentinel)
    path = tmp_path / "a.zip"
    limits = tiny_limits()

    assert import_archive.inspect(path, limits) is sentinel
    assert calls == [(path, limits)]


# --- the extension decides the format ---------------------------------------

def _zip_bytes():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("a.mp3", AUDIO)
    return buf.getvalue()


def _tar_bytes(mode="w"):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode=mode) as t:
        info, data = tar_info("a.mp3", AUDIO)
        t.addfile(info, io.BytesIO(data))
    return buf.getvalue()


@pytest.mark.parametrize("name,content", [
    ("zip-in.tar", _zip_bytes),
    ("xz-in.tar", lambda: _tar_bytes("w:xz")),
    ("gz-in.tar", lambda: _tar_bytes("w:gz")),
    ("plain-in.tar.gz", lambda: _tar_bytes("w")),
    ("bz2-in.tar.gz", lambda: _tar_bytes("w:bz2")),
    ("zip-in.rar", _zip_bytes),
    ("tar-in.rar", lambda: _tar_bytes("w")),
    ("xz-in.zip", lambda: _tar_bytes("w:xz")),
    ("garbage.tar", lambda: b"not a tar at all" * 40),
    ("garbage.rar", lambda: b"not a rar at all" * 40),
])
def test_an_archive_whose_real_format_differs_from_its_extension_is_invalid(tmp_path, name, content):
    path = tmp_path / name.replace("-in", "")
    path.write_bytes(content())

    _fail(path, "upload_archive_invalid")


# --- the shared per-member rules reach the tar / RAR lister ------------------

@pytest.mark.parametrize("entries,code", [
    ([("../evil.flac", AUDIO)], "upload_archive_unsafe_path"),
    ([("/abs/evil.flac", AUDIO)], "upload_archive_unsafe_path"),
    ([("A.flac", AUDIO), ("a.FLAC", AUDIO)], "upload_archive_duplicate_names"),
    ([("a.flac", AUDIO), ("inner.zip", b"PK")], "upload_archive_nested"),
    ([("a.flac", b"A" * 1001)], "upload_archive_member_too_large"),
    ([(f"{i}.flac", AUDIO) for i in range(5)], "upload_archive_too_many_audio"),
    ([(f"{i}.txt", b"x") for i in range(9)], "upload_archive_too_many_members"),
])
def test_the_shared_member_rules_apply_to_a_tar(tmp_path, entries, code):
    _fail(write_tar(tmp_path / "a.tar", entries), code)


def test_the_expanded_total_counts_audio_entries(tmp_path):
    path = write_tar(tmp_path / "a.tar", [("a.flac", b"A" * 800), ("b.flac", b"B" * 800)])

    _fail(path, "upload_archive_expanded_too_large", max_expanded_bytes_per_batch=1599)
    assert len(import_archive.inspect(path, tiny_limits(max_expanded_bytes_per_batch=1600)).members) == 2


@pytest.mark.parametrize("build", [rar5, rar4], ids=["rar5", "rar4"])
def test_the_shared_member_rules_apply_to_a_rar(tmp_path, build):
    _fail(write_rar(tmp_path / "a.rar", [("../evil.mp3", AUDIO)], build=build),
          "upload_archive_unsafe_path")


@pytest.mark.parametrize("entry", [
    tar_info("link.flac", kind=tarfile.SYMTYPE, linkname="/etc/passwd"),
    tar_info("hard.flac", kind=tarfile.LNKTYPE, linkname="a.flac"),
    tar_info("fifo", kind=tarfile.FIFOTYPE),
    tar_info("dev", kind=tarfile.CHRTYPE),
])
def test_link_and_device_entries_are_refused(tmp_path, entry):
    path = write_tar(tmp_path / "a.tar", [("a.flac", AUDIO), entry])

    _fail(path, "upload_archive_unsafe_member")


# --- the archive-wide compression ratio ------------------------------------

def test_a_tar_gz_expanding_beyond_the_ratio_is_refused(tmp_path):
    # Every entry counts (the lister has to decompress non-audio data too).
    path = write_tar(tmp_path / "a.tar.gz", [("a.flac", AUDIO), ("zeros.txt", bytes(100_000))],
                     mode="w:gz")
    assert 300 + 100_000 > 10 * path.stat().st_size

    _fail(path, "upload_archive_ratio_exceeded")


def test_the_ratio_boundary(tmp_path):
    path = write_tar(tmp_path / "a.tar.gz", [("a.flac", AUDIO), ("b.txt", bytes(20_000))], mode="w:gz")
    declared, size = 300 + 20_000, path.stat().st_size
    at = -(-declared // size)  # the smallest ratio that admits it
    assert at > 1

    assert _names(import_archive.inspect(path, tiny_limits(max_compression_ratio=at))) == ["a.flac"]
    _fail(path, "upload_archive_ratio_exceeded", max_compression_ratio=at - 1)


def test_a_plain_tar_passes_a_ratio_of_one(tmp_path):
    path = write_tar(tmp_path / "a.tar", [("a.flac", AUDIO), ("b.txt", b"x" * 700)])

    assert _names(import_archive.inspect(path, tiny_limits(max_compression_ratio=1))) == ["a.flac"]


def test_the_ratio_is_checked_at_the_header_before_the_data_is_read(tmp_path):
    """A header claiming 1 TB with no data behind it: refused for its ratio
    at the header, never decompressed or read as a truncated archive."""
    info, _ = tar_info("bomb.txt")
    info.size = 10**12
    header = info.tobuf(format=tarfile.PAX_FORMAT)
    path = tmp_path / "bomb.tar.gz"
    path.write_bytes(gzip.compress(header + bytes(1024)))

    _fail(path, "upload_archive_ratio_exceeded")


def test_an_empty_tar_has_no_members(tmp_path):
    path = write_tar(tmp_path / "a.tar", [])

    plan = import_archive.inspect(path, tiny_limits())

    assert plan.members == () and plan.skipped == 0


# --- review r1 (s7-import-archives-review.md) -------------------------------------

def _no_libarchive(monkeypatch):
    """libarchive must not even open the file: the Python pre-checks refuse it."""
    def refuse(*args, **kwargs):
        raise AssertionError("libarchive opened an archive the pre-check should refuse")

    monkeypatch.setattr(import_archive.libarchive, "file_reader", refuse)
    monkeypatch.setattr(import_archive.libarchive, "fd_reader", refuse)


@pytest.mark.parametrize("fmt", [tarfile.GNU_FORMAT, tarfile.PAX_FORMAT], ids=["gnu-longname", "pax"])
@pytest.mark.parametrize("name,mode", [("a.tar", "w"), ("a.tar.gz", "w:gz")])
def test_r1_1_an_oversized_special_header_is_refused_before_libarchive_reads_it(
        tmp_path, monkeypatch, fmt, name, mode):
    """libarchive reads a long-name header's body into memory (1000 MiB from a
    1 MB tar.gz in the review); a special header over 64 KiB is refused first."""
    path = tmp_path / name
    with tarfile.open(path, mode, format=fmt) as t:
        info, data = tar_info("d/" + "n" * 70_000 + ".mp3", AUDIO)
        t.addfile(info, io.BytesIO(data))
    _no_libarchive(monkeypatch)

    _fail(path, "upload_archive_invalid", max_compression_ratio=10**6)


@pytest.mark.parametrize("fmt", [tarfile.GNU_FORMAT, tarfile.PAX_FORMAT], ids=["gnu-longname", "pax"])
def test_r1_1_a_long_name_under_the_cap_is_listed(tmp_path, fmt):
    path = tmp_path / "a.tar"
    with tarfile.open(path, "w", format=fmt) as t:
        info, data = tar_info("d/" + "n" * 1000 + ".mp3", AUDIO)
        t.addfile(info, io.BytesIO(data))

    assert _names(import_archive.inspect(path, tiny_limits())) == ["d/" + "n" * 1000 + ".mp3"]


def _tar_raw(entries):
    """Raw tar bytes from (TarInfo, data) pairs, data padded to 512, no end marker."""
    out = b""
    for info, data in entries:
        out += info.tobuf(format=tarfile.USTAR_FORMAT) + data + bytes(-len(data) % 512)
    return out


def test_r1_6_a_directory_entry_with_data_is_refused(tmp_path, monkeypatch):
    """libarchive and a header walker disagree on where the next header is:
    the hidden entry would be missing from the plan, and a full import would
    delete the archive with it."""
    hidden = _tar_raw([tar_info("hidden.mp3", AUDIO)])
    folder, _ = tar_info("dir", kind=tarfile.DIRTYPE)
    folder.size = len(hidden)
    raw = folder.tobuf(format=tarfile.USTAR_FORMAT) + hidden + _tar_raw([tar_info("a.mp3", AUDIO)]) + bytes(1024)
    path = tmp_path / "a.tar"
    path.write_bytes(raw)

    _fail(path, "upload_archive_invalid")


@pytest.mark.parametrize("gz", ["none", "one-stream", "two-members"])
def test_r1_6_data_after_the_end_of_archive_marker_is_refused(tmp_path, gz):
    """Concatenated tars: libarchive stops at the first end marker, so the
    second part's tracks would never be planned."""
    first = _tar_bytes("w")
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        info, data = tar_info("disc2/b.mp3", AUDIO)
        t.addfile(info, io.BytesIO(data))
    second = buf.getvalue()
    if gz == "none":
        path, raw = tmp_path / "a.tar", first + second
    elif gz == "one-stream":
        path, raw = tmp_path / "a.tar.gz", gzip.compress(first + second)
    else:
        path, raw = tmp_path / "a.tar.gz", gzip.compress(first) + gzip.compress(second)
    path.write_bytes(raw)

    _fail(path, "upload_archive_invalid", max_compression_ratio=10**6)


def test_r1_6_zero_padding_after_the_end_marker_is_fine(tmp_path):
    raw = _tar_raw([tar_info("a.mp3", AUDIO)]) + bytes(1024) + bytes(20 * 512)
    path = tmp_path / "a.tar"
    path.write_bytes(raw)

    assert _names(import_archive.inspect(path, tiny_limits())) == ["a.mp3"]


@pytest.mark.parametrize("content", [_zip_bytes, lambda: b"7z\xbc\xaf\x27\x1c" + bytes(200)],
                         ids=["zip", "7z"])
def test_r1_4_a_rar_without_a_rar_signature_is_refused_before_libarchive(tmp_path, monkeypatch, content):
    path = tmp_path / "a.rar"
    path.write_bytes(content())
    _no_libarchive(monkeypatch)

    _fail(path, "upload_archive_invalid")


# --- review re-check r1 ----------------------------------------------------------------

@pytest.mark.parametrize("build,fmt", [(rar5, "rar5"), (rar4, "rar")], ids=["rar5", "rar4"])
def test_r2_1_a_rar_is_read_with_the_rar_reader_its_signature_names(tmp_path, monkeypatch, build, fmt):
    """With every format enabled, a file starting with a RAR signature and
    ending with a huge ZIP was parsed by the ZIP reader (it outbids RAR)."""
    path = write_rar(tmp_path / "a.rar", [("a.mp3", AUDIO)], build=build)
    seen = []
    real = import_archive.libarchive.fd_reader

    def spy(fd, *args, **kwargs):
        seen.append(kwargs.get("format_name"))
        return real(fd, *args, **kwargs)

    monkeypatch.setattr(import_archive.libarchive, "fd_reader", spy)

    assert _names(import_archive.inspect(path, tiny_limits())) == ["a.mp3"]
    assert seen and set(seen) == {fmt}


def test_r2_1_a_rar_signature_in_front_of_a_zip_is_invalid(tmp_path):
    path = tmp_path / "a.rar"
    path.write_bytes(b"Rar!\x1a\x07\x01\x00" + _zip_bytes())

    _fail(path, "upload_archive_invalid")


def _empty_headers(count):
    return _tar_raw([tar_info(f"{i}.txt") for i in range(count)])


@pytest.mark.parametrize("gz", [False, True])
def test_r2_2_the_header_walk_caps_the_number_of_headers(tmp_path, monkeypatch, gz):
    """2M empty headers in a 4.5 MB tar.gz took 18 s to walk; the walk stops
    at four times the member cap (tiny limits: 8 members, so 32 headers)."""
    raw = _empty_headers(33) + bytes(1024)
    path = tmp_path / ("a.tar.gz" if gz else "a.tar")
    path.write_bytes(gzip.compress(raw) if gz else raw)
    _no_libarchive(monkeypatch)

    _fail(path, "upload_archive_too_many_members", max_compression_ratio=10**6)


def test_r2_2_header_bytes_count_toward_the_ratio(tmp_path, monkeypatch):
    path = tmp_path / "a.tar.gz"
    path.write_bytes(gzip.compress(_empty_headers(30) + bytes(1024)))
    _no_libarchive(monkeypatch)
    assert 30 * 512 > 2 * path.stat().st_size

    _fail(path, "upload_archive_ratio_exceeded", max_compression_ratio=2, max_archive_members=100)


def test_r2_2_the_header_walk_stops_when_the_server_stops(tmp_path, monkeypatch):
    from app.services.import_archive import ArchiveStopped

    path = write_tar(tmp_path / "a.tar", [("a.mp3", AUDIO)])
    _no_libarchive(monkeypatch)

    with pytest.raises(ArchiveStopped):
        import_archive.inspect(path, tiny_limits(), should_stop=lambda: True)


def test_r2_nit_more_audio_formats_count_as_audio_the_server_cannot_import():
    from app.services.upload_zip import is_other_audio

    for name in ("02.mp4", "r.m4r", "w.webm", "a.ac3", "d.dts", "s.spx", "m.mid", "m.midi", "s.shn",
                 "b.aax", "t.mod", "t.xm", "t.it", "t.s3m"):
        assert is_other_audio(name), name
    assert not is_other_audio("cover.jpg") and not is_other_audio("._x.mp4")
