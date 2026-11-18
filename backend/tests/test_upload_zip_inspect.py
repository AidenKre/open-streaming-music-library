"""7A.2d S1 (spec §5 "ZIP"): "Inspect members before extraction: reject
absolute paths, drive paths, `..`, symlinks/special files, encrypted entries,
unsupported compression, duplicate normalized names and oversized
counts/declared sizes. Ignore non-audio regular files with a visible skipped
count; reject nested archives explicitly." Defaults: archive member limit 2000
including ignored entries, audio-child limit 1000 per batch, 250 MiB per
member, 2 GiB per batch, ratio 100:1. Adversarial archives are tiny and
scratch-owned; lowered quotas test the boundaries."""

import errno
import os
import stat
import struct
import unicodedata
import zipfile

import pytest

from app.services.upload_validation import ValidationFailed
from app.services.upload_zip import ArchivePlan, Member, inspect_archive
from tests.upload_zip_fixtures import Entry, build_zip, patch_eocd_count, tiny_limits

AUDIO = b"A" * 50


def _fail(path, code, tmp_path, *names, **kw):
    limits = kw.pop("limits", None) or tiny_limits()
    with pytest.raises(ValidationFailed) as ei:
        inspect_archive(path, limits, **kw)
    err = ei.value.error
    assert err.code == code
    assert err.retryable is False
    assert "/" not in err.message and "\\" not in err.message
    assert str(tmp_path) not in err.message
    for n in names:
        assert n not in err.message
    return err


def _zip(tmp_path, entries):
    return build_zip(tmp_path / "a.zip", entries)


# --- 1. invalid archives -------------------------------------------------

@pytest.mark.parametrize("data", [b"", b"not a zip at all", b"PK\x03\x04" + b"\x00" * 10])
def test_garbage_is_invalid(tmp_path, data):
    p = tmp_path / "g.zip"
    p.write_bytes(data)
    _fail(p, "upload_archive_invalid", tmp_path, "g.zip")


def test_truncated_is_invalid(tmp_path):
    p = _zip(tmp_path, [Entry("a.flac", AUDIO), Entry("b.flac", AUDIO)])
    p.write_bytes(p.read_bytes()[:-30])
    _fail(p, "upload_archive_invalid", tmp_path)


# --- 2. member counts ----------------------------------------------------

def test_real_member_count_over_cap(tmp_path):
    p = _zip(tmp_path, [Entry(f"n{i}.txt", b"x") for i in range(3)])
    _fail(p, "upload_archive_too_many_members", tmp_path, limits=tiny_limits(max_archive_members=2))


def test_eocd_declared_count_over_cap(tmp_path):
    p = _zip(tmp_path, [Entry("a.flac", AUDIO)])
    patch_eocd_count(p, 5000)
    assert len(zipfile.ZipFile(p).infolist()) == 1
    _fail(p, "upload_archive_too_many_members", tmp_path)


def test_exactly_cap_members_passes(tmp_path):
    entries = [Entry("d", is_dir=True)]
    entries += [Entry(f"s{i}.flac", AUDIO) for i in range(2)]
    entries += [Entry(f"n{i}.txt", b"x") for i in range(5)]
    assert len(entries) == 8
    plan = inspect_archive(_zip(tmp_path, entries), tiny_limits())
    assert len(plan.members) == 2 and plan.skipped == 5


def test_central_directory_size_over_cap(tmp_path):
    p = _zip(tmp_path, [Entry("a" * 5000 + ".txt", b"x"), Entry("b" * 5000 + ".txt", b"x")])
    _fail(p, "upload_archive_too_many_members", tmp_path, limits=tiny_limits(max_archive_members=2))


# --- 3. unsafe paths -----------------------------------------------------

@pytest.mark.parametrize("name", [
    "/etc/x.flac", "\\evil.flac", "C:/x.flac", "c:x.flac", "C:\\x.flac",
    "../x.flac", "a/../../x.flac", "a\\..\\x.flac", "a/..",
])
def test_unsafe_paths(tmp_path, name):
    _fail(_zip(tmp_path, [Entry(name, AUDIO)]), "upload_archive_unsafe_path", tmp_path, "x.flac", "evil")


