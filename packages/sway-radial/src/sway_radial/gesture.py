"""The gesture state machine: pinch events in, one immutable Result out.

Every call to :meth:`GestureMachine.handle` mutates the private state and hands
back a fresh frozen :class:`Result` describing what the screen should now show.
The overlay is driven from that return value alone and never reads a private
attribute, which is what keeps this module testable with no compositor and no
trackpad: a test is a list of events and a list of expected Results.

Two numbers do the work. A pinch has to close past :data:`ARM_SCALE` before any
sector will highlight, so a resting hand selects nothing, and it has to open
back past :data:`COMMIT_SCALE` to execute. Arming is sticky on purpose: the
spread that commits is itself a rising scale, so an armed gesture that relaxes
is a user finishing, not a user giving up.

Distances are measured from the origin of the ring that is currently open, and
that origin resets on every push and every pop. Depth therefore costs one ring
radius per level instead of a cumulative reach, which is the only reason three
levels fit inside the travel of a trackpad.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from typing import Literal

from .config import submenu
from .geometry import R_RING, direction_at, radius
from .model import CLOSE, DIRECTIONS, Direction, Menu, MenuItem

__all__ = [
    "ARM_SCALE",
    "COMMIT_SCALE",
    "FINGERS",
    "Event",
    "GestureMachine",
    "Outcome",
    "Result",
]

#: Pinch in past this to arm. Below 1.0 because libinput reports scale relative
#: to the start of the gesture.
ARM_SCALE: float = 0.85

#: Spread back out past this to commit.
COMMIT_SCALE: float = 1.0

#: Exactly four, never three and never five. libinput's gesture state machine
#: stops at four fingers, and three belongs to sway's own bindings.
FINGERS: int = 4


class Outcome(StrEnum):
    """What the last event did, as far as the overlay is concerned."""

    IDLE = "idle"
    OPENED = "opened"
    UPDATED = "updated"
    EXECUTED = "executed"
    LATCHED = "latched"
    DISMISSED = "dismissed"


@dataclass(frozen=True, slots=True)
class Event:
    """One pinch event, already stripped of libinput's C types.

    ``scale`` is absolute against the start of the gesture, ``dx`` and ``dy``
    are per-event deltas, which is why the machine integrates them.
    """

    kind: Literal["begin", "update", "end"]
    finger_count: int = FINGERS
    scale: float = 1.0
    dx: float = 0.0
    dy: float = 0.0
    cancelled: bool = False


@dataclass(frozen=True, slots=True)
class Result:
    """Everything the overlay needs for one frame, and nothing else."""

    outcome: Outcome
    visible: bool
    breadcrumb: tuple[str, ...]
    menu: Menu | None
    highlighted: Direction | None
    item: MenuItem | None
    cursor: tuple[float, float]
    #: What a dwell would act on right now: a direction, the literal "close", or
    #: None when holding still would do nothing. The daemon owns the clock and
    #: reads this to decide when to start one, so the rules for what counts as a
    #: dwell target live here with the rest of the state and not in the caller.
    dwell_target: str | None = None


class GestureMachine:
    """The menu's whole behavior, with no GTK and no libinput in sight."""

    def __init__(self, root: Menu) -> None:
        self._root = root
        self._stack: list[Menu] = []
        self._path: list[str] = []
        self._cursor: list[float] = [0.0, 0.0]
        self._active = False
        self._armed = False
        self._latched = False
        self._highlighted: Direction | None = None

    def set_root(self, root: Menu) -> None:
        """Swap the tree after a config reload. Ignored mid-gesture."""
        if self._active:
            # Swapping the tree under the fingers would move the sector the
            # user is already aiming at. The next begin picks the new one up.
            return
        self._root = root

    def handle(self, event: Event) -> Result:
        if event.kind == "begin":
            return self._begin(event)
        if event.kind == "update":
            return self._update(event)
        if event.kind == "end":
            return self._end(event)
        raise ValueError(f"unknown event kind {event.kind!r}")

    def pop(self) -> Result:
        """Back, for the latched mode: mouse button 8 and Esc."""
        if len(self._stack) > 1:
            self._pop_level()
            return self._snapshot(Outcome.UPDATED)
        # At the top ring there is nothing above to go back to, so Back closes.
        return self.dismiss()

    def select(self, direction: Direction) -> Result:
        """Act on a sector the way a pointer click does, for the latched mode.

        This is pop()'s counterpart, and it exists so the daemon does not have to
        keep a second copy of the ring stack in order to drill in with the mouse.
        Two stacks that have to agree are two stacks that can drift apart, and
        the one that drifts would be the one the user is looking at.

        A submenu pushes a level, a leaf runs and closes, the Back sector pops,
        and an empty sector does nothing. That is deliberately the same set of
        outcomes the fingers produce, so the two ways of driving the menu cannot
        disagree about what a sector means.
        """
        if not self._stack:
            return self._snapshot(Outcome.IDLE)
        menu = self._stack[-1]
        if direction == menu.back:
            return self.pop()
        item = menu.items.get(direction)
        if item is None:
            return self._snapshot(Outcome.IDLE)
        if item.is_submenu:
            self._push_level(item)
            return self._snapshot(Outcome.UPDATED)
        self._reset()
        return self._snapshot(Outcome.EXECUTED, item)

    def open_latched(self) -> Result:
        """Open the top ring already latched, for a trigger with no direction.

        Added 2026-10-06 for the MX Master's gesture button. A button press
        carries no movement to steer by, so the menu skips the finger phase and
        lands where letting go of an unspread pinch lands: on screen, waiting
        for the pointer. Nothing is armed, so no dwell can count down, and a
        pinch that begins afterwards resets it like any other latched menu.
        """
        self._reset()
        self._stack = [self._root]
        self._latched = True
        self._highlighted = self._default_highlight()
        return self._snapshot(Outcome.OPENED)

    def hover(self, direction: Direction | None) -> Result:
        """Move the highlight to the sector under the pointer, latched only.

        The highlight is the cursor in this design, and in the latched mode the
        pointer is the only thing moving, so without this the lit sector would
        stay wherever the menu opened while the click lands somewhere else.
        The hub and empty sectors keep the last highlight rather than going
        dark, which keeps "one sector is always lit" true for the mouse too.
        Ignored mid-gesture, where the fingers own the highlight.
        """
        if not self._latched or self._active or not self._stack:
            return self._snapshot(Outcome.IDLE)
        menu = self._stack[-1]
        if direction is None or direction == self._highlighted:
            return self._snapshot(Outcome.IDLE)
        if direction != menu.back and direction not in menu.items:
            return self._snapshot(Outcome.IDLE)
        self._highlighted = direction
        return self._snapshot(Outcome.UPDATED)

    def dwell(self) -> Result:
        """Act on the sector the fingers have been resting on.

        Submenus drill in, leaves run. This replaced drilling in at the commit
        radius on 2026-09-05: reaching 140 px opened whatever sector you were
        crossing on the way somewhere else, so the ring changed under the hand
        mid-movement. Holding still is a thing you only do on purpose.

        The daemon owns the clock and calls this once it has elapsed, which
        keeps the machine synchronous and ignorant of milliseconds. A wall clock
        also beats timing this from libinput's own event timestamps, because
        libinput only emits an update when something changes: the quieter the
        hand, the fewer timestamps arrive, and holding still is exactly the
        interval being measured. How sparse that gets on a resting hand was
        never measured here, which is the point. A timer does not care.

        Back is on the same dwell as everything else since 2026-09-05. It used
        to pop the moment you pointed at it, on the theory that a correction
        should be cheaper than going in. With one sector always lit that stops
        being a discount and becomes a hazard: crossing south on the way
        anywhere else would throw away a level under the hand.
        """
        target = self._dwell_target()
        if target is None:
            return self._snapshot(Outcome.IDLE)
        if target == CLOSE:
            return self.dismiss()
        if target == self._stack[-1].back:
            self._pop_level()
            return self._snapshot(Outcome.UPDATED)
        item = self._stack[-1].items.get(target)
        if item is None:
            return self._snapshot(Outcome.IDLE)
        if item.is_submenu:
            self._push_level(item)
            return self._snapshot(Outcome.UPDATED)
        # Reset before the snapshot, or `visible` is still true and the ring
        # stays on screen over the thing it just launched.
        self._reset()
        return self._snapshot(Outcome.EXECUTED, item)

    def dismiss(self) -> Result:
        self._reset()
        return self._snapshot(Outcome.DISMISSED)

    def _begin(self, event: Event) -> Result:
        if event.finger_count != FINGERS:
            # Not ours. Report the state unchanged so a latched menu already on
            # screen survives a three-finger swipe meant for sway.
            return self._snapshot(Outcome.IDLE)
        self._reset()
        self._stack = [self._root]
        self._active = True
        self._highlighted = self._default_highlight()
        return self._snapshot(Outcome.OPENED)

    def _update(self, event: Event) -> Result:
        if not self._active:
            return self._snapshot(Outcome.IDLE)

        if event.scale < ARM_SCALE:
            self._armed = True

        # The cursor integrates every update whether armed or not, so movement
        # made while the pinch was still closing is not thrown away. Unarmed it
        # moves the highlight and nothing else: _dwell_target refuses to name a
        # target until the pinch has armed, so a resting four-finger hand cannot
        # launch anything by sitting still on the sector that happens to be lit.
        self._cursor[0] += event.dx
        self._cursor[1] += event.dy

        dx, dy = self._cursor
        # R_RING rather than the dead zone R_DEAD. They carry the same number
        # today and mean different things, so ask the one this rule is about.
        if radius(dx, dy) > R_RING:
            self._left_ring = True
            direction = direction_at(dx, dy)
            if direction is not None:
                self._highlighted = direction
        elif self._left_ring:
            # Coming back to the middle after having been out is a deliberate
            # move, and it is the exit. Nothing is lit, and the hub says so.
            self._highlighted = None
        # Otherwise the highlight is sticky and simply stays where it was. The
        # angle at a radius of three pixels is noise, so trusting it near the
        # origin would make the selection flicker between sectors while the hand
        # is barely moving, which is the failure that made this the one rule
        # worth spelling out.
        return self._snapshot(Outcome.UPDATED)

    def _end(self, event: Event) -> Result:
        if not self._active:
            return self._snapshot(Outcome.IDLE)
        self._active = False

        # An unarmed gesture never chose anything, so releasing it is a pinch
        # that happened to be four fingers wide, whatever the closing scale.
        if event.cancelled or not self._armed:
            return self.dismiss()

        if event.scale >= COMMIT_SCALE:
            # The same gate the dwell uses. A ring opens with a sector already
            # lit, so without this a pinch that armed and spread without ever
            # going anywhere would launch whatever happened to be lit, and the
            # rule that a gesture which chose nothing runs nothing would hold
            # for holding still but not for spreading.
            direction = self._highlighted if self._left_ring else None
            item = self._stack[-1].items.get(direction) if direction is not None else None
            if item is None:
                # Spreading with nothing under the finger says "none of these".
                return self.dismiss()
            if item.is_submenu:
                # Spreading on a submenu drills in and latches. The spread has
                # already said yes to this one, so dismissing here would throw
                # away a deliberate commit and read as a broken gesture. Esc and
                # button 8 back out of it.
                self._push_level(item)
                self._latched = True
                return self._snapshot(Outcome.LATCHED)
            result = self._snapshot(Outcome.EXECUTED, item=item)
            self._reset()
            return result

        # Released without spreading: the ring stays on screen for the mouse,
        # with the highlight the fingers left behind.
        self._latched = True
        return self._snapshot(Outcome.LATCHED)

    def _push_level(self, item: MenuItem) -> None:
        self._stack.append(submenu(item))
        self._path.append(item.label)
        self._recenter()

    def _pop_level(self) -> None:
        if len(self._stack) > 1:
            self._stack.pop()
            self._path.pop()
        self._recenter()

    def _default_highlight(self) -> Direction | None:
        """The sector that is lit before the fingers have chosen one.

        One is always lit, which is why there is no cursor dot: the highlight is
        the cursor. Compass order, first populated slot, and never Back, because
        opening a menu already pointing at the way out of it would be a strange
        thing to do.
        """
        if not self._stack:
            return None
        menu = self._stack[-1]
        for direction in DIRECTIONS:
            if direction != menu.back and direction in menu.items:
                return direction
        return None

    def _dwell_target(self) -> str | None:
        """What holding still would act on, or None while nothing would.

        Nothing counts down until the fingers have been out past R_RING at least
        once in this ring. That one gate does two jobs. A ring opens with a
        sector already lit, so without it the menu would begin counting down on
        that sector the instant it appeared and you could never simply look at
        it. And the exit lives in the middle, where every gesture starts, so
        without it every open would also be a countdown to closing itself.
        """
        if not self._active or not self._armed or not self._stack:
            return None
        if not self._left_ring:
            return None
        if self._highlighted is not None:
            return self._highlighted
        # The way out, and the only exit that needs no item and works at any
        # depth. The radius is asked rather than assumed: a ring with no items
        # at all lights nothing, and that must not read as the exit from afar.
        if radius(*self._cursor) <= R_RING:
            return CLOSE
        return None

    def _recenter(self) -> None:
        # Both directions recenter, which is what makes depth cheap: each level
        # costs one ring radius of travel rather than a cumulative one.
        self._cursor = [0.0, 0.0]
        self._highlighted = self._default_highlight()
        # A fresh ring has not been left yet, so the close dwell has to be
        # earned again. Otherwise drilling in would land the fingers in the dead
        # zone of the new ring already eligible to close the menu.
        self._left_ring = False

    def _reset(self) -> None:
        self._stack = []
        self._path = []
        self._cursor = [0.0, 0.0]
        self._active = False
        self._armed = False
        self._latched = False
        self._highlighted = None
        self._left_ring = False

    def _snapshot(self, outcome: Outcome, item: MenuItem | None = None) -> Result:
        return Result(
            outcome=outcome,
            visible=self._active or self._latched,
            breadcrumb=tuple(self._path),
            menu=self._stack[-1] if self._stack else None,
            highlighted=self._highlighted,
            item=item,
            cursor=(self._cursor[0], self._cursor[1]),
            dwell_target=self._dwell_target(),
        )
