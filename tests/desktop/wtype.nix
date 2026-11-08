# The wtype of the system types a dictation take without dropping characters.
#
# Handy types every take with `wtype -- TEXT`. wtype 0.4 gives the Nth distinct
# character of a text the evdev key code N. From the 29th on, characters land
# on the keys of Ctrl, Shift and Alt, the F-keys, the arrows and the number
# pad, and ghostty obeys the physical key: a probe of 126 distinct characters
# lost 65 of them in ghostty (measured on Fedora 2026-11-07). Upstream commit
# 82bca82b2b27e3d044c7cd5c22a471c8c60df72e, "Use printable keycodes for literal
# text", puts plain text on the 48 printable key positions only. nixpkgs ships
# wtype 0.5, which contains that commit (it is its parent's child: v0.5 is
# 4b9cc29, one commit after 82bca82), so ravnix builds no wtype of its own.
#
# This check does not trust the version number. It runs the wtype that a host
# with nixosModules.desktop installs (the one Handy's launcher puts first on
# PATH, checked below) against a real Wayland compositor (Sway, headless, in the build
# sandbox) with a window that records its key events (wev), types 126
# distinct characters, and requires that
#
#   - every character arrives, in order, and
#   - every key code used for them is one of the 48 printable positions.
#
# As a control, the same probe runs against wtype 0.4 and must fail, so the
# probe is known to see the defect it exists for.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  hostPkgs = inputs.nixpkgs.legacyPackages.${system};

  # The wtype of the system under test: the one in the profile of a host with
  # the desktop module, not the one nixpkgs happens to have, so an overlay or
  # a pin of a host cannot split the two.
  host = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = (import ../flake/helpers/host-modules.nix { inherit lib; }) ++ [
      self.nixosModules.desktop
    ];
  };
  wtype =
    lib.findFirst (p: lib.getName p == "wtype")
      (throw "no wtype in the system profile of a host with nixosModules.desktop")
      host.config.environment.systemPackages;
  handyLaunch = host.pkgs.ravnix.handy-launch;
  wtype04 = wtype.overrideAttrs (old: {
    version = "0.4";
    src = pkgs.fetchFromGitHub {
      owner = "atx";
      repo = "wtype";
      rev = "v0.4";
      hash = "sha256-TfpzAi0mkXugQn70MISyNFOXIJpDwvgh3enGv0Xq8S4=";
    };
  });

  # 94 printable ASCII characters and 32 letters of the Latin-1 supplement:
  # 126 distinct characters, none of them a space.
  probe = pkgs.runCommand "probe.txt" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 -I -c '
    chars = [chr(c) for c in range(33, 127)] + [chr(c) for c in range(0xC0, 0xE0)]
    assert len(set(chars)) == 126
    open("'$out'", "w", encoding="utf-8").write("".join(chars))
    '
  '';