def test_unsafe_path_on_non_audio_member(tmp_path):
    _fail(_zip(tmp_path, [Entry("../notes.txt", b"x")]), "upload_archive_unsafe_path", tmp_path, "notes")


# --- 4. normalization and duplicates -------------------------------------

def test_normalization_drops_empty_and_dot_and_nfc(tmp_path):
    nfd = unicodedata.normalize("NFD", "é.flac")
    p = _zip(tmp_path, [Entry("./a//b.flac", AUDIO), Entry(nfd, AUDIO)])
    plan = inspect_archive(p, tiny_limits())
    assert [m.name for m in plan.members] == ["a/b.flac", unicodedata.normalize("NFC", "é.flac")]


@pytest.mark.parametrize("entries", [
    [Entry("a.flac", AUDIO), Entry("a.flac", AUDIO)],
    [Entry("A.flac", AUDIO), Entry("a.flac", AUDIO)],
    [Entry("a/./b.flac", AUDIO), Entry("a/b.flac", AUDIO)],
    [Entry(unicodedata.normalize("NFD", "é.flac"), AUDIO), Entry(unicodedata.normalize("NFC", "é.flac"), AUDIO)],
    [Entry("x", b"data"), Entry("x", is_dir=True)],
], ids=["exact", "case", "dot", "nfd-nfc", "file-vs-dir"])
def test_duplicates(tmp_path, entries):
    _fail(_zip(tmp_path, entries), "upload_archive_duplicate_names", tmp_path, "flac")


# --- 5. unix modes -------------------------------------------------------

@pytest.mark.parametrize("mode", [
    stat.S_IFLNK | 0o777, stat.S_IFIFO | 0o644, stat.S_IFCHR | 0o644,
    stat.S_IFBLK | 0o644, stat.S_IFSOCK | 0o644,
])
def test_special_modes_rejected(tmp_path, mode):
    p = _zip(tmp_path, [Entry("link.flac", b"target", external_attr=mode << 16)])
    assert zipfile.ZipFile(p).infolist()[0].external_attr >> 16 == mode
    _fail(p, "upload_archive_unsafe_member", tmp_path, "link")


def test_regular_and_directory_modes_pass(tmp_path):
    p = _zip(tmp_path, [
        Entry("d", is_dir=True, external_attr=(stat.S_IFDIR | 0o755) << 16),
        Entry("d/a.flac", AUDIO, external_attr=(stat.S_IFREG | 0o644) << 16),
    ])
    assert len(inspect_archive(p, tiny_limits()).members) == 1


# --- 6/7. encryption and compression -------------------------------------

def test_encrypted_rejected(tmp_path):
    p = _zip(tmp_path, [Entry("s.flac", AUDIO, flag_bits=0x1)])
    assert zipfile.ZipFile(p).infolist()[0].flag_bits & 0x1
    _fail(p, "upload_archive_encrypted", tmp_path, "s.flac")


@pytest.mark.parametrize("ctype", [zipfile.ZIP_BZIP2, zipfile.ZIP_LZMA])
def test_unsupported_compression(tmp_path, ctype):
    p = _zip(tmp_path, [Entry("s.flac", AUDIO, compress_type=ctype)])
    assert zipfile.ZipFile(p).infolist()[0].compress_type == ctype
    _fail(p, "upload_archive_unsupported_compression", tmp_path, "s.flac")


@pytest.mark.parametrize("ctype", [zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED])
def test_supported_compression_passes(tmp_path, ctype):
    p = _zip(tmp_path, [Entry("s.flac", bytes(range(50)), compress_type=ctype)])
    assert len(inspect_archive(p, tiny_limits(max_compression_ratio=100)).members) == 1


# --- 8. nested archives --------------------------------------------------

