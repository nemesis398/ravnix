"""The command line: wallpaper, lock-args and render, and what they do with
a bad config, bad arguments, a broken sway and concurrent runs."""

import json
import os
import subprocess
import time

import pytest

from conftest import (
    BACKDROP,
    H,
    KERNEL,
    S,
    STATE_HUES,
    SWATCHES,
    W,
    facts_text,
    load_png,
    palette_box,
    palette_row_offset,
    rgb,
    where,
)


def hands_to_sway(lab):
    """The `output NAME bg PATH fill` commands swaymsg got, as (name, path)."""
    if not lab.log.exists():
        return []
    found = []
    for line in lab.log.read_text().splitlines():
        words = line.split()
        assert words[0] == "output" and words[2] == "bg" and words[-1] == "fill", line
        found.append((words[1], " ".join(words[3:-1])))
    return found


def cached(lab, pattern):
    return sorted((lab.cache / "backdrop").glob(pattern))


def lock_args(lab, **env):
    proc = lab.run("lock-args", **env)
    lines = proc.stdout.splitlines()
    assert len(lines) % 2 == 0 and all(l == "-i" for l in lines[::2]), proc.stdout
    return {l.split(":", 1)[0]: l.split(":", 1)[1] for l in lines[1::2]}, proc


# wallpaper ---------------------------------------------------------------


def test_wallpaper_hands_the_image_to_sway_and_caches_the_lock_image(lab):
    proc = lab.run("wallpaper")
    assert lab.journal(proc) == []
    [(name, path)] = hands_to_sway(lab)
    assert name == "eDP-1"
    img = load_png(path)
    assert img.shape == (H, W, 3)
    assert where(img, rgb("mauve")).sum() > 3000
    [lock] = cached(lab, "lock-*.png")
    assert load_png(lock).shape == (H, W, 3)
    assert cached(lab, "wall-*.png") == [type(lock)(path)]


def test_wallpaper_renders_every_active_output_at_its_own_size(lab):
    lab.set_outputs([("eDP-1", 1920, 1200, 1.0), ("DP-2", 3440, 1440, 1.0)])
    lab.run("wallpaper")
    sizes = {name: load_png(path).shape[:2] for name, path in hands_to_sway(lab)}
    assert sizes == {"eDP-1": (1200, 1920), "DP-2": (1440, 3440)}
    assert len(cached(lab, "lock-*.png")) == 2


def test_wallpaper_leaves_one_image_per_output(lab):
    for _ in range(3):
        lab.run("wallpaper")
    assert len(hands_to_sway(lab)) == 3
    assert len(cached(lab, "wall-eDP-1-*.png")) == 1
    assert len(cached(lab, "lock-*.png")) == 1
    assert cached(lab, "*.tmp") == []
    assert [p for _, p in hands_to_sway(lab)][-1] == str(cached(lab, "wall-eDP-1-*.png")[0])


def test_wallpaper_with_no_active_output_does_nothing(lab):
    lab.outputs_path.write_text("[]")
    proc = lab.run("wallpaper")
    assert proc.returncode == 0 and hands_to_sway(lab) == []


def test_wallpaper_skips_outputs_that_are_off(lab):
    data = json.loads(lab.outputs_path.read_text())
    data[0]["active"] = False
    lab.outputs_path.write_text(json.dumps(data))
    lab.run("wallpaper")
    assert hands_to_sway(lab) == []


def test_wallpaper_says_so_when_sway_refuses(lab):
    proc = lab.run("wallpaper", check=False, STUB_SWAYMSG_FAIL="1")
    assert proc.returncode == 1
    assert "swaymsg" in proc.stderr and "Traceback" not in proc.stderr


def test_wallpaper_says_so_when_sway_prints_nonsense(lab):
    lab.outputs_path.write_text("this is not json")
    proc = lab.run("wallpaper", check=False)
    assert proc.returncode == 1
    assert "Traceback" not in proc.stderr and "get_outputs" in proc.stderr


def test_wallpaper_says_so_when_the_cache_cannot_be_written(lab):
    if os.geteuid() == 0:
        pytest.skip("root writes everywhere")
    lab.cache.mkdir()
    lab.cache.chmod(0o500)
    try:
        proc = lab.run("wallpaper", check=False)
    finally:
        lab.cache.chmod(0o700)
    assert proc.returncode == 1
    assert "Traceback" not in proc.stderr and "cache" in proc.stderr


