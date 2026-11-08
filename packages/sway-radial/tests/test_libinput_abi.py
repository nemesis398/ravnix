"""The binding against the real libraries, and against libinput's own header.

test_libinput.py proves the binding behaves over a fake library. This file asks
the two things a fake cannot: that the libraries load under the names the
binding uses, and that every number and signature in the binding is the one in
libinput.h. A wrong event type fails silently (the daemon runs, logs nothing
and the menu never opens), and a libinput that renumbered or dropped a symbol
would do exactly that, so the check is worth its few lines.

SWAY_RADIAL_TEST_LIBINPUT_H names libinput.h; the Nix check hands over the
header of the libinput it links. Without it the header tests are skipped.
"""

import ctypes
import os
import re
from pathlib import Path

import pytest

from sway_radial import libinput as li


def test_libinput_loads_under_the_name_the_binding_uses():
    lib = li._load_libinput()
    for name in li._LIBINPUT_SIGNATURES:
        assert hasattr(lib, name), f"{li.LIBINPUT_SONAME} has no {name}"


def test_libudev_loads_under_the_name_the_binding_uses():
    lib = li._load_libudev()
    for name in li._LIBUDEV_SIGNATURES:
        assert hasattr(lib, name), f"{li.LIBUDEV_SONAME} has no {name}"


def test_a_name_that_does_not_load_is_a_libinput_error(monkeypatch):
    monkeypatch.setattr(li, "LIBINPUT_SONAME", "libsway-radial-nothing.so.0")
    with pytest.raises(li.LibinputError, match="libsway-radial-nothing"):
        li._load_libinput()


@pytest.fixture(scope="module")
def header():
    given = os.environ.get("SWAY_RADIAL_TEST_LIBINPUT_H")
    if not given:
        pytest.skip("SWAY_RADIAL_TEST_LIBINPUT_H is not set; the Nix check hands it over")
    return Path(given).read_text()


def enum_values(text, name):
    """The members of `enum NAME { ... };` with their numbers, implicit ones
    counted on from the one before."""
    body = re.search(rf"enum {name} \{{(.*?)\}};", text, re.S)
    assert body, f"enum {name} is not in the header"
    body = re.sub(r"/\*.*?\*/", "", body.group(1), flags=re.S)
    values, number = {}, -1
    for entry in body.split(","):
        entry = entry.strip()
        if not entry:
            continue
        member, _, given = entry.partition("=")
        number = int(given.strip(), 0) if given.strip() else number + 1
        values[member.strip()] = number
    return values


def test_the_event_numbers_are_the_headers(header):
    events = enum_values(header, "libinput_event_type")
    assert li.DEVICE_ADDED == events["LIBINPUT_EVENT_DEVICE_ADDED"]
    assert li.DEVICE_REMOVED == events["LIBINPUT_EVENT_DEVICE_REMOVED"]
    assert li.PINCH_BEGIN == events["LIBINPUT_EVENT_GESTURE_PINCH_BEGIN"]
    assert li.PINCH_UPDATE == events["LIBINPUT_EVENT_GESTURE_PINCH_UPDATE"]
    assert li.PINCH_END == events["LIBINPUT_EVENT_GESTURE_PINCH_END"]


def test_the_parser_of_the_enum_counts_on_from_the_member_before():
    sample = "enum e { /* c */ A = 0, B, C, /** doc */ D = 0x10, E, };"
    assert enum_values(sample, "e") == {"A": 0, "B": 1, "C": 2, "D": 16, "E": 17}


def test_every_function_the_binding_declares_is_in_the_header(header):
    for name in li._LIBINPUT_SIGNATURES:
        assert re.search(rf"\b{name}\s*\(", header), f"{name} is not declared in libinput.h"


def test_the_functions_that_return_a_double_are_declared_as_one(header):
    """ctypes defaults a return to a 32-bit int, which turns a double into
    garbage; the binding declares c_double for these, and the header agrees."""
    for name, (_args, restype) in li._LIBINPUT_SIGNATURES.items():
        match = re.search(rf"(\w+)\s*\n\s*{name}\s*\(", header)
        if match and match.group(1) == "double":
            assert restype is ctypes.c_double, f"{name} returns a double in the header"
    declared = [n for n, (_a, r) in li._LIBINPUT_SIGNATURES.items() if r is ctypes.c_double]
    assert declared, "the binding declares no double"
    for name in declared:
        assert re.search(rf"double\s*\n\s*{name}\s*\(", header), f"{name} is no double in the header"
