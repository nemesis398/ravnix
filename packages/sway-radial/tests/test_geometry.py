import math

import pytest

from sway_radial.geometry import (
    R_DEAD, angle_of, direction_at, radius, sector_bounds,
)
from sway_radial.model import DIRECTIONS


def test_dead_zone_selects_nothing():
    assert direction_at(0.0, 0.0) is None
    assert direction_at(0.0, -39.9) is None
    assert direction_at(20.0, 20.0) is None      # r ~ 28, inside 40


def test_north_is_negative_y():
    # +y is DOWN on screen, so the sector you reach by moving UP is "n".
    assert direction_at(0.0, -100.0) == "n"
    assert direction_at(0.0, 100.0) == "s"
    assert direction_at(100.0, 0.0) == "e"
    assert direction_at(-100.0, 0.0) == "w"


def test_diagonals():
    assert direction_at(100.0, -100.0) == "ne"
    assert direction_at(100.0, 100.0) == "se"
    assert direction_at(-100.0, 100.0) == "sw"
    assert direction_at(-100.0, -100.0) == "nw"


def test_every_direction_is_reachable_and_unique():
    seen = {direction_at(math.sin(angle_of(d)) * 100, -math.cos(angle_of(d)) * 100)
            for d in DIRECTIONS}
    assert seen == set(DIRECTIONS)


def test_sector_is_45_degrees_wide():
    for d in DIRECTIONS:
        start, end = sector_bounds(d)
        assert math.isclose((end - start) % (2 * math.pi), math.pi / 4, abs_tol=1e-9)


def test_boundary_between_n_and_ne_is_stable():
    # Just inside the north half of the n/ne boundary stays "n".
    a = angle_of("n") + math.pi / 8 - 0.001
    assert direction_at(math.sin(a) * 100, -math.cos(a) * 100) == "n"
    a = angle_of("n") + math.pi / 8 + 0.001
    assert direction_at(math.sin(a) * 100, -math.cos(a) * 100) == "ne"


def test_no_outer_bound_past_the_drawn_ring():
    assert direction_at(0.0, -5000.0) == "n"


def test_radius():
    assert radius(3.0, 4.0) == pytest.approx(5.0)


def test_dead_zone_boundary_is_exclusive():
    assert direction_at(0.0, -R_DEAD) is None          # exactly on the edge: nothing
    assert direction_at(0.0, -(R_DEAD + 0.001)) == "n"
