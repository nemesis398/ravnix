import logging
import pytest
from pathlib import Path
from sway_radial.daemon import Daemon, focused_output

def test_missing_config_falls_back_to_the_packaged_default(tmp_path, caplog):
    d = Daemon(config_path=tmp_path / "nope.toml")
    assert d.menu is not None
    assert "nope.toml" in caplog.text

def test_malformed_config_on_reload_keeps_the_old_tree(tmp_path, caplog):
    p = tmp_path / "menu.toml"
    p.write_text('[[items]]\ndir="n"\nlabel="A"\nexec="true"\n')
    d = Daemon(config_path=p)
    before = d.menu
    p.write_text("[[items]\nbroken")
    d._on_config_changed()
    assert d.menu is before
    assert "broken" in caplog.text or "menu.toml" in caplog.text

def test_a_permission_error_on_libinput_is_logged_once_not_raised(monkeypatch, caplog):
    from sway_radial import libinput as li
    def boom(*a, **k): raise li.LibinputError("Permission denied")
    monkeypatch.setattr(li, "Libinput", boom)
    d = Daemon()
    d.start_input()                      # must not raise
    d.start_input()
    assert caplog.text.count("Permission denied") == 1

def test_focused_output_parses_swaymsg(monkeypatch):
    payload = '[{"name":"eDP-1","focused":true,"rect":{"x":0,"y":0,"width":2880,"height":1800}}]'
    monkeypatch.setattr("sway_radial.daemon._swaymsg", lambda *a: payload)
    assert focused_output() == ("eDP-1", (1440.0, 900.0))

def test_the_layout_position_is_not_part_of_the_origin(monkeypatch):
    """The regression. Widget coordinates are surface local, so an output's
    place in the layout must not reach the origin.

    Both outputs here are off the layout origin, which is exactly what the old
    fixture was missing: it used x=0, y=0, where the wrong answer and the right
    one are the same number. On the real machine this put the ring 328 px past
    the right edge of the external screen, drawn onto a surface that ends at
    3440, and it looked like the gesture was never delivered."""
    payload = (
        '[{"name":"eDP-1","focused":false,"rect":{"x":0,"y":160,"width":2048,"height":1280}},'
        '{"name":"HDMI-A-1","focused":true,"rect":{"x":2048,"y":0,"width":3440,"height":1440}}]'
    )
    monkeypatch.setattr("sway_radial.daemon._swaymsg", lambda *a: payload)
    assert focused_output() == ("HDMI-A-1", (1720.0, 720.0))

def test_focused_output_falls_back_when_none_is_focused(monkeypatch):
    payload = '[{"name":"eDP-1","focused":false,"rect":{"x":0,"y":0,"width":800,"height":600}}]'
    monkeypatch.setattr("sway_radial.daemon._swaymsg", lambda *a: payload)
    assert focused_output() == ("eDP-1", (400.0, 300.0))

def test_focused_output_survives_no_sway(monkeypatch):
    monkeypatch.setattr("sway_radial.daemon._swaymsg", lambda *a: (_ for _ in ()).throw(OSError()))
    assert focused_output() == (None, (0.0, 0.0))


class _StubInput:
    """Stands in for Libinput. The device list only fills once something drains
    the queue, which is exactly how the real binding behaves: assign_seat queues
    a DEVICE_ADDED burst and nothing exists until a poll() consumes it."""

    def __init__(self, names):
        self._names = list(names)
        self.fd = 10
        self.drained = False

    @property
    def devices(self):
        return tuple(self._names) if self.drained else ()

    def poll(self):
        self.drained = True
        return iter(())


class _StubGlib:
    PRIORITY_DEFAULT = 0

    class IOCondition:
        IN = 1

    def unix_fd_add_full(self, priority, fd, condition, callback):
        self.watched = (fd, callback)


def test_the_device_list_is_read_after_the_burst_is_drained(caplog):
    caplog.set_level(logging.INFO)
    d = Daemon()
    d._input = _StubInput(["Apple Inc. Magic Trackpad USB-C"])
    d._watch_input(_StubGlib())
    assert "Magic Trackpad" in caplog.text


def test_opening_no_device_is_an_error_naming_the_uaccess_rule(caplog):
    caplog.set_level(logging.INFO)
    d = Daemon()
    d._input = _StubInput([])
    d._watch_input(_StubGlib())
    assert "uaccess" in caplog.text
    assert any(r.levelname == "ERROR" for r in caplog.records)


class _FakeGlib:
    """Records timer traffic instead of running a main loop."""

    def __init__(self):
        self.added = []
        self.removed = []
        self._next_id = 1

    def timeout_add(self, ms, callback):
        self.added.append((ms, callback))
        source_id = self._next_id
        self._next_id += 1
        return source_id

    def source_remove(self, source_id):
        self.removed.append(source_id)


