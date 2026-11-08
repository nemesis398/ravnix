import pytest
from sway_radial.config import parse_menu, submenu
from sway_radial.gesture import Event, GestureMachine, Outcome
from sway_radial.geometry import R_RING
import tomllib, textwrap

TREE = """
[[items]]
dir = "n"
label = "Apps"
  [[items.items]]
  dir = "n"
  label = "Browser"
  desktop = "helium.desktop"
  [[items.items]]
  dir = "nw"
  label = "More"
    [[items.items.items]]
    dir = "n"
    label = "Editor"
    desktop = "nvim.desktop"
[[items]]
dir = "e"
label = "Clipboard"
exec = "sway-clipboard"
"""

@pytest.fixture
def machine():
    return GestureMachine(parse_menu(tomllib.loads(textwrap.dedent(TREE)), source="t"))

def begin(fingers=4):   return Event(kind="begin", finger_count=fingers)
def arm():              return Event(kind="update", scale=0.8)
def move(dx, dy, scale=0.8): return Event(kind="update", scale=scale, dx=dx, dy=dy)
def end(scale=1.0, cancelled=False):
    return Event(kind="end", scale=scale, cancelled=cancelled)

def test_three_fingers_is_ignored(machine):
    r = machine.handle(begin(3))
    assert r.outcome is Outcome.IDLE and not r.visible

def test_five_fingers_is_ignored(machine):
    assert machine.handle(begin(5)).outcome is Outcome.IDLE

def test_begin_opens_at_the_top_ring(machine):
    r = machine.handle(begin())
    assert r.outcome is Outcome.OPENED
    assert r.visible and r.breadcrumb == () and r.cursor == (0.0, 0.0)
    assert r.menu.back is None
    # One sector is lit from the first frame. There is no cursor dot any more,
    # so an unlit ring would be a ring with no feedback in it at all.
    assert r.highlighted == "n"
    assert r.dwell_target is None                # lit, but nothing counting yet

def test_update_without_begin_is_ignored(machine):
    assert machine.handle(move(0, -100)).outcome is Outcome.IDLE

def test_moving_before_arming_moves_the_highlight_but_arms_nothing(machine):
    """The highlight follows unarmed; the dwell does not.

    Before 2026-09-05 the unarmed gesture highlighted nothing, which was the
    whole protection against a resting four-finger hand launching something.
    Now that a sector is always lit, that protection has to live somewhere else,
    and it lives in dwell_target refusing to name one until the pinch has armed.
    """
    machine.handle(begin())
    r = machine.handle(Event(kind="update", scale=0.99, dx=0, dy=-100))
    assert r.highlighted == "n"
    assert r.dwell_target is None
    assert machine.dwell().outcome is Outcome.IDLE
    assert r.cursor == (0.0, -100.0)

def test_arming_then_moving_highlights(machine):
    machine.handle(begin()); machine.handle(arm())
    assert machine.handle(move(0, -100)).highlighted == "n"

def test_armed_state_is_sticky(machine):
    machine.handle(begin()); machine.handle(arm())
    r = machine.handle(move(0, -100, scale=0.95))   # scale went back up
    assert r.highlighted == "n"

def test_dead_zone_clears_the_highlight(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(0, -100))
    assert machine.handle(move(0, 100)).highlighted is None   # back to origin

def test_a_dwell_drills_into_a_submenu_and_recentres(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(0, -100))
    r = machine.dwell()
    assert r.breadcrumb == ("Apps",)
    assert r.cursor == (0.0, 0.0)
    assert r.menu.back == "s"
    assert r.highlighted == "n"               # the new ring lights its own first slot
    assert r.dwell_target is None             # and counts nothing until you move

def test_distance_alone_never_drills_in(machine):
    """The regression. Reaching past a radius used to open whatever sector the
    fingers were crossing, so the ring changed under the hand mid-movement."""
    machine.handle(begin()); machine.handle(arm())
    r = machine.handle(move(0, -400))
    assert r.breadcrumb == () and r.highlighted == "n"

def test_a_dwell_on_a_leaf_runs_it(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(100, 0))
    r = machine.dwell()
    assert r.outcome is Outcome.EXECUTED
    assert r.item.label == "Clipboard"
    assert not r.visible                      # the ring goes with it

def test_a_dwell_on_nothing_does_nothing(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(0, -10))              # inside the ring, nothing highlighted
    assert machine.dwell().outcome is Outcome.IDLE

def test_a_dwell_before_the_gesture_starts_is_ignored(machine):
    assert machine.dwell().outcome is Outcome.IDLE

