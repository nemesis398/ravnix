import os
import stat
import time

import pytest

from sway_radial.actions import desktop_exists, run_item
from sway_radial.model import MenuItem

def test_desktop_item_goes_through_sway_with_gtk_launch(monkeypatch):
    """Sway starts the app, so it is not a child of the service: it outlives a
    restart of the unit and gets the session's environment, not the program's."""
    calls = []
    monkeypatch.delenv("SWAY_RADIAL_GTK_LAUNCH", raising=False)
    monkeypatch.setattr("sway_radial.actions._spawn", lambda argv: calls.append(argv))
    run_item(MenuItem(direction="n", label="Browser", desktop="helium.desktop"))
    assert calls == [["swaymsg", "exec", "--", "gtk-launch helium.desktop"]]

def test_the_launcher_may_be_named_by_the_wrapper(monkeypatch):
    calls = []
    monkeypatch.setenv("SWAY_RADIAL_GTK_LAUNCH", "/nix/store/abc-gtk3-3.24/bin/gtk-launch")
    monkeypatch.setattr("sway_radial.actions._spawn", lambda argv: calls.append(argv))
    run_item(MenuItem(direction="n", label="Browser", desktop="helium"))
    assert calls == [["swaymsg", "exec", "--", "/nix/store/abc-gtk3-3.24/bin/gtk-launch helium"]]

@pytest.mark.parametrize("bad", ["x; reboot", "a b", "$(id)", "`id`", "a|b", "'q'", '"q"',
                                 "-h", "", "a\nb", "a,b", "{x}"])
def test_a_desktop_id_that_is_not_one_is_refused(monkeypatch, caplog, bad):
    """The id reaches a shell through Sway's exec, and Sway splits a command
    line at ; and ,. A real id has neither, so nothing is run for one."""
    calls = []
    monkeypatch.setattr("sway_radial.actions._spawn", lambda argv: calls.append(argv))
    run_item(MenuItem(direction="n", label="Odd", desktop=bad))
    assert calls == []
    assert "desktop id" in caplog.text

@pytest.mark.parametrize("good", ["helium", "md.obsidian.Obsidian", "webapp-claude",
                                  "onlyoffice-desktopeditors.desktop", "a_b", "x+y"])
def test_ordinary_desktop_ids_are_launched(monkeypatch, good):
    calls = []
    monkeypatch.delenv("SWAY_RADIAL_GTK_LAUNCH", raising=False)
    monkeypatch.setattr("sway_radial.actions._spawn", lambda argv: calls.append(argv))
    run_item(MenuItem(direction="n", label="Ok", desktop=good))
    assert calls == [["swaymsg", "exec", "--", f"gtk-launch {good}"]]

def test_no_item_is_started_by_the_program_itself(monkeypatch):
    """Every leaf, of either kind, is handed to swaymsg and to nothing else."""
    calls = []
    monkeypatch.setattr("sway_radial.actions._spawn", lambda argv: calls.append(argv))
    run_item(MenuItem(direction="n", label="A", desktop="helium"))
    run_item(MenuItem(direction="e", label="B", command="sway-clipboard"))
    assert [argv[0] for argv in calls] == ["swaymsg", "swaymsg"]

def _fake(path, body):
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)

def test_a_desktop_item_reaches_a_swaymsg_on_the_path_and_nothing_else(tmp_path, monkeypatch):
    """The real spawn against a fake swaymsg and a fake gtk-launch: the first
    is called with the exec command, the second never runs, because starting it
    is Sway's job."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    seen = tmp_path / "swaymsg.argv"
    ran = tmp_path / "gtk-launch.ran"
    _fake(bin_dir / "swaymsg", f'for a in "$@"; do printf "%s\\n" "$a"; done > {seen}\n')
    _fake(bin_dir / "gtk-launch", f"echo ran > {ran}\n")
    monkeypatch.setenv("PATH", str(bin_dir))
    monkeypatch.delenv("SWAY_RADIAL_GTK_LAUNCH", raising=False)
    run_item(MenuItem(direction="n", label="Browser", desktop="helium"))
    deadline = time.monotonic() + 10
    while not seen.exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    time.sleep(0.2)
    assert seen.read_text().split("\n")[:-1] == ["exec", "--", "gtk-launch helium"]
    assert not ran.exists(), "the program ran gtk-launch itself"

def test_command_item_goes_through_swaymsg(monkeypatch):
    calls = []
    monkeypatch.setattr("sway_radial.actions._spawn", lambda argv: calls.append(argv))
    run_item(MenuItem(direction="e", label="Clip", command="sway-clipboard"))
    assert calls == [["swaymsg", "exec", "--", "sway-clipboard"]]

def test_submenu_is_never_run(monkeypatch):
    calls = []
    monkeypatch.setattr("sway_radial.actions._spawn", lambda argv: calls.append(argv))
    child = MenuItem(direction="n", label="X", command="true")
    run_item(MenuItem(direction="n", label="Apps", children=(child,)))
    assert calls == []

def test_spawn_failure_is_swallowed(monkeypatch, caplog):
    def boom(argv): raise OSError("nope")
    monkeypatch.setattr("sway_radial.actions._spawn", boom)
    run_item(MenuItem(direction="n", label="Browser", desktop="helium.desktop"))
    assert "nope" in caplog.text

def test_desktop_exists_accepts_both_forms(tmp_path, monkeypatch):
    apps = tmp_path / "applications"
    apps.mkdir()
    (apps / "helium.desktop").write_text("[Desktop Entry]\nName=Helium\n")
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    monkeypatch.setenv("XDG_DATA_DIRS", str(tmp_path))
    assert desktop_exists("helium")
    assert desktop_exists("helium.desktop")
    assert not desktop_exists("nothing-here")
