import cairo, math, pytest
from sway_radial.geometry import R_RING, angle_of
from sway_radial.overlay import draw_ring
from sway_radial import theme
from sway_radial.config import parse_menu
import tomllib

W = H = 600
ORIGIN = (300.0, 300.0)

@pytest.fixture
def menu():
    # Deviation from the plan, and the only one: the plan puts the
    # [[items.items]] block after the "Clip" entry, where TOML nests it under
    # Clip. That makes Apps a leaf with no action and Clip a submenu carrying
    # exec, so parse_menu rejects the fixture and all six tests error before
    # they render anything. The rest of the file only reads if Apps is the
    # submenu: test_a_submenu_draws_its_back_sector calls submenu(menu.items["n"]).
    # Only the nesting order moved, no assertion changed.
    return parse_menu(tomllib.loads(
        '[[items]]\ndir="n"\nlabel="Apps"\n'
        '  [[items.items]]\n  dir="n"\n  label="B"\n  exec="b"\n'
        '[[items]]\ndir="e"\nlabel="Clip"\nexec="c"\n'), source="t")

def render(menu, highlighted=None, breadcrumb=()):
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, W, H)
    cr = cairo.Context(surface)
    draw_ring(cr, menu=menu, highlighted=highlighted,
              breadcrumb=breadcrumb, origin=ORIGIN, scale=1.0)
    surface.flush()
    return surface

def pixel(surface, x, y):
    data = surface.get_data()
    stride = surface.get_stride()
    off = int(y) * stride + int(x) * 4
    b, g, r, a = data[off], data[off + 1], data[off + 2], data[off + 3]
    return (r / 255, g / 255, b / 255, a / 255)

def at(direction, r):
    a = angle_of(direction)
    return ORIGIN[0] + math.sin(a) * r, ORIGIN[1] - math.cos(a) * r

def test_nothing_highlighted_draws_no_accent(menu):
    s = render(menu)
    r, g, b, _ = pixel(s, *at("n", 120))
    assert (round(r, 1), round(g, 1), round(b, 1)) != tuple(round(c, 1) for c in theme.ACCENT)

def test_the_highlighted_sector_is_the_accent(menu):
    s = render(menu, highlighted="n")
    r, g, b, a = pixel(s, *at("n", 120))
    assert a > 0.5
    for got, want in zip((r, g, b), theme.ACCENT):
        assert abs(got - want) < 0.06

def test_only_the_highlighted_sector_is_the_accent(menu):
    s = render(menu, highlighted="n")
    r, g, b, _ = pixel(s, *at("s", 120))
    assert abs(r - theme.ACCENT[0]) > 0.1 or abs(g - theme.ACCENT[1]) > 0.1

def test_the_dead_zone_is_not_a_wedge(menu):
    s = render(menu, highlighted="n")
    r, g, b, _ = pixel(s, ORIGIN[0], ORIGIN[1] - R_RING / 2)
    for got, want in zip((r, g, b), theme.ACCENT):
        assert abs(got - want) > 0.05

def test_a_submenu_draws_its_back_sector(menu):
    from sway_radial.config import submenu
    sub = submenu(menu.items["n"])
    s = render(sub, breadcrumb=("Apps",))
    _, _, _, a = pixel(s, *at("s", 120))
    assert a > 0.1                      # Back is drawn, not an empty hole

def test_it_never_paints_outside_the_drawn_radius(menu):
    s = render(menu, highlighted="n")
    assert pixel(s, 5, 5)[3] == pytest.approx(0.0, abs=0.02)


# -- opaque, and no fade (docs/style.md: the sway-radial row) -----------------
#
# The Fedora program drew every wedge at alpha 0.92 and faded the whole ring in
# and out over 80 ms. ravnix has no transparency and no motion, so the ring is
# opaque and appears and disappears at once. The surface around the ring stays
# clear: it is the layer surface that covers the output, with nothing drawn on it.


def test_every_part_of_the_ring_is_fully_opaque(menu):
    s = render(menu, highlighted="n")
    seen = 0
    for direction in ("n", "ne", "e", "se", "s", "sw", "w", "nw"):
        for radius in (60, 120, 180):
            _, _, _, a = pixel(s, *at(direction, radius))
            assert a == pytest.approx(1.0, abs=0.004), (direction, radius, a)
            seen += 1
    assert seen == 24
    _, _, _, hub = pixel(s, ORIGIN[0], ORIGIN[1] - R_RING / 2)
    assert hub == pytest.approx(1.0, abs=0.004)


