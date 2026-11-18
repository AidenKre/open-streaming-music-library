"""Phase 9D.2e: the Last.fm operator guide ships in backend/README.md.

Spec §7.12: "The operator guide ships in backend/README.md with the
user-facing slice. It covers" eight points; §7.2: the test seam
``OSML_INSECURE_LASTFM_API_URL`` "is not in the operator guide".
Each point is one heading, in order, with the facts the spec requires.
"""

from pathlib import Path

import pytest

README = Path(__file__).resolve().parent.parent / "README.md"
SECTION = "## Last.fm scrobbling (operator guide)"

HEADINGS = [
    "### 1. Register a Last.fm API account and configure the server",
    "### 2. You accept Last.fm's API terms",
    "### 3. Limits",
    "### 4. Open signup",
    "### 5. When scrobbling stops",
    "### 6. Replacing the encryption key",
    "### 7. Purging Last.fm data",
    "### 8. Backups",
]

# What each point must say (spec §7.12 points 1-8).
FACTS = {
    1: ["free", "what your users see", "callback URL blank", "LASTFM_ENABLED",
        "LASTFM_API_KEY", "LASTFM_API_SECRET", "LASTFM_CREDENTIAL_KEY",
        "LASTFM_SETTLE_DELAY_S", "LASTFM_MIN_REQUEST_GAP_S", "Fernet",
        "misspelt", "prints", "`_FILE` variants",
        # signoff-9-lastfm-app-name (DEV-9-06): the optional application name.
        "| `LASTFM_APP_NAME` | none |", "the same name", "without naming it",
        "the wrong name", "ignored with a warning",
        # signoff-9-review-answers (DEV-9-15 row 49): proxies are ignored.
        "ignores proxy settings", "`HTTPS_PROXY`",
        "only through an HTTP proxy cannot scrobble"],
    2: ["the party who accepts", "Non-commercial", "clause 3", "clause 8.2",
        "clauses 2.3 to 2.5", "clause 2.8", "clause 5.1.6", "clause 5.3",
        "privacy policy"],
    3: ["Clause 4.4", "request gap", "share one API key", "suspension",
        "partners@last.fm"],
    4: ["Any signed-in user", "OSML_SIGNUP_ENABLED=false"],
    5: ["`stopped`", "logged", "restart tries again", "suspension",
        "LASTFM_ENABLED=false",
        # signoff-9-review-answers (OPEN-A-08): a wrong setting and the clean-up.
        "When a Last.fm setting is wrong", "the log names the setting",
        "keep queuing", "is not cleaned up", "restart the server with correct settings",
        "older than 14 days are dropped and the rest are sent"],
    6: ["every user reconnect", "already leaked"],
    7: ["lastfm purge", "switch the integration off first", "backups",
        "logs", "settings themselves"],
    8: ["Last.fm usernames", "encrypted session keys", "same backup"],
}


def _guide() -> str:
    text = README.read_text(encoding="utf-8")
    assert text.count(SECTION) == 1
    start = text.index(SECTION)
    end = text.find("\n## ", start + len(SECTION))
    return text[start:] if end < 0 else text[start:end]


def _points(guide: str) -> dict[int, str]:
    lines = guide.splitlines()
    starts = [lines.index(h) for h in HEADINGS]
    assert starts == sorted(starts), "the eight points are in order"
    bounds = starts + [len(lines)]
    return {i + 1: "\n".join(lines[bounds[i]:bounds[i + 1]]) for i in range(8)}


def test_the_section_has_the_eight_headings_in_order():
    guide = _guide()
    found = [line for line in guide.splitlines() if line.startswith("### ")]
    assert found == HEADINGS


@pytest.mark.parametrize("point", range(1, 9))
def test_each_point_states_what_the_spec_requires(point):
    body = " ".join(_points(_guide())[point].split())
    missing = [fact for fact in FACTS[point] if fact not in body]
    assert not missing


def test_the_test_seam_is_not_in_the_guide():
    assert "OSML_INSECURE_LASTFM_API_URL" not in README.read_text(encoding="utf-8")


def test_the_tests_section_is_still_there():
    text = README.read_text(encoding="utf-8")
    assert text.count("\n## Tests\n") == 1
    assert "uv run pytest" in text[text.index("\n## Tests\n"):]
