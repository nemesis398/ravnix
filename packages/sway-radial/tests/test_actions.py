from sway_radial.actions import desktop_exists, run_item
from sway_radial.model import MenuItem

def test_desktop_item_uses_gtk_launch(monkeypatch):
    calls = []
    monkeypatch.setattr("sway_radial.actions._spawn", lambda argv: calls.append(argv))
    run_item(MenuItem(direction="n", label="Browser", desktop="helium.desktop"))
    assert calls == [["gtk-launch", "helium.desktop"]]

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