_DWELL_TREE = """
dwell_ms = 200
[[items]]
dir = "n"
label = "Apps"
  [[items.items]]
  dir = "n"
  label = "Browser"
  exec = "true"
[[items]]
dir = "e"
label = "Clip"
exec = "true"
"""


def _dwelling_daemon(tmp_path):
    path = tmp_path / "menu.toml"
    path.write_text(_DWELL_TREE)
    d = Daemon(config_path=path)
    d._glib = _FakeGlib()
    return d


def _event(kind, **kw):
    from sway_radial.gesture import Event

    return Event(kind=kind, **kw)


def _drive(d, *events):
    for event in events:
        d._apply(d._machine.handle(event))


def test_highlighting_a_sector_arms_the_dwell_with_the_configured_time(tmp_path):
    d = _dwelling_daemon(tmp_path)
    _drive(d, _event("begin"), _event("update", scale=0.8), _event("update", scale=0.8, dy=-100))
    assert [ms for ms, _cb in d._glib.added] == [200]


def test_resting_on_one_sector_does_not_restart_the_clock(tmp_path):
    """The bug this design is most exposed to.

    A hand holding still is not silent: libinput keeps sending PINCH_UPDATE as
    the fingers jitter. Arming on every result would reset the countdown on each
    one, so the dwell could never elapse and holding still would do nothing,
    which is indistinguishable from the feature not being wired up at all.
    """
    d = _dwelling_daemon(tmp_path)
    _drive(d, _event("begin"), _event("update", scale=0.8), _event("update", scale=0.8, dy=-100))
    for _ in range(20):
        _drive(d, _event("update", scale=0.8, dx=0.4, dy=-0.4))
        _drive(d, _event("update", scale=0.8, dx=-0.4, dy=0.4))
    assert len(d._glib.added) == 1
    assert d._glib.removed == []


def test_moving_to_another_sector_restarts_it_once(tmp_path):
    d = _dwelling_daemon(tmp_path)
    _drive(d, _event("begin"), _event("update", scale=0.8), _event("update", scale=0.8, dy=-100))
    _drive(d, _event("update", scale=0.8, dx=100, dy=100))   # north -> east
    assert len(d._glib.added) == 2
    assert len(d._glib.removed) == 1


def test_the_back_sector_is_armed_like_any_other(tmp_path):
    """Back is on the dwell since 2026-09-05, so it has a countdown of its own.

    It used to pop on contact. That was affordable while a reach past the ring
    was what selected anything; with one sector always lit, crossing south on
    the way somewhere else would silently throw away a level.
    """
    d = _dwelling_daemon(tmp_path)
    _drive(d, _event("begin"), _event("update", scale=0.8), _event("update", scale=0.8, dy=-100))
    d._apply(d._machine.dwell())                    # into Apps, Back is south
    armed_before = len(d._glib.added)
    _drive(d, _event("update", scale=0.8, dy=60))   # point at Back
    assert len(d._glib.added) == armed_before + 1
    assert d._dwell_target == "s"
    d._glib.added[-1][1]()                          # and holding still pops
    assert d._path == []


def test_returning_to_the_hub_hands_the_countdown_over_to_the_exit(tmp_path):
    """Not a plain cancel any more, since the menu needed a way out.

    Coming back to the middle stops the sector's clock and starts the exit's, so
    exactly one timer is ever live. The daemon does not decide which: it arms
    whatever the machine put in dwell_target, so the rule for when leaving is
    allowed stays in one place.
    """
    d = _dwelling_daemon(tmp_path)
    _drive(d, _event("begin"), _event("update", scale=0.8), _event("update", scale=0.8, dy=-100))
    _drive(d, _event("update", scale=0.8, dy=100))  # back into the dead zone
    assert len(d._glib.removed) == 1
    assert [ms for ms, _cb in d._glib.added] == [200, 200]
    assert d._dwell_target == "close"


def test_the_exit_countdown_hides_the_menu_and_runs_nothing(tmp_path):
    d = _dwelling_daemon(tmp_path)
    ran = []
    import sway_radial.daemon as mod

    original, mod.run_item = mod.run_item, ran.append
    try:
        _drive(d, _event("begin"), _event("update", scale=0.8), _event("update", scale=0.8, dy=-100))
        _drive(d, _event("update", scale=0.8, dy=100))
        # Named before firing, or this passes on the sector timer that was
        # already running and proves nothing about the exit at all.
        assert d._dwell_target == "close"
        d._glib.added[-1][1]()                       # the timer fires
    finally:
        mod.run_item = original
    assert ran == []
    assert d._ring is None and d._dwell_target is None