def test_an_occupied_sector_is_the_wash(menu):
    r, g, b, _ = pixel(render(menu), *at("n", 120))
    assert (r, g, b) == pytest.approx(theme.WASH, abs=0.01)


def test_an_empty_sector_is_the_canvas(menu):
    r, g, b, _ = pixel(render(menu), *at("w", 120))
    assert (r, g, b) == pytest.approx(theme.CANVAS, abs=0.01)


def test_the_lit_sector_is_exactly_the_accent(menu):
    r, g, b, _ = pixel(render(menu, highlighted="e"), *at("e", 120))
    assert (r, g, b) == pytest.approx(theme.ACCENT, abs=0.01)


def test_the_hub_is_the_deepest_role(menu):
    r, g, b, _ = pixel(render(menu), ORIGIN[0], ORIGIN[1] - R_RING / 2)
    assert (r, g, b) == pytest.approx(theme.DEEPEST, abs=0.01)


def test_the_surface_around_the_ring_stays_clear(menu):
    s = render(menu, highlighted="n")
    for x, y in ((5, 5), (W - 5, 5), (5, H - 5), (W - 5, H - 5), (ORIGIN[0] + 230, ORIGIN[1])):
        assert pixel(s, x, y)[3] == 0.0, (x, y)


def test_no_color_of_the_ring_is_translucent_in_the_source():
    """The painter has no alpha constant left to be set below 1."""
    from sway_radial import overlay

    assert not hasattr(overlay, "_ALPHA")
    assert not hasattr(overlay, "_FADE_MS")


def test_the_stylesheet_has_no_opacity_transition_or_animation():
    from sway_radial import overlay

    css = overlay._CSS.lower()
    for word in ("opacity", "transition", "animation", "keyframes"):
        assert word not in css, word


class _Recorder:
    """Stands in for GLib: any timer or idle source it is asked for is recorded."""

    def __init__(self):
        self.calls = []

    def timeout_add(self, *args):
        self.calls.append(("timeout_add", args))
        return 1

    def idle_add(self, *args):
        self.calls.append(("idle_add", args))
        return 1

    def source_remove(self, *args):
        self.calls.append(("source_remove", args))
        return True


class _Window:
    def __init__(self):
        self.visible = True
        self.presented = 0

    def set_visible(self, visible):
        self.visible = visible

    def present(self):
        self.presented += 1
        self.visible = True

    def get_surface(self):
        return None


class _Area:
    def __init__(self):
        self.classes = []
        self.draws = 0

    def add_css_class(self, name):
        self.classes.append(("add", name))

    def remove_css_class(self, name):
        self.classes.append(("remove", name))

    def queue_draw(self):
        self.draws += 1


@pytest.fixture
def overlay_without_a_display(monkeypatch):
    """An Overlay that was never built (that needs a compositor) but has the
    attributes show() and hide() touch, over stand-ins for GTK and GLib."""
    from sway_radial import overlay

    recorder = _Recorder()
    monkeypatch.setattr(overlay, "GLib", recorder)
    ov = overlay.Overlay.__new__(overlay.Overlay)
    ov._window = _Window()
    ov._area = _Area()
    ov._origin = (0.0, 0.0)
    ov._output = None
    ov._hide_source = None  # the fade's timer, in the old Overlay
    latched = []
    monkeypatch.setattr(ov, "set_latched", lambda value: latched.append(value))
    return ov, recorder, latched


def test_hiding_is_immediate_and_starts_no_timer(overlay_without_a_display):
    ov, recorder, latched = overlay_without_a_display
    ov.hide()
    assert ov._window.visible is False, "the window is still there after hide()"
    assert latched == [False]
    assert recorder.calls == [], "hide() scheduled something"
    assert ov._area.classes == [], "hide() played a class change"


def test_showing_is_immediate_and_adds_no_style_class(overlay_without_a_display):
    ov, recorder, _ = overlay_without_a_display
    ov._window.visible = False
    ov.show((10.0, 20.0))
    assert ov._window.visible is True
    assert ov._origin == (10.0, 20.0)
    assert recorder.calls == [], "show() scheduled something"
    assert ov._area.classes == []
    assert ov._area.draws >= 1


def test_showing_after_hiding_leaves_nothing_pending(overlay_without_a_display):
    ov, recorder, _ = overlay_without_a_display
    for _ in range(3):
        ov.show((1.0, 2.0))
        ov.hide()
    ov.show((1.0, 2.0))
    assert ov._window.visible is True
    assert recorder.calls == []
