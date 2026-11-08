"""Shared pytest fixtures.

The libinput fixtures inject a fake shared library through the module level
seams in ``sway_radial.libinput``, so no unit test ever opens a real device.
That module is imported inside the fixture rather than at the top of this file:
conftest is loaded for the whole suite, and a top level import would make every
unrelated test fail while the binding does not exist yet.
"""

import os
from pathlib import Path

import pytest

# Opaque handles. None of them is ever dereferenced, they only have to be
# distinguishable and, above all, truthy. The binding stops reading events when
# libinput_get_event returns a false value, so a zero handle would silently end
# the drain loop one event early.
_FAKE_UDEV = 0x1100
_FAKE_CONTEXT = 0x1000
_FAKE_FD = 7
_FIRST_EVENT = 0x2000

_UNSET = object()


class _FakeFn:
    """One symbol on a :class:`FakeLib`.

    It refuses to be called before both ``argtypes`` and ``restype`` have been
    assigned. A symbol left at the ctypes default returns a 32 bit int, and on
    x86-64 a truncated pointer presents as a segfault minutes later, nowhere
    near the call that caused it. Enforcing the declaration here means every
    symbol the binding actually uses is covered, not just the ones an
    enumerated test happens to name.
    """

    def __init__(self, lib, name):
        self.lib, self.name = lib, name
        self.argtypes = None
        self._restype = None
        self._restype_set = False

    @property
    def restype(self):
        return self._restype

    @restype.setter
    def restype(self, value):
        self._restype = value
        # A void function declares restype None, which is indistinguishable
        # from "never assigned" by value alone, hence the separate flag.
        self._restype_set = True
        self.lib.restypes[self.name] = value

    def __call__(self, *args):
        assert self.argtypes is not None, f"{self.name} was called with no argtypes"
        assert self._restype_set, f"{self.name} was called with no restype"
        return self.lib.dispatch(self.name, *args)


def _record(entry):
    """Normalize a queued event into a full field mapping.

    A plain ``(type, finger_count)`` pair covers most tests. A mapping is
    accepted for the cases that care about scale, dx, dy or cancelled.
    """
    fields = {"type": 0, "finger_count": 4, "scale": 1.0, "dx": 0.0, "dy": 0.0,
              "cancelled": 0, "device_name": b"fake device"}
    if isinstance(entry, dict):
        unknown = set(entry) - set(fields)
        assert not unknown, f"unknown event fields: {sorted(unknown)}"
        fields.update(entry)
    else:
        etype, finger_count = entry
        fields.update(type=etype, finger_count=finger_count)
    return fields


class FakeLib:
    """Stands in for libinput.so.10 and for libudev.so.1.

    Records restype assignments so a test can prove the pointer and double
    returns were declared, counts the events it handed out and the ones that
    came back destroyed, and hands out opaque integer handles for every call
    that returns a pointer.
    """

    def __init__(self, events=(), *, context=_UNSET, assign_seat_returns=0):
        self.restypes = {}
        self.destroyed = 0
        self.dispatched = 0
        self.unreffed_context = 0
        self.unreffed_udev = 0
        self.seat = None
        self.context = _FAKE_CONTEXT if context is _UNSET else context
        self.assign_seat_returns = assign_seat_returns
        self._events = [_record(e) for e in events]
        self._live = {}
        self._handed = 0

    def __getattr__(self, name):
        # Dunder lookups reach here only through explicit getattr, and turning
        # one into a fake symbol confuses every introspecting tool there is.
        if name.startswith("__"):
            raise AttributeError(name)
        fn = _FakeFn(self, name)
        setattr(self, name, fn)
        return fn

    def queue(self, events):
        self._events.extend(_record(e) for e in events)

    def dispatch(self, name, *args):
        if name == "udev_new":
            return _FAKE_UDEV
        if name == "udev_unref":
            self.unreffed_udev += 1
            return None
        if name == "libinput_udev_create_context":
            return self.context
        if name == "libinput_udev_assign_seat":
            self.seat = args[1]
            return self.assign_seat_returns
        if name == "libinput_unref":
            self.unreffed_context += 1
            return None
        if name == "libinput_get_fd":
            return _FAKE_FD
        if name == "libinput_dispatch":
            self.dispatched += 1
            return 0
        if name == "libinput_get_event":
            if not self._events:
                return None
            handle = _FIRST_EVENT + self._handed
            self._handed += 1
            self._live[handle] = self._events.pop(0)
            return handle
        if name == "libinput_event_destroy":
            self.destroyed += 1
            # Dropping it here turns a use after free into a KeyError on the
            # next read rather than into nothing at all.
            self._live.pop(args[0], None)
            return None
        if name == "libinput_event_get_device":
            # The same handle stands in for the device view of the event.
            assert args[0] in self._live, "device taken from a destroyed event"
            return args[0]
        if name == "libinput_device_get_name":
            return self._live[args[0]]["device_name"]
        if name == "libinput_event_get_gesture_event":
            # The same handle stands in for the gesture view of the event.
            assert args[0] in self._live, "gesture view taken from a destroyed event"
            return args[0]
        if name == "libinput_event_get_type":
            return self._live[args[0]]["type"]
        if name == "libinput_event_gesture_get_finger_count":
            return self._live[args[0]]["finger_count"]
        if name == "libinput_event_gesture_get_scale":
            return self._live[args[0]]["scale"]
        if name == "libinput_event_gesture_get_dx":
            return self._live[args[0]]["dx"]
        if name == "libinput_event_gesture_get_dy":
            return self._live[args[0]]["dy"]
        if name == "libinput_event_gesture_get_cancelled":
            return self._live[args[0]]["cancelled"]
        raise AssertionError(f"the binding called an unexpected symbol: {name}")


class FakeContext:
    """A :class:`sway_radial.libinput.Libinput` wired to a :class:`FakeLib`."""

    def __init__(self, lib, udev, ctx):
        self.lib = lib
        self.udev = udev
        self.ctx = ctx

    def queue(self, events):
        self.lib.queue(events)


@pytest.fixture
def fake_context_factory(monkeypatch):
    """Build a Libinput over a fake shared library.

    ``create_context_returns`` and ``assign_seat_returns`` drive the two
    failure paths, so the constructor is allowed to raise out of the factory.
    """

    def factory(*, events=(), create_context_returns=_UNSET, assign_seat_returns=0):
        from sway_radial import libinput as li

        lib = FakeLib(
            events, context=create_context_returns, assign_seat_returns=assign_seat_returns
        )
        udev = FakeLib()
        monkeypatch.setattr(li, "_load_libinput", lambda: lib)
        monkeypatch.setattr(li, "_load_libudev", lambda: udev)
        return FakeContext(lib, udev, li.Libinput())

    return factory


@pytest.fixture
def fake_context(fake_context_factory):
    return fake_context_factory()


@pytest.fixture(scope="session")
def menu_path() -> Path:
    """The menu file the menu tests judge: the packaged default menu.

    SWAY_RADIAL_TEST_MENU names another file, so that whoever sets
    ravnix.desktop.radial.menu can run the same tests (the default-menu tests
    and the font tests) on their own menu.
    """
    given = os.environ.get("SWAY_RADIAL_TEST_MENU")
    if given:
        return Path(given)
    from sway_radial.daemon import _packaged_menu

    path = _packaged_menu()
    assert path is not None, "the packaged default menu was not found"
    return path
