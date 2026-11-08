"""ctypes binding to libinput's gesture API.

Every enum value and signature here was read out of ``libinput.h``, the header
shipped with the library (``tests/test_libinput_header.py`` compares the values
with it). Do not substitute remembered values: a wrong event type fails
silently, because ``libinput_get_event`` happily returns events whose type never
matches anything the daemon tests for, and the menu simply never opens.

The context is created through udev rather than by path, so hotplugging the
trackpad does not need a restart.
"""

from __future__ import annotations

import ctypes
import errno
import logging
import os
from collections.abc import Iterator
from dataclasses import dataclass

log = logging.getLogger(__name__)

LIBINPUT_SONAME = "libinput.so.10"
LIBUDEV_SONAME = "libudev.so.1"

# enum libinput_event_type, libinput 1.31.3. The daemon acts on the three pinch
# types and on nothing else. The hold pair, 806 and 807, is deliberately left to
# sway, which binds hold:4 itself (modules/desktop/sway/50-laptop.conf).
DEVICE_ADDED = 1
DEVICE_REMOVED = 2
PINCH_BEGIN = 803
PINCH_UPDATE = 804
PINCH_END = 805

_PINCH_TYPES = frozenset((PINCH_BEGIN, PINCH_UPDATE, PINCH_END))


class LibinputError(Exception):
    """A libinput call failed in a way the caller cannot paper over."""


@dataclass(frozen=True, slots=True)
class GestureEvent:
    type: int
    finger_count: int
    scale: float
    dx: float
    dy: float
    cancelled: bool


OPEN_RESTRICTED = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p)
CLOSE_RESTRICTED = ctypes.CFUNCTYPE(None, ctypes.c_int, ctypes.c_void_p)


class libinput_interface(ctypes.Structure):
    """struct libinput_interface: two function pointers, in this order."""

    _fields_ = [
        ("open_restricted", OPEN_RESTRICTED),
        ("close_restricted", CLOSE_RESTRICTED),
    ]


# argtypes and restype for every symbol this module resolves. ctypes defaults
# restype to a 32 bit int, so leaving any of these undeclared truncates the
# pointer returns and turns a double return into garbage. The failure lands as
# a segfault minutes later, nowhere near the call, which is why the whole table
# is declared in one place instead of at each call site.
_LIBINPUT_SIGNATURES = {
    "libinput_udev_create_context": (
        (ctypes.POINTER(libinput_interface), ctypes.c_void_p, ctypes.c_void_p),
        ctypes.c_void_p,
    ),
    "libinput_udev_assign_seat": ((ctypes.c_void_p, ctypes.c_char_p), ctypes.c_int),
    "libinput_unref": ((ctypes.c_void_p,), ctypes.c_void_p),
    "libinput_get_fd": ((ctypes.c_void_p,), ctypes.c_int),
    "libinput_dispatch": ((ctypes.c_void_p,), ctypes.c_int),
    "libinput_get_event": ((ctypes.c_void_p,), ctypes.c_void_p),
    "libinput_event_destroy": ((ctypes.c_void_p,), None),
    "libinput_event_get_type": ((ctypes.c_void_p,), ctypes.c_int),
    "libinput_event_get_gesture_event": ((ctypes.c_void_p,), ctypes.c_void_p),
    "libinput_event_gesture_get_finger_count": ((ctypes.c_void_p,), ctypes.c_int),
    "libinput_event_gesture_get_scale": ((ctypes.c_void_p,), ctypes.c_double),
    "libinput_event_gesture_get_dx": ((ctypes.c_void_p,), ctypes.c_double),
    "libinput_event_gesture_get_dy": ((ctypes.c_void_p,), ctypes.c_double),
    "libinput_event_gesture_get_cancelled": ((ctypes.c_void_p,), ctypes.c_int),
    "libinput_event_get_device": ((ctypes.c_void_p,), ctypes.c_void_p),
    "libinput_device_get_name": ((ctypes.c_void_p,), ctypes.c_char_p),
}

_LIBUDEV_SIGNATURES = {
    "udev_new": ((), ctypes.c_void_p),
    "udev_unref": ((ctypes.c_void_p,), ctypes.c_void_p),
}


def _load_libinput():
    """Seam. The unit tests replace this with a fake library."""
    try:
        return ctypes.CDLL(LIBINPUT_SONAME)
    except OSError as exc:
        raise LibinputError(f"cannot load {LIBINPUT_SONAME}: {exc}") from exc


def _load_libudev():
    """Seam. The unit tests replace this with a fake library."""
    try:
        return ctypes.CDLL(LIBUDEV_SONAME)
    except OSError as exc:
        raise LibinputError(f"cannot load {LIBUDEV_SONAME}: {exc}") from exc


def _declare(lib, signatures) -> None:
    for name, (argtypes, restype) in signatures.items():
        fn = getattr(lib, name)
        fn.argtypes = list(argtypes)
        fn.restype = restype


def _open_restricted(path, flags, _user_data) -> int:
    """Open an evdev node and hand libinput the descriptor.

    This is a plain os.open and it must stay one. Asking logind instead would
    be worse than useless: TakeDevice on a node sway already holds returns
    DeviceIsTaken, and a later ReleaseDevice would revoke sway's own descriptor
    and kill input for the whole session. Access comes from the uaccess udev
    rule on the seat, not from a device manager handshake.
    """
    try:
        return os.open(path, flags)
    except OSError as exc:
        # libinput expects a negative errno here. An exception raised out of a
        # ctypes callback is printed and swallowed, and the return value is
        # then garbage, so nothing may escape.
        return -(exc.errno or errno.EIO)
    except Exception:
        log.exception("open_restricted failed for %r", path)
        return -errno.EIO