@pytest.mark.parametrize("name", ["in.zip", "in.rar", "in.tar", "in.tar.gz", "dir/IN.ZIP"])
def test_nested_archives(tmp_path, name):
    _fail(_zip(tmp_path, [Entry(name, b"x")]), "upload_archive_nested", tmp_path, "in.")


# --- 9. classification ---------------------------------------------------

def test_classification_and_plan(tmp_path):
    p = _zip(tmp_path, [
        Entry("zeta/02.flac", b"B" * 30),
        Entry("dir", is_dir=True),
        Entry("cover.jpg", b"j"),
        Entry("__MACOSX/zeta/02.flac", b"m"),
        Entry("zeta/._song.flac", b"m"),
        Entry("alpha/SONG.FLAC", b"C" * 40),
        Entry("notes.txt", b"n"),
        Entry("song.ogg", b"o"),
        Entry("a.mp3", b"1" * 5),
        Entry("b.wav", b"2" * 6),
        Entry("c.m4a", b"3" * 7),
    ])
    infos = zipfile.ZipFile(p).infolist()
    idx = {i.filename: n for n, i in enumerate(infos)}
    plan = inspect_archive(p, tiny_limits(max_audio_items_per_batch=10, max_archive_members=20))
    assert isinstance(plan, ArchivePlan)
    assert plan.skipped == 5
    assert plan.members == (
        Member(idx["zeta/02.flac"], "zeta/02.flac", 30, 30),
        Member(idx["alpha/SONG.FLAC"], "alpha/SONG.FLAC", 40, 40),
        Member(idx["a.mp3"], "a.mp3", 5, 5),
        Member(idx["b.wav"], "b.wav", 6, 6),
        Member(idx["c.m4a"], "c.m4a", 7, 7),
    )


def test_normalized_name_in_plan(tmp_path):
    p = _zip(tmp_path, [Entry("./d//x.flac", AUDIO)])
    (m,) = inspect_archive(p, tiny_limits()).members
    assert m.name == "d/x.flac" and m.index == 0


def test_compressed_size_recorded(tmp_path):
    p = _zip(tmp_path, [Entry("z.flac", b"\0" * 200, compress_type=zipfile.ZIP_DEFLATED)])
    comp = zipfile.ZipFile(p).infolist()[0].compress_size
    assert 0 < comp < 200
    (m,) = inspect_archive(p, tiny_limits(max_compression_ratio=1000)).members
    assert (m.declared_bytes, m.compressed_bytes) == (200, comp)


def test_empty_archive(tmp_path):
    plan = inspect_archive(_zip(tmp_path, []), tiny_limits())
    assert plan.members == () and plan.skipped == 0


# --- 10. declared limits -------------------------------------------------

def test_member_size_boundary(tmp_path):
    assert inspect_archive(_zip(tmp_path, [Entry("a.flac", b"x" * 1000)]), tiny_limits()).members
    p = _zip(tmp_path, [Entry("a.flac", b"x" * 1001)])
    _fail(p, "upload_archive_member_too_large", tmp_path, "a.flac")


def test_ratio_exceeded(tmp_path):
    p = _zip(tmp_path, [Entry("z.flac", b"\0" * 900, compress_type=zipfile.ZIP_DEFLATED)])
    info = zipfile.ZipFile(p).infolist()[0]
    assert info.file_size > 10 * max(info.compress_size, 1)
    _fail(p, "upload_archive_ratio_exceeded", tmp_path, "z.flac")


def test_ratio_boundary_stored_passes(tmp_path):
    p = _zip(tmp_path, [Entry("a.flac", b"x" * 100)])
    assert inspect_archive(p, tiny_limits(max_compression_ratio=1)).members


def test_too_many_audio_boundary(tmp_path):
    four = [Entry(f"{i}.flac", AUDIO) for i in range(4)]
    assert len(inspect_archive(_zip(tmp_path, four), tiny_limits()).members) == 4
    p = build_zip(tmp_path / "b.zip", four + [Entry("4.flac", AUDIO)])
    _fail(p, "upload_archive_too_many_audio", tmp_path)


