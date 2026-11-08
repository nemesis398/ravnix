"""The shared vocabulary.

Deliberately free of logic. Every other module imports these names, so they are
written and committed on their own: four modules were built in parallel against
this file, and a type that drifts mid-flight is a merge conflict that presents
as an AttributeError three tasks later.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Literal

Direction = Literal["n", "ne", "e", "se", "s", "sw", "w", "nw"]

#: Clockwise from north. The order is load-bearing: geometry indexes into it.
DIRECTIONS: tuple[Direction, ...] = ("n", "ne", "e", "se", "s", "sw", "w", "nw")

@dataclass(frozen=True, slots=True)
class MenuItem:
    """One sector of one ring.

    A leaf carries exactly one of ``desktop`` or ``command``. A submenu carries
    neither and has children instead.

    ``command`` rather than ``exec``, because ``exec`` reads badly as an
    attribute. The TOML key stays ``exec``; the loader maps it.
    """

    direction: Direction
    label: str
    icon: str | None = None
    desktop: str | None = None
    command: str | None = None
    children: tuple[MenuItem, ...] = ()

    @property
    def is_submenu(self) -> bool:
        return bool(self.children)


#: Where Back sits in every submenu. Fixed rather than opposite the direction
#: the ring was entered through: a Back that moves has to be found before it can
#: be used, and finding it is the one thing you are not doing when you want out.
#: Set on 2026-09-05. The top ring has no parent and reserves nothing.
BACK_DIRECTION: Direction = "s"

#: How long the fingers have to hold still on a sector before it acts, in
#: milliseconds. Walked up on 2026-09-05 while using it: 350 was short
#: enough that moving deliberately from one sector to the next could still open
#: something on the way past, 750 was not quite enough room, and a round second
#: is where it settled.
DEFAULT_DWELL_MS = 1000

#: The dwell target that means "close without running anything". Not a
#: Direction, because it is not a sector: it is the dead zone in the middle,
#: which is the one place on the ring that never carries an item.
CLOSE = "close"


@dataclass(frozen=True, slots=True)
class Settings:
    """Everything in menu.toml that is not an item."""

    dwell_ms: int = DEFAULT_DWELL_MS


@dataclass(frozen=True, slots=True)
class Menu:
    """One ring.

    ``back`` is ``None`` for the top ring, which therefore has all eight slots.
    Every ring below it reserves one direction and has seven.
    """

    label: str
    items: Mapping[Direction, MenuItem] = field(default_factory=dict)
    back: Direction | None = None