def test_two_wallpapers_at_once_do_not_trip_over_each_other(lab):
    procs = [
        subprocess.Popen(
            list(BACKDROP) + ["wallpaper"], env=lab.env(), stderr=subprocess.PIPE, text=True
        )
        for _ in range(4)
    ]
    for p in procs:
        _, err = p.communicate(timeout=120)
        assert p.returncode == 0, err
    assert len(hands_to_sway(lab)) == 4
    [last] = cached(lab, "wall-eDP-1-*.png")
    assert load_png(last).shape == (H, W, 3)
    [lock] = cached(lab, "lock-*.png")
    assert load_png(lock).shape == (H, W, 3)
    assert cached(lab, "*.tmp") == []


def test_a_wallpaper_and_a_lock_at_once(lab):
    wall = subprocess.Popen(list(BACKDROP) + ["wallpaper"], env=lab.env(), stderr=subprocess.PIPE, text=True)
    lock = subprocess.Popen(
        list(BACKDROP) + ["lock-args"], env=lab.env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    out, err = lock.communicate(timeout=120)
    assert lock.returncode == 0, err
    _, err = wall.communicate(timeout=120)
    assert wall.returncode == 0, err
    assert out.splitlines()[0] == "-i"
    assert load_png(out.splitlines()[1].split(":", 1)[1]).shape == (H, W, 3)


# lock-args ---------------------------------------------------------------


def test_lock_args_name_the_image_of_every_output(lab):
    lab.set_outputs([("eDP-1", W, H, S), ("DP-2", 3440, 1440, 1.0)])
    args, proc = lock_args(lab)
    assert set(args) == {"eDP-1", "DP-2"}
    assert load_png(args["DP-2"]).shape == (1440, 3440, 3)
    assert lab.journal(proc) == []


def test_lock_args_reuse_the_image_they_made(lab):
    first, _ = lock_args(lab)
    path = first["eDP-1"]
    before = os.stat(path).st_mtime_ns
    time.sleep(0.05)
    second, _ = lock_args(lab)
    assert second == first and os.stat(path).st_mtime_ns == before


def test_the_lock_image_is_made_again_when_the_look_changes(lab):
    first, _ = lock_args(lab)
    lab.write_config(accent="teal")
    second, _ = lock_args(lab)
    assert second["eDP-1"] != first["eDP-1"]
    assert where(load_png(second["eDP-1"]), rgb("teal")).sum() > 3000


def test_the_lock_image_is_not_made_again_when_only_the_tools_change(lab):
    first, _ = lock_args(lab)
    lab.write_config(tools=lab.logos("disc", "bar"))
    second, _ = lock_args(lab)
    assert second == first


def test_the_lock_image_is_made_again_when_the_image_file_changes(lab):
    from test_image import banded_png

    path = banded_png(lab.work / "wall.png")
    lab.write_config(image=str(path))
    first, _ = lock_args(lab)
    banded_png(path, w=500, h=300)
    second, _ = lock_args(lab)
    assert second["eDP-1"] != first["eDP-1"]


def test_an_output_that_is_gone_still_gets_its_image(lab):
    # Docked while locked: the monitor was seen before, so the lock names it.
    lab.set_outputs([("eDP-1", W, H, S), ("DP-2", 3440, 1440, 1.0)])
    lab.run("wallpaper")
    lab.set_outputs([("eDP-1", W, H, S)])
    args, _ = lock_args(lab)
    assert set(args) == {"eDP-1", "DP-2"}
    assert os.path.exists(args["DP-2"])


def test_an_output_that_changed_size_is_named_once_with_its_new_image(lab):
    lab.set_outputs([("DP-2", 1920, 1080, 1.0)])
    lab.run("wallpaper")
    lab.set_outputs([("DP-2", 3440, 1440, 1.0)])
    args, _ = lock_args(lab)
    assert list(args) == ["DP-2"]
    assert load_png(args["DP-2"]).shape == (1440, 3440, 3)


def test_lock_args_with_no_output_print_nothing(lab):
    lab.outputs_path.write_text("[]")
    proc = lab.run("lock-args")
    assert proc.stdout == "" and proc.returncode == 0


def test_a_broken_seen_list_is_started_afresh(lab):
    lock_args(lab)
    (lab.cache / "backdrop" / "lock-outputs.json").write_text("{not json")
    args, proc = lock_args(lab)
    assert list(args) == ["eDP-1"] and proc.returncode == 0


def test_the_pruning_keeps_the_images_in_use_and_drops_the_rest(lab):
    lock_args(lab)
    stale = lab.cache / "backdrop" / "lock-0123456789ab.png"
    stale.write_bytes(b"old")
    lab.run("wallpaper")
    assert not stale.exists()
    assert len(cached(lab, "lock-*.png")) == 1


# the config ----------------------------------------------------------------


def test_no_config_is_an_error_that_names_it(lab):
    lab.config_path.unlink()
    proc = lab.run("render", "wall", lab.work / "x.png", "200x100", 1, check=False)
    assert proc.returncode == 1
    assert str(lab.config_path) in proc.stderr and "Traceback" not in proc.stderr
    assert not (lab.work / "x.png").exists()


def test_the_config_comes_from_the_xdg_config_dir_by_default(lab):
    target = lab.home / ".config" / "backdrop"
    target.mkdir(parents=True)
    (target / "config.json").write_text(lab.config_path.read_text())
    lab.config_path.unlink()
    env = {"BACKDROP_CONFIG": ""}
    proc = lab.run("render", "lock", lab.work / "x.png", "400x300", 1, **env)
    assert proc.returncode == 0 and (lab.work / "x.png").exists()


@pytest.mark.parametrize(
    "text, word",
    [
        ("{not json", "json"),
        ("[]", "object"),
        ('{"palette": {}}', "accent"),
        ('{"accent": "mauve", "font": "x"}', "palette"),
    ],
)
def test_a_broken_config_is_an_error_that_says_what(lab, text, word):
    lab.config_path.write_text(text)
    proc = lab.run("render", "lock", lab.work / "x.png", "200x100", 1, check=False)
    assert proc.returncode == 1
    assert word in proc.stderr.lower() and "Traceback" not in proc.stderr


def test_a_palette_without_a_color_the_look_needs_says_which(lab):
    config = json.loads(lab.config_path.read_text())
    del config["palette"]["sapphire"]
    lab.config_path.write_text(json.dumps(config))
    proc = lab.run("render", "wall", lab.work / "x.png", "400x300", 1, check=False)
    assert proc.returncode == 1 and "sapphire" in proc.stderr


def test_an_accent_the_palette_lacks_is_an_error(lab):
    lab.write_config(accent="chartreuse")
    proc = lab.run("render", "lock", lab.work / "x.png", "400x300", 1, check=False)
    assert proc.returncode == 1 and "chartreuse" in proc.stderr


def test_tools_that_are_not_a_list_are_an_error(lab):
    lab.write_config(tools="odin.svg")
    proc = lab.run("render", "wall", lab.work / "x.png", "400x300", 1, check=False)
    assert proc.returncode == 1 and "tools" in proc.stderr


# render ------------------------------------------------------------------


@pytest.mark.parametrize(
    "args",
    [
        [],
        ["render"],
        ["render", "wall", "x.png"],
        ["render", "wall", "x.png", "200x100"],
        ["render", "poster", "x.png", "200x100", "1"],
        ["render", "wall", "x.png", "200x100", "1", "extra"],
        ["wallpaper", "extra"],
        ["lock-args", "extra"],
        ["frobnicate"],
    ],
)
def test_wrong_usage_prints_the_usage_and_exits_2(lab, args):
    proc = lab.run(*args, check=False)
    assert proc.returncode == 2
    assert "usage" in proc.stderr.lower() and "Traceback" not in proc.stderr
    assert not (lab.work / "x.png").exists()


@pytest.mark.parametrize(
    "size, scale",
    [
        ("0x0", "1"),
        ("0x100", "1"),
        ("100x0", "1"),
        ("-5x10", "1"),
        ("100", "1"),
        ("axb", "1"),
        ("100x100x100", "1"),
        ("99999x99999", "1"),
        ("200x100", "0"),
        ("200x100", "-1"),
        ("200x100", "abc"),
        ("200x100", "nan"),
        ("200x100", "inf"),
        ("200x100", "1000"),
    ],
)
def test_impossible_sizes_are_refused_without_a_file(lab, size, scale):
    out = lab.work / "x.png"
    proc = lab.run("render", "wall", out, size, scale, check=False)
    assert proc.returncode == 2, proc.stderr
    assert "Traceback" not in proc.stderr
    assert not out.exists() and not list(lab.work.glob("x.png*"))


def test_a_tiny_output_still_renders(lab):
    for kind in ("wall", "lock"):
        img, _ = lab.render(kind, size=(1, 1), scale=1)
        assert img.shape == (1, 1, 3)
    img, _ = lab.render("wall", size=(64, 48), scale=0.5)
    assert img.shape == (48, 64, 3)


def test_an_output_path_that_cannot_be_written_is_an_error(lab):
    proc = lab.run("render", "lock", lab.work / "no" / "such" / "dir" / "x.png", "200x100", 1, check=False)
    assert proc.returncode == 1
    assert "Traceback" not in proc.stderr and "x.png" in proc.stderr


def test_render_replaces_its_output_whole(lab):
    out = lab.work / "x.png"
    out.write_bytes(b"old")
    lab.run("render", "lock", out, "300x200", 1)
    assert load_png(out).shape == (200, 300, 3)
    assert list(lab.work.glob("x.png.*")) == []


# the facts -----------------------------------------------------------------


def right_half_is_bare(img, scale):
    from conftest import MARK_REACH, not_base

    # Right of the middle and above the circle the ravnix mark reaches.
    top = int(img.shape[0] / 2 - MARK_REACH * scale)
    return not not_base(img[:top, img.shape[1] // 2 :]).any()


def test_missing_facts_leave_the_wallpaper_without_them_and_say_so_once(lab):
    lab.extra_env["BACKDROP_FACTS"] = str(lab.work / "none")
    img, proc = lab.render("wall")
    assert proc.returncode == 0 and right_half_is_bare(img, S)
    assert len(lab.journal(proc)) == 1
    assert where(img, rgb("mauve")).sum() > 3000


def test_empty_facts_draw_nothing(lab):
    lab.facts_path.write_text("")
    img, proc = lab.render("wall")
    assert right_half_is_bare(img, S) and lab.journal(proc) == []


@pytest.mark.parametrize(
    "text",
    [
        b"no newline at the end",
        b"\n\n\n\n\n",
        b"\x1b[31mred\x1b[0m\t\ttabs\r\r\n",
        b"\x1b[38;2;999;999;999mtoo big\x1b[m\n",
        b"\x1b[38;5;300mindex\x1b[m\n\x1b[38;5;1mindex\x1b[m\n",
        b"\x1b[2J\x1b[H\x1b[10;10Hcursor movement\x1b[?25l\x1b[K\n",
        b"\x1b]0;a title\x07after the title\n",
        b"\x1b[999999999G far right\n",
        b"\x1b[\n\x1b\n\x1b[38;2;1\n",
        b"\x00\x01\x02 control bytes \x7f\n",
        b"bad utf-8 \xff\xfe in the middle\n",
        "\u202e right to left \u200b zero width \U0001f600 emoji \u4e2d\u6587\n".encode(),
    ],
)
def test_hostile_facts_do_not_break_the_wallpaper(lab, text):
    lab.facts_path.write_bytes(text)
    img, proc = lab.render("wall", size=(800, 500), scale=1)
    assert proc.returncode == 0, proc.stderr
    assert "Traceback" not in proc.stderr
    assert where(img, rgb("mauve")).sum() > 500


def test_huge_facts_are_cut_and_do_not_hang(lab):
    lines = ["\x1b[1m" + "x" * 200_000 + "\x1b[m" for _ in range(50)] + ["short"] * 200_000
    lab.facts_path.write_text("\n".join(lines))
    start = time.monotonic()
    img, proc = lab.render("wall", size=(800, 500), scale=1, timeout=60)
    assert proc.returncode == 0 and time.monotonic() - start < 30
    assert where(img, rgb("mauve")).sum() > 500


# a fastfetch that goes wrong ------------------------------------------------


def render_with_fastfetch(lab, **env):
    env = {k: v for k, v in lab.env(BACKDROP_FASTFETCH_SECONDS="2", **env).items() if k != "BACKDROP_FACTS"}
    out = lab.work / "ff.png"
    start = time.monotonic()
    proc = subprocess.run(
        list(BACKDROP) + ["render", "wall", str(out), "800x500", "1"],
        env=env, capture_output=True, text=True, timeout=60,
    )
    return proc, time.monotonic() - start, out


@pytest.mark.parametrize(
    "body, word",
    [
        ("echo 'fastfetch: boom' >&2; exit 3\n", "boom"),
        ("exit 0\n", "no facts"),
        ("echo; echo '   '; exit 0\n", "no facts"),
        ("echo 'some facts'; echo 'fastfetch: half way' >&2; exit 1\n", "half way"),
        # More on stderr than is read: the pipe is still emptied, so it cannot block.
        ("echo 'fastfetch: loud' >&2; head -c 300000 /dev/zero | tr '\\0' x >&2; exit 3\n", "loud"),
    ],
)
def test_a_fastfetch_that_fails_leaves_the_wallpaper_without_facts(lab, body, word):
    lab.install_stub("fastfetch", "#!/usr/bin/env bash\n" + body)
    proc, _, out = render_with_fastfetch(lab)
    assert proc.returncode == 0, proc.stderr
    lines = proc.stderr.splitlines()
    assert len(lines) == 1 and word in lines[0], lines
    img = load_png(out)
    assert where(img, rgb("mauve")).sum() > 500
    assert right_half_is_bare(img, 1)


def test_a_fastfetch_that_hangs_is_given_up_on_with_its_children(lab):
    lab.install_stub("fastfetch", "#!/usr/bin/env bash\nsleep 60\n")
    proc, elapsed, out = render_with_fastfetch(lab)
    assert proc.returncode == 0, proc.stderr
    assert elapsed < 20, "waited for the hung fastfetch (%.1f s)" % elapsed
    lines = proc.stderr.splitlines()
    assert len(lines) == 1 and "fastfetch took more than 2 s" in lines[0], lines
    assert where(load_png(out), rgb("mauve")).sum() > 500


def alive(pid):
    # A killed process that nobody has reaped yet is a zombie, which is dead.
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return False


def test_a_fastfetch_that_never_stops_printing_is_cut_and_killed(lab):
    # What it printed is read only up to the cap, then it is killed with its
    # children: the 2 s it is given are neither used up nor spent holding
    # everything it wrote in memory.
    pid = lab.work / "pid.txt"
    lab.install_stub(
        "fastfetch",
        "#!/usr/bin/env bash\necho $$ > " + str(pid) + "\n"
        "while :; do printf '\\033[1mKey\\033[m value 0123456789 0123456789 0123456789\\n'; done\n",
    )
    proc, elapsed, out = render_with_fastfetch(lab)
    assert proc.returncode == 0, proc.stderr
    lines = proc.stderr.splitlines()
    assert len(lines) == 1 and "printed more than 1048576 bytes" in lines[0], lines
    assert elapsed < 20
    assert not right_half_is_bare(load_png(out), 1), "the first of what it printed is not used"
    assert not alive(int(pid.read_text())), "the runaway fastfetch was left running"


def test_a_child_that_outlives_fastfetch_and_holds_the_pipe_is_killed(lab):
    # fastfetch's shell is gone when the time is up, but a background child of
    # it still has the pipe open, so the read never ends: the child is killed
    # with the rest of the group, not left running after backdrop is done.
    pid = lab.work / "child.txt"
    lab.install_stub("fastfetch", "#!/usr/bin/env bash\nsleep 60 &\necho $! > " + str(pid) + "\nexit 0\n")
    proc, elapsed, out = render_with_fastfetch(lab)
    assert proc.returncode == 0, proc.stderr
    assert elapsed < 20
    lines = proc.stderr.splitlines()
    assert len(lines) == 1 and "fastfetch took more than 2 s" in lines[0], lines
    child = int(pid.read_text())
    deadline = time.monotonic() + 5
    while alive(child) and time.monotonic() < deadline:
        time.sleep(0.05)
    assert not alive(child), "the child that held the pipe is still running"


def test_a_bad_fastfetch_timeout_is_a_line_not_a_crash(lab):
    lab.install_stub("fastfetch", "#!/usr/bin/env bash\nexit 0\n")
    env = {k: v for k, v in lab.env(BACKDROP_FASTFETCH_SECONDS="soon").items() if k != "BACKDROP_FACTS"}
    out = lab.work / "ff.png"
    proc = subprocess.run(list(BACKDROP) + ["render", "wall", str(out), "800x500", "1"],
                          env=env, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0 and "Traceback" not in proc.stderr
    assert out.exists()


def test_fastfetch_gets_the_logo_colors_of_the_theme(lab):
    # The stand-in records its arguments: six slots, Blue and Sapphire.
    args = lab.work / "args.txt"
    lab.install_stub("fastfetch", '#!/usr/bin/env bash\nprintf "%s\\n" "$@" > ' + str(args) + "\n")
    render_with_fastfetch(lab)
    given = args.read_text().splitlines()
    assert given[:2] == ["--pipe", "false"]
    slots = {given[i]: given[i + 1] for i in range(2, len(given), 2)}
    blue, sapphire = rgb("blue"), rgb("sapphire")
    want = {}
    for n in range(1, 7):
        c = blue if n % 2 else sapphire
        want["--logo-color-%d" % n] = "38;2;%d;%d;%d" % c
    assert slots == want


# the real fastfetch ----------------------------------------------------------

real = pytest.mark.skipif(
    os.environ.get("BACKDROP_REAL_FASTFETCH") != "1", reason="BACKDROP_REAL_FASTFETCH is not 1"
)


@real
def test_the_real_fastfetch_draws_the_logo_and_the_facts_with_no_network(lab):
    config = os.environ.get("BACKDROP_TEST_FASTFETCH_CONFIG")
    if config:
        target = lab.home / ".config" / "fastfetch"
        target.mkdir(parents=True)
        (target / "config.jsonc").write_text(open(config).read())
    # The Failed row asks systemd, which the build sandbox has none of; the
    # stand-in finds no failed unit, as on a healthy machine, instead of the
    # row printing a shell's "command not found" in a line of its own.
    lab.install_stub("systemctl", "#!/usr/bin/env bash\nexit 0\n")
    env = {k: v for k, v in lab.env().items() if k != "BACKDROP_FACTS"}
    out = lab.work / "real.png"
    start = time.monotonic()
    proc = subprocess.run(
        list(BACKDROP) + ["render", "wall", str(out), "%dx%d" % (W, H), str(S)],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert proc.returncode == 0, proc.stderr
    assert time.monotonic() - start < 30
    img = load_png(out)
    right = img[: H // 2, W // 2 :]
    assert where(right, rgb("blue")).sum() > 500
    assert where(right, rgb("sapphire")).sum() > 500
    assert where(right, rgb("text")).sum() > 100
    assert len(proc.stderr.splitlines()) <= 1, proc.stderr
    # The Palette row is one line that starts in the value column, as on the
    # terminal: fastfetch's block symbol prints the bright eight on a second
    # line with no jump to that column, and backdrop does not reflow it.
    facts = img[: int(0.40 * H), W // 2 :]
    assert abs(palette_row_offset(facts)) < 1.5
    # And it holds the swatches that are no state hue, and none that is: this
    # is where a change of the colors module's symbol or padding would show.
    first, last, top, bottom, _ = palette_box(facts)
    for name in SWATCHES:
        assert where(facts[top:bottom, first:last], rgb(name)).any(), name
    for hue in STATE_HUES:
        assert not where(facts[top:bottom, first - 1 : last + 1], rgb(hue)).any(), hue


def test_a_line_that_is_too_wide_shrinks_the_facts_to_fit(lab):
    # 200 columns do not fit in the room right of the panel's left edge at the
    # usual size; the panel shrinks so that none of it runs off the screen.
    lab.facts_path.write_text(facts_text().replace(KERNEL, "v" * 150))
    img, _ = lab.render("wall")
    from conftest import bbox, not_base

    right = img[: int(0.40 * H), W // 2 :]
    x1 = bbox(not_base(right))[2] + W // 2
    assert x1 < W * 0.985
    # The facts are tiny now, so no pixel is fully Text: something is drawn
    # besides the logo's blocks.
    logo = where(right, rgb("blue")) | where(right, rgb("sapphire"))
    assert (not_base(right) & ~logo).sum() > 500, "the facts vanished"
