"""Shared check for the app tests of the background workers, moved out of
``tests/test_identity_worker_app.py``: whether the server instance lock is held."""

from app.core.instance_lock import InstanceLockHeld, acquire_instance_lock


def _lock_is_held(data_dir) -> bool:
    try:
        acquire_instance_lock(data_dir).release()
    except InstanceLockHeld:
        return True
    return False