def _close_restricted(fd, _user_data) -> None:
    try:
        os.close(fd)
    except OSError as exc:
        log.warning("close_restricted could not close fd %d: %s", fd, exc)


class Libinput:
    """A udev backed libinput context that yields pinch gestures."""

    def __init__(self, seat: str = "seat0") -> None:
        self._ctx = None
        self._udev = None
        self._devices: list[str] = []

        self._lib = _load_libinput()
        self._udev_lib = _load_libudev()
        _declare(self._lib, _LIBINPUT_SIGNATURES)
        _declare(self._udev_lib, _LIBUDEV_SIGNATURES)

        # libinput keeps the raw pointers out of this struct for the life of
        # the context. If the CFUNCTYPE objects are collected, the crash lands
        # on the next device hotplug rather than here, so all three stay
        # reachable from the instance and none of them is a local.
        self._open_cb = OPEN_RESTRICTED(_open_restricted)
        self._close_cb = CLOSE_RESTRICTED(_close_restricted)
        self._interface = libinput_interface(self._open_cb, self._close_cb)

        self._udev = self._udev_lib.udev_new()
        if not self._udev:
            raise LibinputError("udev_new() returned NULL")

        self._ctx = self._lib.libinput_udev_create_context(
            ctypes.byref(self._interface), None, self._udev
        )
        if not self._ctx:
            self.close()
            raise LibinputError("libinput_udev_create_context() returned NULL, no context")

        if self._lib.libinput_udev_assign_seat(self._ctx, seat.encode()) != 0:
            self.close()
            raise LibinputError(f"libinput_udev_assign_seat() rejected seat {seat!r}")

    @property
    def devices(self) -> tuple[str, ...]:
        """Names of the devices libinput has actually opened.

        This is the only cheap proof that the daemon can see the trackpad at
        all. Creating the context and assigning the seat both succeed even when
        every evdev node is refused with EACCES, and libinput logs nothing at
        its default priority, so a missing uaccess rule presents as a daemon
        that runs and never fires. The list fills as poll() drains the
        DEVICE_ADDED burst that assign_seat queues.
        """
        return tuple(self._devices)

    @property
    def fd(self) -> int:
        """The descriptor to watch. Readable means events are pending.

        It is level triggered and it is never read from directly. Reading it
        means calling poll().
        """
        return self._lib.libinput_get_fd(self._require_context())

    def poll(self) -> Iterator[GestureEvent]:
        """Dispatch once, then yield every pending pinch event.

        Destroys every event it is handed, including the ones it does not
        yield. The drain runs to completion before anything is yielded, so a
        caller that breaks out of the loop early cannot leave events undestroyed
        or leave the descriptor readable.
        """
        ctx = self._require_context()
        # Exactly one dispatch per readable notification. Without it
        # libinput_get_event returns NULL forever while the descriptor stays
        # readable, which is a busy loop that pins a core.
        rc = self._lib.libinput_dispatch(ctx)
        if rc != 0:
            # libinput returns 0 or a negative errno. Anything else would make
            # os.strerror raise out of the error path itself.
            detail = os.strerror(-rc) if rc < 0 else str(rc)
            raise LibinputError(f"libinput_dispatch() failed: {detail}")

        collected: list[GestureEvent] = []
        while True:
            event = self._lib.libinput_get_event(ctx)
            if not event:
                break
            try:
                event_type = self._lib.libinput_event_get_type(event)
                if event_type in _PINCH_TYPES:
                    collected.append(self._read_gesture(event, event_type))
                elif event_type in (DEVICE_ADDED, DEVICE_REMOVED):
                    self._track_device(event, event_type)
            finally:
                # Ownership passes to us the moment the event is handed over.
                # Nothing else frees it, whatever its type.
                self._lib.libinput_event_destroy(event)
        return iter(collected)

    def close(self) -> None:
        if self._ctx is not None:
            self._lib.libinput_unref(self._ctx)
            self._ctx = None
        if self._udev is not None:
            self._udev_lib.udev_unref(self._udev)
            self._udev = None

    def _read_gesture(self, event, event_type: int) -> GestureEvent:
        gesture = self._lib.libinput_event_get_gesture_event(event)
        return GestureEvent(
            type=event_type,
            finger_count=self._lib.libinput_event_gesture_get_finger_count(gesture),
            scale=self._lib.libinput_event_gesture_get_scale(gesture),
            dx=self._lib.libinput_event_gesture_get_dx(gesture),
            dy=self._lib.libinput_event_gesture_get_dy(gesture),
            # Only an END event defines cancelled. libinput logs a client bug
            # for the other types and returns 0 anyway, so asking would buy
            # nothing but log noise.
            cancelled=(
                bool(self._lib.libinput_event_gesture_get_cancelled(gesture))
                if event_type == PINCH_END
                else False
            ),
        )

    def _track_device(self, event, event_type: int) -> None:
        device = self._lib.libinput_event_get_device(event)
        raw = self._lib.libinput_device_get_name(device)
        name = raw.decode(errors="replace") if raw else "<unnamed>"
        if event_type == DEVICE_ADDED:
            self._devices.append(name)
            log.debug("libinput opened %s", name)
        elif name in self._devices:
            # Two devices can share a name, so drop one entry rather than all.
            self._devices.remove(name)

    def _require_context(self):
        if self._ctx is None:
            raise LibinputError("the libinput context is closed")
        return self._ctx
