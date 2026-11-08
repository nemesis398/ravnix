#!/usr/bin/env bash
# Tests for btop-gpu and btop-auto (packages/btop-gpu), run by the check
# bin-btop-gpu. btop is a stand-in that copies the config it is started with, so
# the contract can be read off it: the throwaway config derived from the user's
# own, the keys it overrides, the real config untouched, the throwaway gone
# afterwards, and the arguments passed on. The dGPU's power state is read from
# sysfs at a fixed path, which a test cannot fake, so btop-auto is only checked
# on a machine without the NVIDIA driver (the build sandbox): it starts plain
# btop.
#
# BTOP_GPU_UNDER_TEST and BTOP_AUTO_UNDER_TEST=<file> test other copies; by
# default they are the commands on the PATH.

# The checks are eval'd, so their $ expand at check time (SC2016), and the
# variables they read are set outside them (SC2034).
# shellcheck disable=SC2016,SC2034

set -uo pipefail

GPU=$(readlink -f "${BTOP_GPU_UNDER_TEST:-$(type -P btop-gpu)}")
AUTO=$(readlink -f "${BTOP_AUTO_UNDER_TEST:-$(type -P btop-auto)}")
BASH_BIN=$(type -P bash)
SB=$(mktemp -d "${TMPDIR:-/tmp}/btop-gpu-test.XXXXXX")
trap 'rm -rf "$SB"' EXIT

pass=0 fail=0
ok()  { printf '  \e[32m✓\e[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \e[31m✗\e[0m %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$SB/bin" "$SB/tmp" "$SB/home/.config/btop"
cat >"$SB/bin/btop" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$SB_OUT/args"
printf 'ld:%s\n' "${LD_LIBRARY_PATH-}" >>"$SB_OUT/args"
if [[ ${1-} == -c ]]; then
    cp -- "$2" "$SB_OUT/conf"
    printf '%s\n' "$2" >"$SB_OUT/conf-path"
fi
exit "${STUB_RC:-0}"
STUB
sed -i "1s|.*|#!$BASH_BIN|" "$SB/bin/btop"
chmod +x "$SB/bin/btop"

# run CMD [ENV=VAL ...] -- ARGS: sets $out, $rc, and reads the stand-in's notes.
run() {
    local cmd=$1; shift
    local envs=()
    while [[ $1 != -- ]]; do envs+=("$1"); shift; done
    shift
    rm -rf "$SB/o"; mkdir -p "$SB/o"; rm -f "$SB/tmp"/*
    out=$(env -i HOME="$SB/home" PATH="$SB/bin" SB_OUT="$SB/o" TMPDIR="$SB/tmp" "${envs[@]}" "$BASH_BIN" "$cmd" "$@" 2>&1)
    rc=$?
    args="" conf=""
    [[ -r $SB/o/args ]] && args=$(<"$SB/o/args")
    [[ -r $SB/o/conf ]] && conf=$(<"$SB/o/conf")
}
check() { if eval "$2"; then ok "$1"; else bad "$1" "    rc: $rc
    out: $out
    args: $args
    conf: $conf"; fi; }
has_line() { grep -qxF -- "$1" <<<"$conf"; }

echo "btop-gpu"

printf '%s\n' 'color_theme = "mocha"' 'shown_gpus = "amd"' 'save_config_on_exit = true' 'shown_boxes = "cpu mem net proc"' >"$SB/home/.config/btop/btop.conf"
orig=$(<"$SB/home/.config/btop/btop.conf")
run "$GPU" -- --utf-force
check "btop is started with -c and a throwaway config, and the arguments follow" '[[ $args == "-c "*"/btop-gpu."*".conf --utf-force"* ]]'
check "the user's keys are inherited" 'has_line "color_theme = \"mocha\""'
check "shown_gpus gains nvidia, replaced in place" 'has_line "shown_gpus = \"amd nvidia\"" && ! has_line "shown_gpus = \"amd\""'
check "save_config_on_exit is forced off, so the throwaway cannot clobber the real settings" \
    'has_line "save_config_on_exit = false" && ! has_line "save_config_on_exit = true"'
check "the two GPU boxes are appended to the layout" 'has_line "shown_boxes = \"cpu mem net proc gpu0 gpu1\""'
check "the real config is untouched" '[[ $(<"$SB/home/.config/btop/btop.conf") == "$orig" ]]'
check "the throwaway is removed when btop exits" '[[ -z $(ls -A "$SB/tmp") ]]'
check "the loader is told where the driver keeps NVML, in front of what was set" '[[ $args == *"ld:/run/opengl-driver/lib" ]]'

run "$GPU" LD_LIBRARY_PATH=/somewhere -- 
check "an LD_LIBRARY_PATH of the user is kept behind it" '[[ $args == *"ld:/run/opengl-driver/lib:/somewhere" ]]'

printf '%s\n' 'shown_boxes = "cpu gpu0 net"' >"$SB/home/.config/btop/btop.conf"
run "$GPU" -- 
check "a layout that has gpu0 already is left as it is" 'has_line "shown_boxes = \"cpu gpu0 net\""'

rm -f "$SB/home/.config/btop/btop.conf"
run "$GPU" -- 
check "without a config the throwaway holds the three keys alone" \
    '[[ $conf == $'"'"'shown_gpus = "amd nvidia"\nsave_config_on_exit = false\nshown_boxes = "cpu mem net proc gpu0 gpu1"'"'"' ]]'

run "$GPU" XDG_CONFIG_HOME="$SB/xdg" -- 
check "XDG_CONFIG_HOME decides where the user's config is" '[[ $rc == 0 ]]'
mkdir -p "$SB/xdg/btop"; printf 'color_theme = "xdg"\n' >"$SB/xdg/btop/btop.conf"
run "$GPU" XDG_CONFIG_HOME="$SB/xdg" -- 
check "the config under XDG_CONFIG_HOME is the one inherited" 'has_line "color_theme = \"xdg\""'

run "$GPU" STUB_RC=3 -- 
check "btop's exit status is the script's, and the throwaway is gone even so" '[[ $rc == 3 && -z $(ls -A "$SB/tmp") ]]'

run "$GPU" PATH="$SB/nobin" -- 
check "without btop on the PATH it fails, and the throwaway is gone" '[[ $rc -ne 0 && -z $(ls -A "$SB/tmp") ]]'

echo "btop-auto"
run "$AUTO" -- --version
if ls /sys/bus/pci/drivers/nvidia/0000:*/power/runtime_status >/dev/null 2>&1; then
    ok "(skipped: this machine has the NVIDIA driver, whose state decides what btop-auto starts)"
else
    check "without the NVIDIA driver it starts plain btop, with the arguments" '[[ $args == "--version"* && ! -e "$SB/o/conf" ]]'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
