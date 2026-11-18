"""Cross-user access policy (SC-28 rule 7).

Cross-user access is granted in this one place. In Phase M a user may act only
on their own data; future friend features extend this module instead of adding
owner checks elsewhere.

It has no production caller yet: Phase M has no cross-user feature, and every
owned read is already scoped by ``Library``. It is kept so the first friend
feature has one place to extend (review r1 m-R1-24).
"""


def can(viewer, action, owner) -> bool:
    for who in (viewer, owner):
        if not isinstance(who, int) or isinstance(who, bool):
            raise TypeError(f"user ids must be int, got {who!r}")
    return viewer == owner