def test_back_pops_on_a_dwell_and_not_on_contact(machine):
    """Back used to answer the moment you pointed at it.

    That was a discount while a cursor dot showed where you were and only a
    reach past the ring selected anything. With one sector always lit it turns
    into a hazard: crossing south on the way anywhere else would throw away a
    level under the hand. Moved onto the dwell on 2026-09-05.
    """
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(0, -100)); machine.dwell()     # into Apps
    r = machine.handle(move(0, 100 + R_RING + 5))      # south = Back
    assert r.breadcrumb == ("Apps",)                   # still there
    assert r.highlighted == "s" and r.dwell_target == "s"
    r = machine.dwell()
    assert r.breadcrumb == () and r.cursor == (0.0, 0.0)

def test_three_levels_each_cost_one_ring(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(0, -100)); machine.dwell()               # Apps
    machine.handle(move(-70, -70))
    r = machine.dwell()                                          # Apps > More
    assert r.breadcrumb == ("Apps", "More")
    assert r.menu.back == "s"  # every ring, at every depth

def test_end_spread_on_a_leaf_executes(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(R_RING + 10, 0))
    r = machine.handle(end(scale=1.1))
    assert r.outcome is Outcome.EXECUTED
    assert r.item.label == "Clipboard" and not r.visible

def test_end_spread_on_a_submenu_drills_in_and_latches(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(0, -(R_RING + 10)))
    r = machine.handle(end(scale=1.1))
    assert r.outcome is Outcome.LATCHED
    assert r.breadcrumb == ("Apps",) and r.visible

def test_end_without_spreading_latches(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(R_RING + 10, 0))
    r = machine.handle(end(scale=0.8))
    assert r.outcome is Outcome.LATCHED and r.visible
    assert r.highlighted == "e" and r.item is None

def test_end_with_nothing_highlighted_dismisses(machine):
    machine.handle(begin()); machine.handle(arm())
    r = machine.handle(end(scale=1.1))
    assert r.outcome is Outcome.DISMISSED and not r.visible

def test_cancelled_end_dismisses_even_when_highlighted(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(R_RING + 10, 0))
    r = machine.handle(end(scale=1.1, cancelled=True))
    assert r.outcome is Outcome.DISMISSED and r.item is None

def test_end_without_arming_dismisses(machine):
    machine.handle(begin())
    machine.handle(Event(kind="update", scale=0.99, dx=100, dy=0))
    r = machine.handle(end(scale=1.2))
    assert r.outcome is Outcome.DISMISSED

def test_return_to_dead_zone_and_spread_is_a_cancel(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(0, -100))
    machine.handle(move(0, 100))
    assert machine.handle(end(scale=1.2)).outcome is Outcome.DISMISSED

def test_pop_from_latched_state(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(0, -100)); machine.dwell()
    machine.handle(end(scale=0.8))
    r = machine.pop()
    assert r.breadcrumb == () and r.visible

