"""Unit tests for the libinput binding.

Nothing here opens a device. The fake shared library and the fixtures live in
tests/conftest.py.
"""

import ctypes
import errno
import os

import pytest

from sway_radial import libinput as li


def test_pinch_enum_values_match_the_header():
    assert (li.PINCH_BEGIN, li.PINCH_UPDATE, li.PINCH_END) == (803, 804, 805)


def test_double_returning_symbols_declare_c_double(fake_context):
    lib = fake_context.lib
    for name in ("libinput_event_gesture_get_scale",
                 "libinput_event_gesture_get_dx",
                 "libinput_event_gesture_get_dy"):
        assert lib.restypes[name] is ctypes.c_double, name


def test_pointer_returning_symbols_declare_c_void_p(fake_context):
    lib = fake_context.lib
    for name in ("libinput_udev_create_context", "libinput_get_event",
                 "libinput_event_get_gesture_event"):
        assert lib.restypes[name] is ctypes.c_void_p, name


def test_poll_yields_only_pinch_events(fake_context):
    fake_context.queue([(li.PINCH_BEGIN, 4), (807, 4), (li.PINCH_UPDATE, 4)])
    got = [e.type for e in fake_context.ctx.poll()]
    assert got == [li.PINCH_BEGIN, li.PINCH_UPDATE]


def test_poll_destroys_every_event_including_ignored_ones(fake_context):
    fake_context.queue([(li.PINCH_BEGIN, 4), (807, 4), (806, 4)])
    list(fake_context.ctx.poll())
    assert fake_context.lib.destroyed == 3


def test_assign_seat_failure_raises(fake_context_factory):
    with pytest.raises(li.LibinputError, match="seat"):
        fake_context_factory(assign_seat_returns=-1)


def test_create_context_failure_raises(fake_context_factory):
    with pytest.raises(li.LibinputError, match="context"):
        fake_context_factory(create_context_returns=None)


def test_callbacks_are_kept_alive(fake_context):
    # The CFUNCTYPE objects must be reachable from the instance or libinput
    # dereferences freed memory on the next hotplug.
    assert fake_context.ctx._interface is not None
    assert fake_context.ctx._open_cb is not None
    assert fake_context.ctx._close_cb is not None


def test_poll_dispatches_exactly_once_per_call(fake_context):
    # Not dispatching leaves the descriptor readable forever, which is a busy
    # loop that pins a core. Dispatching per event would be a second bug.
    fake_context.queue([(li.PINCH_BEGIN, 4), (li.PINCH_UPDATE, 4)])
    list(fake_context.ctx.poll())
    assert fake_context.lib.dispatched == 1
    list(fake_context.ctx.poll())
    assert fake_context.lib.dispatched == 2


def test_gesture_fields_reach_the_event(fake_context):
    fake_context.queue([
        {"type": li.PINCH_UPDATE, "finger_count": 4, "scale": 0.8,
         "dx": -3.5, "dy": 7.25, "cancelled": 1},
        {"type": li.PINCH_END, "finger_count": 4, "scale": 1.2, "cancelled": 1},
    ])
    update, ended = list(fake_context.ctx.poll())
    assert (update.finger_count, update.scale, update.dx, update.dy) == (4, 0.8, -3.5, 7.25)
    # libinput defines cancelled on an END event only and logs a client bug for
    # the others, so the binding must not ask on an update.
    assert update.cancelled is False
    assert ended.cancelled is True


def test_open_restricted_opens_the_node_itself(fake_context, tmp_path):
    node = tmp_path / "event-stand-in"
    node.write_bytes(b"")
    fd = fake_context.ctx._open_cb(str(node).encode(), os.O_RDONLY, None)
    assert fd > 0
    fake_context.ctx._close_cb(fd, None)
    assert fake_context.ctx._open_cb(b"/dev/input/there-is-no-such-node",
                                    os.O_RDONLY, None) == -errno.ENOENT


def test_poll_tracks_the_devices_libinput_opened(fake_context):
    # A missing uaccess rule is silent: the context is created and the seat is
    # assigned either way, so the device list is the only symptom.
    assert fake_context.ctx.devices == ()
    fake_context.queue([
        {"type": li.DEVICE_ADDED, "device_name": b"Apple Inc. Magic Trackpad USB-C"},
        {"type": li.DEVICE_ADDED, "device_name": b"DYGMA DEFY Keyboard"},
    ])
    list(fake_context.ctx.poll())
    assert fake_context.ctx.devices == ("Apple Inc. Magic Trackpad USB-C", "DYGMA DEFY Keyboard")
    fake_context.queue([{"type": li.DEVICE_REMOVED, "device_name": b"DYGMA DEFY Keyboard"}])
    list(fake_context.ctx.poll())
    assert fake_context.ctx.devices == ("Apple Inc. Magic Trackpad USB-C",)
