"""The daemon: one GLib main loop joining libinput, the state machine and the overlay.

Nothing here is allowed to be clever, because everything here is a failure mode
someone will meet at three in the morning with no keyboard attached. A missing
trackpad, a config file broken by a half-finished edit, a sway that is not
running: each of those keeps the daemon alive and logs once, and none of them
takes the menu away from the paths that still work.

GTK is imported inside :meth:`Daemon.run` rather than at module scope. Building
a Daemon has to work with no display, both so the tests can do it and so a
startup failure is a log line rather than an import traceback.

The origin of the ring is the center of the focused output's surface, not the
pointer.
Design section 4 asked for the pointer and that is not implementable: Wayland
hands no client the global cursor position, and sway's IPC does not carry one
either. For the use this exists for, driving the machine from a couch with no
keyboard, a fixed origin is arguably the better answer anyway, because the menu
is always in the same place and you never have to find the cursor first.
"""

from __future__ import annotations

import json
import logging
import signal
import subprocess
from pathlib import Path

from . import libinput
from .actions import run_item
from .config import ConfigError, load_config
from .gesture import FINGERS, Event, GestureMachine, Outcome, Result
from .libinput import PINCH_BEGIN, PINCH_END, PINCH_UPDATE
from .model import DEFAULT_DWELL_MS, Direction, Menu, Settings

__all__ = ["DEFAULT_CONFIG", "Daemon", "focused_output"]

log = logging.getLogger(__name__)

DEFAULT_CONFIG = Path("~/.config/sway-radial/menu.toml").expanduser()

#: libinput's three pinch types, mapped onto the state machine's vocabulary.
#: Anything else libinput hands over is not ours and is dropped.
_EVENT_KINDS = {PINCH_BEGIN: "begin", PINCH_UPDATE: "update", PINCH_END: "end"}


def _swaymsg(*args: str) -> str:
    """Run swaymsg and return its raw stdout.

    A module level seam the tests monkeypatch, so it stays one function that
    returns a string and parses nothing.
    """
    return subprocess.run(
        ["swaymsg", *args], check=True, capture_output=True, text=True
    ).stdout


def _packaged_menu() -> Path | None:
    """The shipped default menu, located relative to this module.

    Three candidates because the package is used from two trees: the source
    directory keeps ``menu.toml`` a level above ``src/``, and the installed copy
    keeps it beside the package, in ``lib/sway-radial/``. Looking for a file
    rather than hardcoding a layout means neither tree has to know about the
    other.
    """
    here = Path(__file__).resolve().parent
    candidates = (here / "menu.toml", here.parent / "menu.toml", here.parent.parent / "menu.toml")
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def focused_output() -> tuple[str | None, tuple[float, float]]:
    """The focused output's connector name, and the center of its surface.

    The center is deliberately ``(width / 2, height / 2)`` and the output's
    position in the layout does not appear in it at all. A layer surface is
    anchored to one output and its widget coordinates start at (0, 0) in that
    output's top left corner, so a global layout coordinate drawn into it lands
    somewhere else entirely, or nowhere.

    This returned ``x + width / 2`` until 2026-09-05, which was invisible on a
    single output at the layout origin and wrong the moment a second one
    appeared: 160 px too low on a panel at ``y=160``, and 328 px past the right
    edge of an external screen at ``x=2048``, where the whole ring fell outside
    the surface. Nothing failed and nothing was logged. It presented exactly as
    a gesture that never arrived.

    The name is returned with it so the overlay can pin itself to the same
    output it was measured against, rather than letting the compositor choose.

    Falls back to the first output, then to no name and (0, 0). Every failure
    here is survivable: a wrong origin puts the ring in the wrong place, and an
    exception would take the whole gesture down.
    """
    try:
        outputs = json.loads(_swaymsg("-t", "get_outputs"))
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        log.warning("cannot ask sway for the outputs, centering on (0, 0): %s", exc)
        return (None, (0.0, 0.0))

    if not isinstance(outputs, list) or not outputs:
        log.warning("sway reported no outputs, centering on (0, 0)")
        return (None, (0.0, 0.0))

    chosen = next((o for o in outputs if isinstance(o, dict) and o.get("focused")), outputs[0])
    if not isinstance(chosen, dict):
        return (None, (0.0, 0.0))
    name = chosen.get("name")
    rect = chosen.get("rect")
    if not isinstance(rect, dict):
        return (name if isinstance(name, str) else None, (0.0, 0.0))
    width = float(rect.get("width", 0.0))
    height = float(rect.get("height", 0.0))
    return (name if isinstance(name, str) else None, (width / 2, height / 2))


