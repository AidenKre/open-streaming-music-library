"""What the tool runners receive, in one normal form (refactor BE-TOOLS).

``ToolCalls`` replaces the runner name in every module that starts ffmpeg,
ffprobe or fpcalc with a spy that records the call and then runs the real
runner. A record is ``(site, command, bound, registry, job id, low priority)``:
the command with the test's folder written ``<tmp>`` and the tool's folder
dropped, the time limit (and the stdout cap or the output file), and the
per-run options. Each call is bound to the real runner's signature first, so
an argument the runner does not take fails the test.

``choices(**kw)`` is how a test passes per-run options to a function whose
signature carries them. ``tool_call(runner, *args, **kwargs)`` is the same
check for the hand-written runner fakes of other tests.
"""

from __future__ import annotations

import dataclasses
import functools
import inspect
import os
from pathlib import Path
from typing import Any

from app.services import (
    audio_identity,
    fingerprinter,
    ingestion,
    metadata,
    transcoder,
    upload_validation,
)
from app.services import ffmpeg_runner



def option_fields(options) -> dict[str, Any]:
    """A ``ToolOptions`` value's fields by name (every field, also those added
    later), for a fake's call record."""
    assert isinstance(options, ffmpeg_runner.ToolOptions), options
    return {field.name: getattr(options, field.name) for field in dataclasses.fields(options)}


def tool_call(function, *args, **kwargs) -> dict[str, Any]:
    """The arguments of one call to ``function`` (a runner, or any tool function
    that takes ``options``) as the real function binds them, defaults applied;
    an argument it does not take raises ``TypeError``. The options' fields are
    added by name (``registry``, ``job_id``, ``low_priority``, ``input_format``)."""
    bound = inspect.signature(function).bind(*args, **kwargs)
    bound.apply_defaults()
    values = dict(bound.arguments)
    values.update(option_fields(values["options"]))
    return values


def choices(**kw: Any) -> dict[str, Any]:
    """The keyword arguments that pass these per-run options to a tool function."""
    return {"options": ffmpeg_runner.ToolOptions(**kw)}


def bound_to(real):
    """Decorator for a hand-written stand-in of ``real`` (a tool function that
    takes ``options``): each call is first bound to ``real``'s signature, so an
    argument the real function does not take fails instead of being swallowed."""
    def wrap(fake):
        @functools.wraps(fake)
        def checked(*args, **kwargs):
            tool_call(real, *args, **kwargs)
            return fake(*args, **kwargs)

        return checked

    return wrap


class ToolCalls:
    def __init__(self, monkeypatch, tmp_path: Path, labels: dict[str, Any] | None = None):
        self.records: list[tuple] = []
        self._tmp = sorted({str(tmp_path), str(Path(tmp_path).resolve())}, key=len, reverse=True)
        self._labels = {id(obj): name for name, obj in (labels or {}).items()}
        for module in (audio_identity, fingerprinter, metadata, ingestion):
            monkeypatch.setattr(module, "run_capture", self._capture_spy(module.__name__))
        monkeypatch.setitem(
            upload_validation.probe_upload.__kwdefaults__, "run",
            self._capture_spy("app.services.upload_validation"))
        for module in (metadata, transcoder):
            monkeypatch.setattr(module, "run_ffmpeg", self._ffmpeg_spy(module.__name__))
        # The cached ``ffmpeg -version`` answer would hide the version run.
        monkeypatch.setattr(audio_identity, "_tool_versions_cache", None)

    # -- normal form ---------------------------------------------------------------------

    def _text(self, value: Any) -> str:
        text = str(value)
        for prefix in self._tmp:
            text = text.replace(prefix, "<tmp>")
        return text

    def _command(self, cmd) -> list[str]:
        argv = [self._text(a) for a in cmd]
        if argv and os.path.isabs(argv[0]):
            argv[0] = os.path.basename(argv[0])
        return argv

    def _label(self, value: Any) -> Any:
        if value is None:
            return None
        return self._labels.get(id(value), "<unnamed>")

    @staticmethod
    def _job(value: Any) -> Any:
        if value is None or isinstance(value, (str, int, tuple)):
            return value
        return "<object>"

    def _options(self, call: dict) -> tuple:
        return self._label(call["registry"]), self._job(call["job_id"]), call["low_priority"]

    def _capture_spy(self, site: str):
        real = ffmpeg_runner.run_capture
        short = site.rsplit(".", 1)[-1]

        def spy(cmd, **kwargs):
            call = tool_call(real, cmd, **kwargs)
            self.records.append((
                f"{short}.run_capture", self._command(cmd),
                ("timeout_s", call["timeout_s"], "max_stdout_bytes", call["max_stdout_bytes"]),
                *self._options(call),
            ))
            return real(cmd, **kwargs)

        return spy

    def _ffmpeg_spy(self, site: str):
        real = ffmpeg_runner.run_ffmpeg
        short = site.rsplit(".", 1)[-1]

        def spy(cmd, output_path, *args, **kwargs):
            call = tool_call(real, cmd, output_path, *args, **kwargs)
            self.records.append((
                f"{short}.run_ffmpeg", self._command(cmd),
                ("timeout", call["timeout"], "output", self._text(output_path)),
                *self._options(call),
            ))
            return real(cmd, output_path, *args, **kwargs)

        return spy
