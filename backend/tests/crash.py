"""The one stand-in for a process killed at a chosen point (SP-TS-07)."""


class Crash(BaseException):
    """The process dies here: not an ``Exception``, so no handler may swallow it
    and nothing after this point runs."""
