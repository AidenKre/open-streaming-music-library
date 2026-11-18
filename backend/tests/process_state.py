"""Is a process still running? For the tests that check a killed process group
is gone (pre-merge D2-02).

``os.kill(pid, 0)`` succeeds on a zombie: a process that has exited but that
its parent has not reaped yet. A child orphaned by a group kill is re-parented
to PID 1; where PID 1 does not reap (a container started without an init),
the zombie stays for good. A zombie runs nothing, so it counts as gone here.
"""

import os
import subprocess
import sys


def process_state(pid: int) -> str | None:
    """The process's state letter(s), or None when there is no such process."""
    if sys.platform.startswith("linux"):
        try:
            with open(f"/proc/{pid}/stat", "rb") as stat:
                text = stat.read().decode("ascii", "replace")
        except FileNotFoundError:
            return None
        # "pid (comm) S ...": comm may hold spaces or parentheses.
        return text[text.rindex(")") + 2:].split(" ", 1)[0]
    result = subprocess.run(
        ["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True, check=False
    )
    state = result.stdout.strip()
    return state or None


def pid_alive(pid: int) -> bool:
    """True while ``pid`` exists and is not a zombie."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass  # it exists, owned by someone else
    state = process_state(pid)
    return state is not None and not state.startswith("Z")