class Daemon:
    """Everything wired together, and nothing decided here that belongs elsewhere."""

    def __init__(self, config_path: Path = DEFAULT_CONFIG) -> None:
        self.config_path = Path(config_path)
        self.menu: Menu | None = None
        self.settings = Settings(dwell_ms=DEFAULT_DWELL_MS)
        self._machine: GestureMachine | None = None
        self._input: libinput.Libinput | None = None
        # One flag, one log line. A trackpad that is absent stays absent, and a
        # daemon that says so on every retry is worse than one that says nothing.
        self._input_failed = False
        self._overlay = None
        self._config_monitor = None
        self._origin: tuple[float, float] = (0.0, 0.0)
        # The output the origin was measured on. The overlay pins itself to it,
        # so the surface it draws into is the one the numbers describe.
        self._output: str | None = None
        # The ring currently on screen. Taken straight off the last Result, never
        # accumulated here: the machine owns the stack and select()/pop() are how
        # the pointer moves through it.
        self._ring: Menu | None = None
        self._path: list[str] = []
        self._latched = False
        # The dwell: which sector is being counted down on, and the GLib source
        # counting. Held apart so a stream of PINCH_UPDATEs on the same sector
        # does not restart the clock on every event, which would mean the timer
        # could never elapse while a finger rests and jitters in place.
        self._dwell_target: str | None = None
        self._dwell_source: int | None = None
        # Set in run(). Building a Daemon must not need GTK, so everything that
        # touches the main loop checks this first.
        self._glib = None

        self._load_initial()
        if self.menu is not None:
            self._machine = GestureMachine(self.menu)

    # -- lifecycle ----------------------------------------------------------

    def run(self) -> int:
        # Deferred on purpose, twice over. Importing the overlay pulls in
        # gtk4-layer-shell and GTK, and importing gi.repository needs a working
        # typelib, so neither may run while a Daemon is merely being built.
        from gi.repository import Gio, GLib

        self._glib = GLib

        from .overlay import Overlay

        self._overlay = Overlay(
            on_click=self._on_click,
            on_escape=self._on_escape,
            on_back=self._on_back,
            on_hover=self._on_hover,
        )

        self.start_input()
        self._watch_input(GLib)
        self._watch_config(Gio)

        loop = GLib.MainLoop()
        for signum in (signal.SIGINT, signal.SIGTERM):
            # Python's own handler cannot run while the C main loop has the
            # thread, so Ctrl-C and systemd's stop both need GLib to deliver it.
            GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signum, self._quit, loop)
        # SIGUSR1 opens or closes the menu for the pointer. sway-mouse sends it
        # from the MX Master's gesture button. True keeps the handler installed.
        GLib.unix_signal_add(
            GLib.PRIORITY_DEFAULT, signal.SIGUSR1, lambda: self.toggle_latched() or True
        )

        log.info("sway-radial is up, menu from %s", self.config_path)
        try:
            loop.run()
        finally:
            if self._input is not None:
                self._input.close()
                self._input = None
        return 0

    def start_input(self) -> None:
        """Open the libinput context, or log once and carry on without one.

        No trackpad is not a fatal condition. The daemon still runs, the config
        monitor still works, and the menu simply never opens, which is exactly
        what a user with an unplugged pad should see rather than a service that
        restarts in a loop.
        """
        if self._input is not None or self._input_failed:
            return
        try:
            self._input = libinput.Libinput()
        except libinput.LibinputError as exc:
            self._input_failed = True
            log.error("no gesture input, the menu will not open: %s", exc)

    def _quit(self, loop) -> bool:
        log.info("stopping")
        loop.quit()
        return False  # GLib.SOURCE_REMOVE

    # -- configuration ------------------------------------------------------

    def _load_initial(self) -> None:
        """Load the configured menu, or the packaged default when it is broken."""
        try:
            self.menu, self.settings = load_config(self.config_path)
            return
        except ConfigError as exc:
            log.error("%s; falling back to the packaged default", exc)

        fallback = _packaged_menu()
        if fallback is None:
            log.error("no packaged default menu was found either, the menu cannot open")
            return
        try:
            self.menu, self.settings = load_config(fallback)
        except ConfigError as exc:
            log.error("the packaged default menu is broken too: %s", exc)

    def _on_config_changed(self, *args) -> None:
        """Reload. On ConfigError, log and keep the previous tree live."""
        try:
            menu, settings = load_config(self.config_path)
        except ConfigError as exc:
            # Deliberately not the packaged default. You are editing the file,
            # and having the menu silently revert to the shipped tree halfway
            # through would hide the mistake rather than report it.
            log.error("reload failed, keeping the menu that is already loaded: %s", exc)
            return

        self.menu = menu
        self.settings = settings
        if self._machine is None:
            self._machine = GestureMachine(menu)
        else:
            self._machine.set_root(menu)
        log.info("reloaded %s", self.config_path)

    def _watch_config(self, gio) -> None:
        """Watch the menu file, and through a symlink, the file it points at.

        The path is a symlink (home-manager's, into the Nix store), and GIO
        watches the directory a path sits in. A monitor on the link alone
        therefore never saw an edit to the target, in place or by rename, and
        the menu kept its old tree until a restart (found 2026-10-06; the note
        had promised a menu edit needs no restart). So the resolved target is
        watched too. The link itself stays watched, so a new generation that
        replaces it still reloads.
        """
        paths = [self.config_path]
        target = self.config_path.resolve()
        if target != self.config_path:
            paths.append(target)

        monitors = []
        for path in paths:
            try:
                monitor = gio.File.new_for_path(str(path)).monitor_file(
                    gio.FileMonitorFlags.NONE, None
                )
            except Exception as exc:  # noqa: BLE001
                log.warning("cannot watch %s for changes: %s", path, exc)
                continue
            monitor.connect("changed", self._on_monitor_event, gio)
            monitors.append(monitor)
        # Held on the instance: a GFileMonitor that is collected stops emitting,
        # and it does it without a word.
        self._config_monitor = monitors

    def _on_monitor_event(self, monitor, file, other, event, gio) -> None:
        # Only the hint GIO sends once a write has settled. CHANGED fires
        # mid-write and would parse half a file, and a rename into place, which
        # is how a deploy writes, arrives as DELETED then CREATED, where the
        # first half reads a missing file and logs a failed reload on every
        # deploy. Measured 2026-10-06: both an in-place write and a rename end
        # in exactly this event.
        if event != gio.FileMonitorEvent.CHANGES_DONE_HINT:
            return
        self._on_config_changed()

    # -- input --------------------------------------------------------------

    def _watch_input(self, glib) -> None:
        if self._input is None:
            return
        try:
            fd = self._input.fd
        except libinput.LibinputError as exc:
            log.error("libinput has no descriptor to watch: %s", exc)
            return
        glib.unix_fd_add_full(
            glib.PRIORITY_DEFAULT, fd, glib.IOCondition.IN, self._on_libinput_ready
        )
        # Drain the DEVICE_ADDED burst assign_seat has already queued, so the
        # list below is the real one. Reading it before the first drain always
        # reported "none yet", whatever the permissions were, which left the one
        # diagnostic built to catch a missing uaccess rule unable to report it.
        self._on_libinput_ready(fd, None)
        # The device list is the only cheap proof the pad is actually readable:
        # the context opens fine even when every evdev node is refused.
        if self._input.devices:
            log.info(
                "watching libinput on fd %d, devices: %s",
                fd,
                ", ".join(self._input.devices),
            )
        else:
            # ERROR, not INFO. This is the whole silent failure: libinput opened
            # nothing, said so to nobody, and the menu will never appear.
            log.error(
                "watching libinput on fd %d, but it opened no device, so the "
                "menu can never open. That is almost always a missing uaccess "
                "udev rule: getfacl on the trackpad's /dev/input/event node "
                "should list your user.",
                fd,
            )

    def _on_libinput_ready(self, fd: int, condition) -> bool:
        """GLib callback. Must return True or GLib drops the watch."""
        if self._input is not None:
            try:
                # The descriptor is level triggered and is never read directly.
                # Reading it means one poll(), which dispatches and drains.
                for event in self._input.poll():
                    self._feed(event)
            except libinput.LibinputError as exc:
                log.error("libinput poll failed: %s", exc)
        # Never False. GLib removes the source on a false return and the menu
        # then works exactly once, which looks like a gesture problem.
        return True

    def _feed(self, event: libinput.GestureEvent) -> None:
        kind = _EVENT_KINDS.get(event.type)
        if kind is None or self._machine is None:
            return

        if kind == "begin" and event.finger_count == FINGERS:
            # Asked once per gesture, not per update: swaymsg is a subprocess
            # and the ring has to be on screen before the fingers have moved.
            self._output, self._origin = focused_output()

        result = self._machine.handle(
            Event(
                kind=kind,
                finger_count=event.finger_count,
                scale=event.scale,
                dx=event.dx,
                dy=event.dy,
                cancelled=event.cancelled,
            )
        )
        self._apply(result)

    # -- the overlay --------------------------------------------------------

    def _apply(self, result: Result) -> None:
        """Drive the overlay from one Result and nothing else."""
        # First, because every path out of this method has to leave the dwell
        # clock in a state that matches the frame being drawn, including the
        # early return that hides the ring.
        self._sync_dwell(result)
        self._ring = result.menu
        self._path = list(result.breadcrumb)

        # Running the item lives here rather than in the caller so that the two
        # ways of choosing something, the fingers and a click in latched mode,
        # cannot end up with different behavior.
        if result.outcome is Outcome.EXECUTED and result.item is not None:
            run_item(result.item)

        if not result.visible:
            self._hide()
            return

        if result.outcome is Outcome.OPENED:
            self._latched = False
            if self._overlay is not None:
                self._overlay.set_latched(False)
                self._overlay.show(self._origin, self._output)

        self._redraw(result.highlighted)

        if result.outcome is Outcome.LATCHED and not self._latched:
            self._latched = True
            if self._overlay is not None:
                self._overlay.set_latched(True)

    # -- the dwell ----------------------------------------------------------

    def _sync_dwell(self, result: Result) -> None:
        """Start, keep or cancel the countdown, from the frame alone.

        Restarting only when the sector changes is the whole trick. Arming on
        every result would reset the clock on each PINCH_UPDATE, and a resting
        hand still produces those, so the dwell would never elapse and holding
        still would do nothing at all.
        """
        # What is worth dwelling on is the machine's decision, not this one's:
        # it owns the ring, the depth and whether the fingers have been out to
        # the edge yet. Here we only own the clock.
        target = result.dwell_target
        if (
            not result.visible
            or result.outcome is Outcome.LATCHED
            or self._latched
        ):
            target = None

        if target == self._dwell_target:
            return

        self._cancel_dwell()
        self._dwell_target = target
        if target is None or self._glib is None:
            return
        self._dwell_source = self._glib.timeout_add(self.settings.dwell_ms, self._on_dwell)
        if self._overlay is not None:
            self._overlay.start_dwell(self.settings.dwell_ms)

    def _cancel_dwell(self) -> None:
        if self._dwell_source is not None and self._glib is not None:
            self._glib.source_remove(self._dwell_source)
        self._dwell_source = None
        if self._overlay is not None:
            self._overlay.cancel_dwell()

    def _on_dwell(self) -> bool:
        # Cleared before _apply, which calls _sync_dwell, which would otherwise
        # try to remove a source GLib is in the middle of retiring.
        self._dwell_source = None
        self._dwell_target = None
        # The arc is static, so nothing runs it out. Whatever the action does
        # (closes the ring, leaves no target to count down to), the arc of the
        # dwell that just fired must not outlive it.
        if self._overlay is not None:
            self._overlay.cancel_dwell()
        if self._machine is not None:
            self._apply(self._machine.dwell())
        return False  # GLib.SOURCE_REMOVE

    def _redraw(self, highlighted: Direction | None) -> None:
        if self._overlay is None or self._ring is None:
            return
        self._overlay.update(self._ring, highlighted, tuple(self._path))

    def _hide(self) -> None:
        self._ring = None
        self._path = []
        self._latched = False
        if self._overlay is not None:
            self._overlay.set_latched(False)
            self._overlay.hide()

    # -- latched, pointer driven --------------------------------------------

    def toggle_latched(self) -> None:
        """Open the menu latched, or close it if it is already on screen.

        The entry point for anything that is not the trackpad, which since
        2026-10-06 means SIGUSR1 from the mouse's gesture button. A pinch still
        in progress is left alone: the fingers own a live gesture, and a stray
        press must not pull the ring out from under them.
        """
        if self._machine is None:
            return
        if self._ring is not None:
            if self._latched:
                self._apply(self._machine.dismiss())
            return
        # Measured per open, like a pinch does, so the ring lands on whichever
        # output has focus now.
        self._output, self._origin = focused_output()
        self._apply(self._machine.open_latched())
        self._latched = True
        if self._overlay is not None:
            self._overlay.set_latched(True)

    def _on_hover(self, direction: Direction | None) -> None:
        if self._machine is None:
            return
        result = self._machine.hover(direction)
        # Motion arrives on every pixel, so only a changed sector redraws.
        if result.outcome is Outcome.UPDATED:
            self._apply(result)

    def _on_click(self, direction: Direction) -> None:
        if self._machine is not None:
            self._apply(self._machine.select(direction))

    def _on_back(self) -> None:
        if self._machine is not None:
            self._apply(self._machine.pop())

    def _on_escape(self) -> None:
        # Esc pops one level and closes at the top, per the design. pop() already
        # falls through to dismiss at the top ring, so Esc and mouse button 8 are
        # deliberately the same action rather than two behaviors to remember.
        if self._machine is None:
            self._hide()
            return
        self._apply(self._machine.pop())
