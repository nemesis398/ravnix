"""Angle and radius math for one ring.

**Screen coordinates, not textbook ones: ``+x`` is right and ``+y`` is DOWN, so
north is ``dy < 0``.** That is the single thing a reader gets wrong here, and it
is why every angle goes through ``math.atan2(dx, -dy)`` instead of the usual
``atan2(dy, dx)``. Negating ``dy`` puts 0 at north, and swapping the arguments
makes the angle grow clockwise, which is the order ``DIRECTIONS`` is written in.
So the sector index is a plain division and never a table lookup that has to be
kept in step by hand.

All distances are logical pixels, measured from the origin of the ring that is
currently open, never from the screen corner.
"""

from __future__ import annotations

import math

from .model import DIRECTIONS, Direction

#: Inside this the gesture has not chosen anything yet, so a resting hand and a
#: tremor both select nothing.
R_DEAD: float = 40.0

#: Past this a sector highlights, and Back pops a level.
R_RING: float = 40.0

#: How far the graphic reaches. Behavior has no outer bound at all: the finger
#: may leave the drawing and the selection has to survive it.
R_DRAW: float = 200.0

_SECTOR = math.tau / len(DIRECTIONS)
_HALF_SECTOR = _SECTOR / 2


def radius(dx: float, dy: float) -> float:
    """Euclidean distance from the origin."""
    return math.hypot(dx, dy)


def direction_at(dx: float, dy: float) -> Direction | None:
    """The sector the vector points into, or None inside the dead zone.

    +x is right, +y is DOWN, so north is dy < 0. The dead zone edge belongs to
    the dead zone: exactly R_DEAD still selects nothing, so a highlight cannot
    flicker on a value sitting right on the boundary.
    """
    if radius(dx, dy) <= R_DEAD:
        return None
    angle = math.atan2(dx, -dy) % math.tau
    # A sector is centered on its angle rather than starting at it, so shift by
    # half a sector before dividing. The modulo catches north, whose sector
    # straddles the wrap point.
    return DIRECTIONS[int((angle + _HALF_SECTOR) // _SECTOR) % len(DIRECTIONS)]


def angle_of(direction: Direction) -> float:
    """Center angle of a sector, radians, 0 = north, growing clockwise."""
    return DIRECTIONS.index(direction) * _SECTOR


def sector_bounds(direction: Direction) -> tuple[float, float]:
    """(start, end) angle of a sector in the same convention, each 45 degrees
    wide and centered on angle_of.

    ``start`` is always the smaller number, so north comes back as
    ``(-pi/8, +pi/8)`` rather than wrapping through 2pi. A caller can therefore
    take the width or the midpoint without special-casing the one sector that
    straddles the wrap point, and Cairo's ``arc`` accepts a negative start.
    """
    center = angle_of(direction)
    return center - _HALF_SECTOR, center + _HALF_SECTOR