def test_the_hub_is_not_armed_on_a_fresh_ring(tmp_path):
    """Opening the menu must not start a countdown to closing it."""
    d = _dwelling_daemon(tmp_path)
    _drive(d, _event("begin"), _event("update", scale=0.8))
    assert d._glib.added == []
    assert d._dwell_target is None


class _FakeOverlay:
    """Records what the daemon asks of the surface."""

    def __init__(self):
        self.calls = []

    def show(self, origin, output):
        self.calls.append(("show", origin, output))

    def hide(self):
        self.calls.append(("hide",))

    def set_latched(self, latched):
        self.calls.append(("latched", latched))

    def update(self, menu, highlighted, breadcrumb):
        self.calls.append(("update", highlighted, breadcrumb))

    def start_dwell(self, ms):
        self.calls.append(("dwell", ms))

    def cancel_dwell(self):
        pass


def _mouse_daemon(tmp_path, monkeypatch):
    import sway_radial.daemon as daemon_mod

    monkeypatch.setattr(daemon_mod, "focused_output", lambda: ("eDP-1", (1024.0, 640.0)))
    d = _dwelling_daemon(tmp_path)
    d._overlay = _FakeOverlay()
    return d


def test_the_toggle_opens_the_menu_latched_on_the_focused_output(tmp_path, monkeypatch):
    d = _mouse_daemon(tmp_path, monkeypatch)
    d.toggle_latched()
    assert ("show", (1024.0, 640.0), "eDP-1") in d._overlay.calls
    assert ("latched", True) in d._overlay.calls
    assert d._latched
    assert d._glib.added == []          # no dwell is armed for the pointer


def test_the_toggle_closes_a_menu_that_is_open(tmp_path, monkeypatch):
    d = _mouse_daemon(tmp_path, monkeypatch)
    d.toggle_latched()
    d.toggle_latched()
    assert d._overlay.calls[-1] == ("hide",)
    assert d._ring is None


def test_the_toggle_ignores_a_pinch_in_progress(tmp_path, monkeypatch):
    """The fingers own a live gesture; a stray button press must not yank it."""
    d = _mouse_daemon(tmp_path, monkeypatch)
    _drive(d, _event("begin"), _event("update", scale=0.8))
    calls = len(d._overlay.calls)
    d.toggle_latched()
    assert d._ring is not None
    assert ("hide",) not in d._overlay.calls[calls:]


def test_hovering_redraws_with_the_new_highlight(tmp_path, monkeypatch):
    d = _mouse_daemon(tmp_path, monkeypatch)
    d.toggle_latched()
    d._on_hover("e")
    assert d._overlay.calls[-1] == ("update", "e", ())


# ── the menu file watch through a symlink, 2026-10-06 ────────────────────────
# The installed ~/.config/sway-radial/menu.toml is a symlink into another tree
# (home-manager's, in the Nix store).
# GIO watches the directory a path sits in, so a monitor on the link sees no
# edit to the target at all. Measured: zero events for an in-place write and
# for an atomic rename, while a monitor on the resolved path saw both.

_ONE_ITEM = '[[items]]\ndir="n"\nlabel="{label}"\nexec="true"\n'


def _linked_config(tmp_path):
    tree = tmp_path / "target"
    home = tmp_path / "home"
    tree.mkdir()
    home.mkdir()
    real = tree / "menu.toml"
    real.write_text(_ONE_ITEM.format(label="Old"))
    link = home / "menu.toml"
    link.symlink_to(real)
    return link, real


def _run_loop(glib, edit, seconds=1.5):
    loop = glib.MainLoop()
    glib.timeout_add(200, lambda: edit() or False)
    glib.timeout_add(int(seconds * 1000), lambda: loop.quit() or False)
    loop.run()


def _label(d):
    return d.menu.items["n"].label


def test_an_in_place_edit_behind_the_symlink_reloads(tmp_path):
    from gi.repository import Gio, GLib

    link, real = _linked_config(tmp_path)
    d = Daemon(config_path=link)
    d._watch_config(Gio)
    _run_loop(GLib, lambda: real.write_text(_ONE_ITEM.format(label="New")))
    assert _label(d) == "New"


def test_a_rename_into_place_behind_the_symlink_reloads_without_an_error(tmp_path, caplog):
    """A deploy writes a temp file and renames it over the target. GIO reports
    that as deleted, then created, and the deleted half must not be read as a
    broken config."""
    import os

    from gi.repository import Gio, GLib

    link, real = _linked_config(tmp_path)
    d = Daemon(config_path=link)
    d._watch_config(Gio)

    def rename():
        tmp = real.with_suffix(".tmp")
        tmp.write_text(_ONE_ITEM.format(label="Renamed"))
        os.replace(tmp, real)

    _run_loop(GLib, rename)
    assert _label(d) == "Renamed"
    assert "reload failed" not in caplog.text