in
pkgs.runCommand "desktop-wtype"
  {
    nativeBuildInputs = [
      hostPkgs.sway-unwrapped
      hostPkgs.wev
      hostPkgs.python3
      hostPkgs.coreutils
      hostPkgs.gnugrep
    ];
    inherit wtype handyLaunch;
    wtypeOld = wtype04;
    inherit probe;
    version = wtype.version;
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }

    export XDG_RUNTIME_DIR=$TMPDIR/run HOME=$TMPDIR/home
    mkdir -p "$XDG_RUNTIME_DIR" "$HOME"
    chmod 700 "$XDG_RUNTIME_DIR"
    # wtype decodes its arguments with the locale: the build sandbox has C.
    export LC_ALL=C.UTF-8
    export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman LIBSEAT_BACKEND=noop
    printf 'exec_always true\n' > "$TMPDIR/sway.conf"
    sway --config "$TMPDIR/sway.conf" > "$TMPDIR/sway.log" 2>&1 &
    sway_pid=$!
    trap 'kill $sway_pid 2>/dev/null || true' EXIT
    for _ in $(seq 1 100); do
      [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break
      sleep 0.1
    done
    [ -S "$XDG_RUNTIME_DIR/wayland-1" ] || { cat "$TMPDIR/sway.log"; fail "sway did not start"; exit 1; }
    export WAYLAND_DISPLAY=wayland-1

    # Types the probe with the given wtype into a fresh wev window and prints
    # what arrived as "text" and the key codes as "codes".
    run_probe() {
      local bin=$1 out=$2
      # wev writes to a file in blocks unless it is told to write lines, and
      # the block that is not full when it is stopped is lost.
      stdbuf -oL wev > "$out.log" 2>&1 &
      local wev_pid=$!
      for _ in $(seq 1 100); do
        grep -q 'keyboard: enter' "$out.log" 2>/dev/null && break
        grep -q 'wl_keyboard' "$out.log" 2>/dev/null && break
        sleep 0.1
      done
      sleep 0.5
      # The first key of an invocation can reach wev before its window has the
      # keyboard again: wtype's virtual keyboard brings a new keymap, and
      # Sway answers with a new enter. So the probe starts with a sentinel,
      # which may be lost and is not part of what is judged.
      "$bin" -- "§$(cat "$probe")"
      # Wait until wev has seen the keys (the sentinel and 126 characters, one
      # of which may be lost), not for a fixed time: the build may share the
      # machine with others. A short grace period catches the last events.
      for _ in $(seq 1 300); do
        [ "$(grep -c 'state: 1 (pressed)' "$out.log")" -ge 126 ] && break
        sleep 0.1
      done
      sleep 0.3
      kill $wev_pid 2>/dev/null || true
      wait $wev_pid 2>/dev/null || true
      python3 -I - "$out.log" "$out" <<'PY'
    import re, sys
    log = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    text, codes = [], []
    # A pressed key prints "key: serial: S; time: T; key: CODE; state: 1 (pressed)",
    # then "sym: NAME (N), utf8: 'X'" on the next line.
    for m in re.finditer(r"key: serial: \d+; time: \d+; key: (\d+); state: 1 \(pressed\)\s*\n\s*sym: .*?utf8: '(.*?)'\n", log, re.S):
        # wev prints XKB key codes, which are the evdev codes plus 8.
        codes.append(int(m.group(1)) - 8)
        text.append(m.group(2))
    open(sys.argv[2] + ".text", "w", encoding="utf-8").write("".join(text))
    open(sys.argv[2] + ".codes", "w").write(" ".join(map(str, codes)))
    PY
    }

    # The 48 printable key positions of a PC keyboard, as evdev codes: the digit
    # row (2-13), the three letter rows (16-27, 30-41, 43-53) and the space bar (57).
    printable="$(python3 -I -c 'print(" ".join(map(str, list(range(2,14))+list(range(16,28))+list(range(30,42))+list(range(43,54))+[57])))')"

    judge() { # judge LABEL OUTPREFIX [quiet] -> status 0 when the probe is clean
      local label=$1 out=$2 quiet=''${3:-} want got bad
      want=$(cat "$probe")
      got=$(cat "$out.text" 2>/dev/null || true)
      got=''${got#§}
      bad=""
      [ "$got" = "$want" ] || bad="the text that arrived has ''${#got} of 126 characters"
      for c in $(cat "$out.codes" 2>/dev/null); do
        case " $printable " in *" $c "*) ;; *) bad="$bad; key code $c is not a printable position"; break;; esac
      done
      if [ -n "$bad" ]; then
        bad=''${bad#; }
        echo "$label: $bad"
        if [ -z "$quiet" ]; then
          echo "  codes: $(cut -c1-300 "$out.codes")"
          echo "  text:  $(cut -c1-200 "$out.text")"
          echo "  log:   $(grep -n -m12 -E 'enter|keymap|modifiers|key:' "$out.log" | cut -c1-160)"
        fi
        return 1
      fi
      echo "$label: all 126 characters arrived on printable keys"
      return 0
    }

    # Handy types through the wtype that its launcher puts first on PATH; it has
    # to be this one.
    grep -q "$wtype/bin" "$handyLaunch/bin/handy-launch" || fail "handy-launch does not put the system's wtype ($wtype) first on PATH"

    run_probe "$wtype/bin/wtype" "$TMPDIR/new"
    judge "wtype $version" "$TMPDIR/new" || fail "the wtype of the system drops or misplaces characters"

    run_probe "$wtypeOld/bin/wtype" "$TMPDIR/old"
    if judge "wtype 0.4 (control)" "$TMPDIR/old" quiet; then
      fail "the control passed: the probe does not see the defect of wtype 0.4"
    fi
    # The defect of 0.4 is the Nth character on key N: the 29th character lands
    # on Left Ctrl. The control has to show that, not just fail somewhere.
    case " $(cat "$TMPDIR/old.codes") " in
      *" 29 "*) ;;
      *) fail "the control did not put a character on Left Ctrl (29): it fails for another reason than the defect it stands for: $(cut -c1-200 "$TMPDIR/old.codes")";;
    esac

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
