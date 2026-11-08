"""Hardware smoke tests. Deselected by default, see pyproject.toml.

Run them with: python -m pytest tests/smoke -m hardware
"""

import pytest

from sway_radial.libinput import Libinput


@pytest.mark.hardware
def test_opens_a_real_context():
    ctx = Libinput()
    try:
        assert ctx.fd > 0
    finally:
        ctx.close()


@pytest.mark.hardware
def test_libinput_can_actually_read_a_pointing_device():
    """The context opening is not evidence that anything was opened.

    libinput_udev_create_context and libinput_udev_assign_seat both return
    success when every evdev node is refused with EACCES, and libinput logs
    nothing at its default priority. Without this test the smoke suite passes
    identically before and after the uaccess udev rule, which makes it useless
    as the check on that rule.
    """
    ctx = Libinput()
    try:
        list(ctx.poll())  # drains the DEVICE_ADDED burst that assign_seat queued
        names = ctx.devices
        assert any("Trackpad" in n or "Touchpad" in n for n in names), (
            f"libinput opened {names!r} and no pointing device. The evdev node is "
            f"root:input with no ACL for this user, so the uaccess udev rule is missing."
        )
    finally:
        ctx.close()
