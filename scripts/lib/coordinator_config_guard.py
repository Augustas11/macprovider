"""L0 one-writer guard for the live coordinator config (#1693), Python writers.

Same contract as scripts/lib/coordinator-config-guard.sh: a writer of the live
/opt/macprovider/coordinator.yaml or /etc/macprovider/coordinator.pearl-overlays.yaml
holds the Pearl lock set in lease order (updater lock, then the coordinator
deploy lock) across its read-modify-write + HUP, and refuses while the pricing
transaction journal <install_root>/.pricing-txn exists.

Installed on Pearl at /usr/local/share/macprovider/scripts/coordinator_config_guard.py
by ops/pearl-updater/install-pearl-updater.sh; the updater and the Tier-2
enforcement watchdog load it from there. Standard library only.
"""

from __future__ import annotations

import fcntl
import os
from pathlib import Path
import stat
from typing import Optional

PRICING_TXN_NAME = ".pricing-txn"
# coordinator-pricing-recover --resolve-deploy-conflict sets the journal aside
# under this prefix while it runs deploy recovery under the lock set; one left
# behind (the resolver was killed) is still a live pricing transaction.
PRICING_TXN_HELD_PREFIX = PRICING_TXN_NAME + ".conflict-held."
DEPLOY_LOCK_NAME = ".coordinator-deploy.lock"
UPDATER_LOCK_PATH = Path("/run/lock/macprovider-pearl-updater.lock")
EX_REFUSED = 75
EX_PRE_START_JOURNAL = 76


class PricingTransactionActive(RuntimeError):
    """A pricing transaction journal exists; live config writers must not run."""

    def __init__(self, path: Path):
        self.path = path
        super().__init__(refusal_message(path))


class GuardLockError(RuntimeError):
    """A lock in the set is unsafe (wrong type, owner, mode or link count)."""


class GuardLockBusy(GuardLockError):
    """A lock in the set is held by another writer (non-blocking acquisition)."""


def pricing_txn_path(install_root: os.PathLike[str] | str) -> Path:
    return Path(install_root) / PRICING_TXN_NAME


def refusal_message(path: os.PathLike[str] | str) -> str:
    return (
        f"refusing: pricing transaction journal present at {path}; "
        "run scripts/catalog-content-release.sh --recover-pricing-txn"
    )


def refuse_if_pricing_txn(install_root: os.PathLike[str] | str) -> None:
    """Raise PricingTransactionActive when <install_root>/.pricing-txn exists,
    or a journal set aside under PRICING_TXN_HELD_PREFIX does.

    Presence is a path-entry test (a dangling symlink counts), matching the
    shell guard's `[ -e ] || [ -L ]`. The shell guard does not check set-aside
    journals: deploy recovery, which uses it, runs inside the set-aside window.
    """
    path = pricing_txn_path(install_root)
    if os.path.lexists(path):
        raise PricingTransactionActive(path)
    try:
        names = os.listdir(install_root)
    except FileNotFoundError:
        return
    for name in sorted(names):
        if name.startswith(PRICING_TXN_HELD_PREFIX):
            raise PricingTransactionActive(Path(install_root) / name)


def acquire_lock(
    path: os.PathLike[str] | str,
    *,
    required_uid: int = 0,
    required_gid: Optional[int] = 0,
    blocking: bool = False,
) -> int:
    """Open (creating 0600 when absent, never following a symlink) and flock one lock.

    Returns the locked descriptor; the caller closes it to release. required_gid
    None skips the group check (test harnesses whose files inherit a directory
    group).
    """
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if not nofollow:
        raise GuardLockError("this platform cannot open locks without following symlinks")
    flags = os.O_RDWR | os.O_CLOEXEC | nofollow
    try:
        descriptor = os.open(path, flags | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        try:
            descriptor = os.open(path, flags)
        except OSError as exc:
            raise GuardLockError(f"cannot safely open coordinator config lock {path}: {exc}") from exc
    except OSError as exc:
        raise GuardLockError(f"cannot safely open coordinator config lock {path}: {exc}") from exc
    try:
        info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != required_uid
            or (required_gid is not None and info.st_gid != required_gid)
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_nlink != 1
        ):
            raise GuardLockError(f"refusing: unsafe coordinator config lock {path}")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError as exc:
            raise GuardLockBusy(f"refusing: coordinator config lock held: {path}") from exc
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


class LockSet:
    """Hold the lease-order lock set and refuse while a pricing journal exists.

    with LockSet(install_root): ...   # updater lock, deploy lock, journal check
    hold_updater=False is for a writer that already holds the updater lock on
    its own descriptor (the Pearl updater, the watchdog): it then takes only the
    deploy lock, which keeps lease order.
    """

    def __init__(
        self,
        install_root: os.PathLike[str] | str,
        *,
        updater_lock: os.PathLike[str] | str = UPDATER_LOCK_PATH,
        deploy_lock: Optional[os.PathLike[str] | str] = None,
        hold_updater: bool = True,
        required_uid: int = 0,
        required_gid: Optional[int] = 0,
        blocking: bool = False,
    ):
        self.install_root = Path(install_root)
        self.updater_lock = Path(updater_lock)
        self.deploy_lock = Path(deploy_lock) if deploy_lock is not None else self.install_root / DEPLOY_LOCK_NAME
        self.hold_updater = hold_updater
        self.required_uid = required_uid
        self.required_gid = required_gid
        self.blocking = blocking
        self.descriptors: list[int] = []

    def __enter__(self) -> "LockSet":
        paths = ([self.updater_lock] if self.hold_updater else []) + [self.deploy_lock]
        try:
            for path in paths:
                self.descriptors.append(
                    acquire_lock(
                        path,
                        required_uid=self.required_uid,
                        required_gid=self.required_gid,
                        blocking=self.blocking,
                    )
                )
            refuse_if_pricing_txn(self.install_root)
        except BaseException:
            self.release()
            raise
        return self

    def release(self) -> None:
        while self.descriptors:
            os.close(self.descriptors.pop())

    def __exit__(self, *_: object) -> None:
        self.release()