def test_too_many_audio_with_audio_used(tmp_path):
    p = _zip(tmp_path, [Entry(f"{i}.flac", AUDIO) for i in range(3)])
    assert inspect_archive(p, tiny_limits(), audio_used=1).members
    _fail(p, "upload_archive_too_many_audio", tmp_path, audio_used=2)


def test_expanded_total_boundary(tmp_path):
    limits = tiny_limits(max_expanded_bytes_per_batch=2000)
    two = [Entry("a.flac", b"x" * 1000), Entry("b.flac", b"y" * 1000)]
    assert len(inspect_archive(_zip(tmp_path, two), limits).members) == 2
    p = build_zip(tmp_path / "b.zip", two + [Entry("c.flac", b"z")])
    _fail(p, "upload_archive_expanded_too_large", tmp_path, limits=limits)


def test_expanded_used(tmp_path):
    limits = tiny_limits(max_expanded_bytes_per_batch=2000)
    p = _zip(tmp_path, [Entry("a.flac", b"x" * 1000), Entry("b.flac", b"y" * 1000)])
    assert inspect_archive(p, limits, expanded_used=0).members
    _fail(p, "upload_archive_expanded_too_large", tmp_path, limits=limits, expanded_used=1)


def test_huge_non_audio_member_is_not_rejected(tmp_path):
    p = _zip(tmp_path, [Entry("big.txt", b"x" * 3000), Entry("a.flac", AUDIO)])
    plan = inspect_archive(p, tiny_limits())
    assert plan.skipped == 1 and len(plan.members) == 1


# --- U11-B-03: a read error that can pass is not a refusal -----------------

class _ReadFailsOnce:
    """An open archive whose first read fails with ``err``."""

    def __init__(self, path, err):
        self._f = open(path, "rb")
        self._err = err

    def read(self, *args):
        if self._err is not None:
            err, self._err = self._err, None
            raise OSError(err, os.strerror(err))
        return self._f.read(*args)

    def __getattr__(self, name):
        return getattr(self._f, name)


@pytest.mark.parametrize("err", [errno.EIO, errno.EMFILE, errno.ENFILE, errno.ENOMEM, errno.EAGAIN])
def test_a_passing_read_error_is_a_retryable_failure(tmp_path, err):
    p = _zip(tmp_path, [Entry("a.flac", AUDIO)])
    fp = _ReadFailsOnce(p, err)
    try:
        with pytest.raises(ValidationFailed) as ei:
            inspect_archive(fp, tiny_limits())
        assert (ei.value.error.code, ei.value.error.retryable) == ("upload_validation_failed", True)
        # The archive itself is fine: the next read inspects it.
        assert [m.name for m in inspect_archive(fp, tiny_limits()).members] == ["a.flac"]
    finally:
        fp.close()


def test_another_read_error_is_still_an_invalid_archive(tmp_path):
    p = _zip(tmp_path, [Entry("a.flac", AUDIO)])
    fp = _ReadFailsOnce(p, errno.EACCES)
    try:
        _fail(fp, "upload_archive_invalid", tmp_path)
    finally:
        fp.close()


def test_a_passing_read_error_inside_zipfiles_own_read_is_a_retryable_failure(tmp_path, monkeypatch):
    """zipfile re-reads the end record and reports an OSError there as BadZipFile
    (the OSError is its context): still a passing read error, not an invalid archive."""
    p = _zip(tmp_path, [Entry("a.flac", AUDIO)])
    real = zipfile._EndRecData
    calls = []

    def second_read_fails(fp):
        calls.append(True)
        if len(calls) == 2:
            raise OSError(errno.EIO, "io")
        return real(fp)

    monkeypatch.setattr(zipfile, "_EndRecData", second_read_fails)
    with pytest.raises(ValidationFailed) as ei:
        inspect_archive(p, tiny_limits())

    assert len(calls) == 2
    assert (ei.value.error.code, ei.value.error.retryable) == ("upload_validation_failed", True)
