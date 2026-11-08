"""lock-screen: swaylock over the lock image that backdrop names.

Locking never waits on the image: whatever backdrop does, swaylock starts."""

import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from conftest import BACKDROP, BASH, LOCK_SCREEN, load_png, rgb, where, W, H

LOCK_SCREEN_WRAPPED = [os.environ.get("LOCK_SCREEN_WRAPPED") or LOCK_SCREEN[0]]

# What lock-screen runs, and nothing else: no real swaylock, backdrop or
# swaymsg of the machine the tests run on can be found.
TOOLS = ["bash", "sh", "cat", "env", "id", "pgrep", "setsid", "sleep", "tail", "timeout", "dirname"]


DAEMON_NAMES = ["swaylock", ".swaylock-wrapped"]


@pytest.fixture
def locker(lab):
    for tool in TOOLS:
        target = shutil.which(tool)
        assert target, tool
        link = lab.stubs / tool
        if not link.exists():
            link.symlink_to(target)
    # The daemon swaylock -f leaves, as a copy of bash that has its name: on
    # NixOS swaylock is a wrapper that execs .swaylock-wrapped, which the
    # kernel names .swaylock-wrapp, so both are tried.
    lab.daemons = lab.root / "daemon"
    lab.daemons.mkdir()
    for name in DAEMON_NAMES:
        shutil.copy2(BASH, lab.daemons / name)
    lab.extra_env.update(PATH=str(lab.stubs), STUB_DAEMON=str(lab.daemons / "swaylock"))
    return lab


def backdrop_stub(lab, body):
    lab.install_stub("backdrop", "#!/usr/bin/env bash\n" + body)


def passthrough(lab):
    """The real backdrop, found on the stand-in PATH."""
    args = " ".join("'%s'" % a for a in BACKDROP)
    backdrop_stub(lab, "exec %s \"$@\"\n" % args)


def lock(lab, program=None, **env):
    return subprocess.run(
        list(program or LOCK_SCREEN),
        env=lab.env(**env),
        capture_output=True,
        text=True,
        timeout=60,
    )


def swaylock_calls(lab):
    if not lab.log.exists():
        return []
    return [l for l in lab.log.read_text().splitlines() if l.startswith("swaylock")]


def backdrop_calls(lab):
    return [l for l in lab.log.read_text().splitlines() if l.startswith("backdrop")] if lab.log.exists() else []


def serving(lab, args=("-i", "eDP-1:/cache/lock.png")):
    """A backdrop that names these swaylock arguments, one per line, and logs
    the other commands it is given."""
    listing = lab.work / "lock-args.txt"
    listing.write_text("".join(a + "\n" for a in args))
    backdrop_stub(
        lab,
        'if [[ "$1" == lock-args ]]; then cat -- %s; else echo "backdrop $*" >>"$STUB_LOG"; fi\n'
        % listing,
    )


def test_swaylock_gets_the_image_that_backdrop_names(locker):
    serving(locker)
    proc = lock(locker)
    assert proc.returncode == 0, proc.stderr
    assert swaylock_calls(locker) == ["swaylock [-f] [-i] [eDP-1:/cache/lock.png]"]


def test_one_image_per_output_and_names_with_spaces_stay_whole(locker):
    serving(locker, ["-i", "eDP-1:/a b/one.png", "-i", "DP-2:/c/two.png"])
    lock(locker)
    assert swaylock_calls(locker) == [
        "swaylock [-f] [-i] [eDP-1:/a b/one.png] [-i] [DP-2:/c/two.png]"
    ]


def test_when_backdrop_fails_swaylock_still_locks_on_plain_base(locker):
    backdrop_stub(locker, "echo 'backdrop: boom' >&2; exit 1\n")
    proc = lock(locker)
    assert proc.returncode == 0
    assert swaylock_calls(locker) == ["swaylock [-f]"]
    # What backdrop says reaches the journal through lock-screen's stderr.
    assert "boom" in proc.stderr


def test_when_backdrop_is_missing_swaylock_still_locks(locker):
    proc = lock(locker)
    assert proc.returncode == 0
    assert swaylock_calls(locker) == ["swaylock [-f]"]


def test_when_backdrop_prints_nothing_swaylock_still_locks(locker):
    backdrop_stub(locker, "exit 0\n")
    assert lock(locker).returncode == 0
    assert swaylock_calls(locker) == ["swaylock [-f]"]


def test_a_backdrop_that_hangs_does_not_hold_the_lock(locker):
    backdrop_stub(locker, "sleep 30\n")
    start = time.monotonic()
    proc = lock(locker)
    elapsed = time.monotonic() - start
    assert proc.returncode == 0
    assert swaylock_calls(locker) == ["swaylock [-f]"]
    assert 1.5 < elapsed < 8, "backdrop gets two seconds, no more, no less (%.1f)" % elapsed


def test_swaylock_that_rejects_the_image_is_tried_again_without_it(locker):
    serving(locker)
    proc = lock(locker, STUB_SWAYLOCK_REJECT_IMAGES="1")
    assert proc.returncode == 0
    assert swaylock_calls(locker) == [
        "swaylock [-f] [-i] [eDP-1:/cache/lock.png]",
        "swaylock [-f]",
    ]


def test_a_swaylock_that_cannot_lock_fails_lock_screen(locker):
    serving(locker)
    proc = lock(locker, STUB_SWAYLOCK_FAIL="1")
    assert proc.returncode == 1
    assert len(swaylock_calls(locker)) == 2


def test_without_an_image_one_failed_attempt_is_all(locker):
    proc = lock(locker, STUB_SWAYLOCK_FAIL="1")
    assert proc.returncode == 1
    assert swaylock_calls(locker) == ["swaylock [-f]"]
    assert backdrop_calls(locker) == []


@pytest.mark.parametrize("daemon", DAEMON_NAMES)
def test_the_wallpaper_is_redrawn_once_after_the_unlock(locker, daemon):
    serving(locker)
    start = time.monotonic()
    proc = lock(locker, STUB_LOCK_SECONDS="3", STUB_DAEMON=str(locker.daemons / daemon))
    assert proc.returncode == 0
    assert time.monotonic() - start < 2.5, "lock-screen waited for the unlock"
    assert backdrop_calls(locker) == [], "redrawn before the unlock"
    deadline = time.monotonic() + 15
    while not backdrop_calls(locker) and time.monotonic() < deadline:
        time.sleep(0.1)
    time.sleep(0.5)
    assert backdrop_calls(locker) == ["backdrop wallpaper"]


def test_a_lock_that_failed_redraws_nothing(locker):
    serving(locker)
    lock(locker, STUB_SWAYLOCK_FAIL="1")
    time.sleep(1.5)
    assert backdrop_calls(locker) == []


def test_end_to_end_with_the_real_backdrop(locker):
    passthrough(locker)
    proc = lock(locker, program=LOCK_SCREEN_WRAPPED)
    assert proc.returncode == 0, proc.stderr
    [call] = swaylock_calls(locker)
    prefix = "swaylock [-f] [-i] [eDP-1:"
    assert call.startswith(prefix) and call.endswith("]"), call
    image = Path(call[len(prefix) : -1])
    assert image.parent == locker.cache / "backdrop"
    img = load_png(image)
    assert img.shape == (H, W, 3)
    assert where(img, rgb("mauve")).sum() > 3000