def test_pop_at_the_top_dismisses(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(end(scale=0.8))
    assert machine.pop().outcome is Outcome.DISMISSED

def test_a_second_begin_resets_a_latched_menu(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(0, -100)); machine.dwell()
    machine.handle(end(scale=0.8))
    r = machine.handle(begin())
    assert r.breadcrumb == () and r.outcome is Outcome.OPENED

def test_set_root_is_ignored_mid_gesture(machine):
    machine.handle(begin()); machine.handle(arm())
    other = parse_menu(tomllib.loads('[[items]]\ndir="s"\nlabel="X"\nexec="true"\n'), source="t")
    machine.set_root(other)
    assert machine.handle(move(R_RING + 10, 0)).highlighted == "e"   # old tree still live

def test_submenu_reserves_back_and_hides_nothing_else(machine):
    m = machine.handle(begin()).menu
    sub = submenu(m.items["n"])
    assert sub.back == "s"
    assert "s" not in sub.items
    assert set(sub.items) == {"n", "nw"}


# ── latched mode, driven by the pointer rather than the fingers ──────────────
# select() is the counterpart to pop(). Without it the daemon has to keep its own
# mirror of the ring stack in order to drill in with the mouse, and two stacks
# that must agree are two stacks that can disagree.


def latched(machine):
    """Open the menu and let go without spreading, which latches it."""
    machine.handle(begin())
    machine.handle(arm())
    machine.handle(end(scale=0.8))
    return machine


def test_select_pushes_a_submenu(machine):
    r = latched(machine).select("n")
    assert r.outcome is Outcome.UPDATED
    assert r.breadcrumb == ("Apps",)
    assert r.menu.back == "s"
    assert r.cursor == (0.0, 0.0)
    assert r.highlighted == "n"
    assert r.visible


def test_select_executes_a_leaf_and_closes(machine):
    r = latched(machine).select("e")
    assert r.outcome is Outcome.EXECUTED
    assert r.item.label == "Clipboard"
    assert not r.visible


def test_select_on_the_back_sector_pops(machine):
    m = latched(machine)
    m.select("n")
    r = m.select("s")
    assert r.outcome is Outcome.UPDATED
    assert r.breadcrumb == ()


def test_select_on_an_empty_sector_changes_nothing(machine):
    m = latched(machine)
    m.select("n")
    r = m.select("e")           # Apps has no item at "e"
    assert r.outcome is Outcome.IDLE
    assert r.breadcrumb == ("Apps",)
    assert r.visible


def test_select_while_hidden_is_idle(machine):
    r = machine.select("n")
    assert r.outcome is Outcome.IDLE
    assert not r.visible


def test_select_nests_as_deep_as_the_fingers_do(machine):
    m = latched(machine)
    m.select("n")
    r = m.select("nw")
    assert r.breadcrumb == ("Apps", "More")
    assert r.menu.back == "s"  # every ring, at every depth

# -- leaving without choosing ------------------------------------------------
#
# A way out of the menu that selects nothing was added on 2026-09-05. Back
# only climbs one level, and at the top ring there is nothing above it, so the
# exit had to be a second thing and not a deeper Back.

def test_the_hub_is_not_a_dwell_target_before_the_fingers_have_left_the_ring(machine):
    """Opening the menu and pausing to read it must never dismiss it.

    This is the test that stops the feature from being worse than nothing. The
    gesture starts in the dead zone by definition, so an ungated close would
    arm on the very first frame of every single open.
    """
    machine.handle(begin())
    r = machine.handle(arm())
    assert r.dwell_target is None
    assert machine.dwell().outcome is Outcome.IDLE
    assert machine.handle(move(0, -10)).dwell_target is None   # still inside

def test_returning_to_the_hub_after_reaching_the_ring_arms_the_exit(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(0, -(R_RING + 10)))                    # out to a sector
    r = machine.handle(move(0, R_RING + 10))                   # and back in
    assert r.cursor == (0.0, 0.0)                              # deltas, not a position
    assert r.dwell_target == "close"
    assert r.highlighted is None

def test_dwelling_on_the_hub_closes_without_running_anything(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(0, -(R_RING + 10)))
    machine.handle(move(0, R_RING + 10))
    r = machine.dwell()
    assert not r.visible
    assert r.outcome is Outcome.DISMISSED
    assert r.item is None

def test_a_sector_still_wins_over_the_exit(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(0, -(R_RING + 10)))
    r = machine.handle(move(0, -(R_RING + 20)))
    assert r.dwell_target == "n"

def test_drilling_in_disarms_the_exit_again(machine):
    """A push recenters, so the fingers are in the new ring's dead zone.

    Without clearing the flag they would arrive already eligible to close, and
    entering a submenu would be one held breath away from dismissing the menu.
    """
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(0, -(R_RING + 10)))
    r = machine.dwell()                                        # into Apps
    assert r.breadcrumb == ("Apps",)
    assert r.dwell_target is None
    assert machine.dwell().outcome is Outcome.IDLE

def test_back_is_a_dwell_target_like_every_other_sector(machine):
    machine.handle(begin()); machine.handle(arm())
    machine.handle(move(0, -(R_RING + 10)))
    machine.dwell()                                    # into Apps
    r = machine.handle(move(0, R_RING + 10))           # point south at Back
    assert r.highlighted == "s" and r.dwell_target == "s"

# -- one sector is always lit ------------------------------------------------
#
# Added on 2026-09-05, together with removing the cursor dot: the
# highlight IS the cursor now, so a state with nothing lit is a state with no
# feedback in it.

def test_the_highlight_never_goes_dark_while_choosing(machine):
    machine.handle(begin())
    seen = [machine.handle(arm()).highlighted]
    for dx, dy in [(0, -100), (90, -90), (100, 0), (0, 100), (-100, 0), (0, -100)]:
        seen.append(machine.handle(Event(kind="update", scale=0.8, dx=dx, dy=dy)).highlighted)
    assert None not in seen, seen

