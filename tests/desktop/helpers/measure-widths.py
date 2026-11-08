#!/usr/bin/env python3
"""How wide each bar module is, laid out by GTK with the bar's own stylesheet.

    measure-widths.py STYLE.CSS < cases.json > widths.json

Run it in a Wayland session (any compositor, a headless one will do) and with
the font of the system in fontconfig. cases.json is a list of
{"id": "custom-clock", "texts": ["narrow", "widest"], "classes": []}: each text
is set in a module of that id, the way Waybar builds one (a label named after
the module, with the module's classes: ALabel.cpp), and the output maps the id to
{"widths": [...], "natural": [...]}: the width of the module for each text with
the stylesheet as it is, and with its min-width taken out, which is how wide
the text itself is. The key "errors" lists what GTK refused to parse in the
stylesheet, and is empty for a good one. A module has a fixed width when all of its widths are
equal; a floor is no wider than it needs to be when its width is at most one
character cell wider than the widest natural one.
"""
import json
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk  # noqa: E402



def width(module_id, text, classes, extra_css=None):
    label = Gtk.Label(label=text)
    label.set_name(module_id)
    for name in classes:
        label.get_style_context().add_class(name)
    window = Gtk.OffscreenWindow()
    window.add(label)
    provider = None
    if extra_css is not None:
        provider = Gtk.CssProvider()
        provider.load_from_data(extra_css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER + 1
        )
    window.show_all()
    minimum, _natural = label.get_preferred_width()
    if provider is not None:
        Gtk.StyleContext.remove_provider_for_screen(Gdk.Screen.get_default(), provider)
    window.destroy()
    return minimum


def main():
    errors = []
    stylesheet = Gtk.CssProvider()
    stylesheet.connect(
        "parsing-error",
        lambda _provider, section, error: errors.append(
            "line %d: %s" % (section.get_start_line() + 1, error.message)
        ),
    )
    stylesheet.load_from_path(sys.argv[1])
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), stylesheet, Gtk.STYLE_PROVIDER_PRIORITY_USER
    )
    out = {"errors": errors}
    for case in json.load(sys.stdin):
        classes = case.get("classes", [])
        out[case["id"]] = {
            "widths": [width(case["id"], t, classes) for t in case["texts"]],
            "natural": [
                # The id selector of the module outranks `*`, so the floor is
                # taken out with the module's own selector.
                width(case["id"], t, classes, ("#%s { min-width: 0; }" % case["id"]).encode())
                for t in case["texts"]
            ],
        }
    json.dump(out, sys.stdout, indent=1, sort_keys=True)
    print()


main()