def test_a_wobble_near_the_origin_does_not_flip_the_selection(machine):
    """Why the highlight is sticky inside R_RING rather than pure angle.

    The angle at a radius of three pixels is noise. Reading it there would make
    the selection jitter between sectors while the hand is barely moving, and
    with no cursor dot left there is nothing else on screen to explain why.
    """
    machine.handle(begin()); machine.handle(arm())
    for dx, dy in [(3, -2), (-5, 4), (2, 5), (-1, -6), (4, 1)]:
        r = machine.handle(Event(kind="update", scale=0.8, dx=dx, dy=dy))
        assert r.highlighted == "n", (dx, dy, r.cursor)

def test_the_default_skips_back_and_takes_the_first_populated_slot():
    """Compass order, and never Back.

    Opening a ring already pointing at the way out of it would be strange, and
    lighting an empty slot would be worse: the dwell would count down on it and
    then do nothing, which reads exactly like the menu having stopped.
    """
    tree = textwrap.dedent("""
    [[items]]
    dir = "n"
    label = "Only"
      [[items.items]]
      dir = "e"
      label = "East"
      exec = "true"
      [[items.items]]
      dir = "w"
      label = "West"
      exec = "true"
    """)
    m = GestureMachine(parse_menu(tomllib.loads(tree), source="t"))
    m.handle(begin()); m.handle(arm())
    m.handle(move(0, -(R_RING + 10)))
    r = m.dwell()
    assert r.menu.back == "s"
    assert r.highlighted == "e"       # not "s", and not the absent "n"

def test_the_lit_sector_is_not_armed_until_the_fingers_go_somewhere(machine):
    """Opening the menu must not start a countdown on whatever it lit.

    This is the whole reason dwell_target has a gate of its own rather than just
    reading the highlight. Without it the ring would appear with Apps lit and
    open Apps a second later, and you could never simply look at the menu.
    """
    machine.handle(begin())
    r = machine.handle(arm())
    assert r.highlighted == "n" and r.dwell_target is None
    assert machine.dwell().outcome is Outcome.IDLE
    r = machine.handle(move(0, -(R_RING + 10)))
    assert r.dwell_target == "n"      # now it counts

def test_spreading_without_going_anywhere_still_runs_nothing(machine):
    machine.handle(begin()); machine.handle(arm())
    r = machine.handle(end(scale=1.1))
    assert r.outcome is Outcome.DISMISSED and r.item is None


# ── opened by the mouse: the MX Master's gesture button, 2026-10-06 ──────────
# A button press has no direction to move, so the menu opens straight into the
# latched mode the fingers reach by letting go, and the pointer drives it.


def test_open_latched_shows_the_top_ring_latched(machine):
    r = machine.open_latched()
    assert r.outcome is Outcome.OPENED
    assert r.visible
    assert r.menu.items.keys() == {"n", "e"}
    assert r.breadcrumb == ()


def test_open_latched_arms_no_dwell(machine):
    """Nothing may count down: the pointer clicks, it never rests to choose."""
    assert machine.open_latched().dwell_target is None


def test_open_latched_then_select_drives_it_like_a_latched_pinch(machine):
    machine.open_latched()
    r = machine.select("n")
    assert r.outcome is Outcome.UPDATED
    assert r.breadcrumb == ("Apps",)
    r = machine.select("n")
    assert r.outcome is Outcome.EXECUTED
    assert r.item.label == "Browser"
    assert not r.visible


def test_open_latched_resets_a_ring_left_open(machine):
    machine.open_latched()
    machine.select("n")
    r = machine.open_latched()
    assert r.breadcrumb == ()


def test_a_pinch_still_takes_over_a_menu_the_mouse_opened(machine):
    machine.open_latched()
    r = machine.handle(begin())
    assert r.outcome is Outcome.OPENED
    assert machine.handle(arm()).visible


def test_hover_moves_the_highlight_in_latched_mode(machine):
    machine.open_latched()
    r = machine.hover("e")
    assert r.highlighted == "e"
    assert r.outcome is Outcome.UPDATED


def test_hover_over_nothing_keeps_the_last_highlight(machine):
    """The hub and empty sectors light nothing new, so the ring never goes dark."""
    machine.open_latched()
    machine.hover("e")
    assert machine.hover(None).highlighted == "e"
    assert machine.hover("sw").highlighted == "e"


def test_hover_while_hidden_or_mid_gesture_is_idle(machine):
    assert machine.hover("e").outcome is Outcome.IDLE
    machine.handle(begin())
    machine.handle(arm())
    assert machine.hover("e").outcome is Outcome.IDLE
