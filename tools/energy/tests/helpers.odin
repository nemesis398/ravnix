// The tests of energy. Each one builds a small world under a temporary
// directory: the charger's file, the state and runtime directories, and a
// bin directory in which every program energy runs (busctl, swaymsg, fuzzel,
// gdbus, keep-awake, ...) is a link to testdata/fake, which logs its call
// and does what its .case file says. energy finds them on the fixture's
// PATH, which holds nothing else, so a test can never reach the desktop it
// runs on. No setting of the machine changes.
package energy_tests

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import energy ".."

FAKE :: #directory + "/testdata/fake"

// The programs of the world. Each is a link to FAKE.
PROGRAMS :: []string{"busctl", "swaymsg", "fuzzel", "gdbus", "keep-awake", "waybar-launch", "setsid", "notify-send", "systemctl", "pgrep", "charge-mode"}

// The cases of the programs that do more than log.
CASES :: [?][2]string {
	{
		"busctl",
		`[ -e "$dir/busctl.fails" ] && exit 1
case "$2" in
get-property) read -r p <"$dir/profile"; printf 's "%s"\n' "$p" ;;
set-property)
	printf '%s\n' "$name $*" >>"$dir/calls"
	[ -e "$dir/busctl.set-fails" ] && { echo "Unauthorized" >&2; exit 1; }
	printf '%s\n' "$8" >"$dir/profile" ;;
esac
`,
	},
	{
		"swaymsg",
		`if [ "$1 $2" = "-t get_outputs" ]; then
	n=0; [ -r "$dir/refreshes" ] && read -r n <"$dir/refreshes"
	echo $((n + 1)) >"$dir/refreshes"
	[ -e "$dir/swaymsg.hangs" ] && exec sleep 30
	[ -f "$dir/outputs" ] || exit 1
	while IFS= read -r l || [ -n "$l" ]; do printf '%s\n' "$l"; done <"$dir/outputs"
	exit 0
fi
printf '%s\n' "$name $*" >>"$dir/calls"
[ -e "$dir/swaymsg.set-fails" ] && exit 2
exit 0
`,
	},
	{
		"fuzzel",
		`prompt=""
while [ $# -gt 0 ]; do [ "$1" = --prompt ] && prompt=$2; shift; done
: >"$dir/rows"
while IFS= read -r l; do printf '%s\n' "$l" >>"$dir/rows"; done
{ printf 'fuzzel [%s]\n' "$prompt"; while IFS= read -r l; do printf '  | %s\n' "$l"; done <"$dir/rows"; } >>"$dir/fuzzel.log"
n=0; [ -r "$dir/fuzzel.n" ] && read -r n <"$dir/fuzzel.n"
n=$((n + 1)); echo $n >"$dir/fuzzel.n"
[ -e "$dir/fuzzel.says" ] && { read -r say <"$dir/fuzzel.says"; printf '%s\n' "$say"; exit 0; }
pat=""; i=0
if [ -r "$dir/picks" ]; then
	while IFS= read -r l; do i=$((i + 1)); [ $i -eq $n ] && { pat=$l; break; }; done <"$dir/picks"
fi
[ -n "$pat" ] && [ "$pat" != ESC ] || exit 1
while IFS= read -r l; do
	case $l in *"$pat"*) printf '%s\n' "$l"; exit 0 ;; esac
done <"$dir/rows"
exit 1
`,
	},
	{
		"gdbus",
		`case "$*" in *org.freedesktop.UPower*) ;; *) exit 0 ;; esac
n=0; [ -r "$dir/refreshes" ] && read -r n <"$dir/refreshes"
while read -r what text; do
	case "$what" in
	online) printf '%s\n' "$text" >"$dir/online" ;;
	noise) printf '%s\n' "$text" ;;
	partial) printf '%s' "$text" ;;
	say)
		printf '%s\n' "$text"; n=$((n + 1)); i=0
		while :; do
			c=0; [ -r "$dir/refreshes" ] && read -r c <"$dir/refreshes"
			[ "$c" -ge "$n" ] && break
			[ $i -ge 200 ] && break
			sleep 0.02; i=$((i + 1))
		done ;;
	esac
done <"$dir/events"
`,
	},
	{
		"keep-awake",
		`printf '%s\n' "$name $*" >>"$dir/calls"
s=0; [ -r "$dir/keep-awake.status" ] && read -r s <"$dir/keep-awake.status"
exit "$s"
`,
	},
	{
		"systemctl",
		`if [ "$1" = is-active ]; then
	if [ -r "$dir/active_units" ]; then
		while read -r u; do [ "$u" = "$3" ] && exit 0; done <"$dir/active_units"
	fi
	exit 3
fi
printf '%s\n' "$name $*" >>"$dir/calls"
`,
	},
	{
		"pgrep",
		`eval "last=\${$#}"
if [ -r "$dir/running" ]; then
	while IFS= read -r l; do [ "$l" = "$last" ] && exit 0; done <"$dir/running"
fi
exit 1
`,
	},
	{
		"charge-mode",
		`if [ "${1:-}" = set ]; then printf '%s\n' "$name $*" >>"$dir/calls"; exit 0; fi
[ -r "$dir/charge_now" ] || exit 1
read -r m <"$dir/charge_now"; printf '%s\n' "$m"
`,
	},
}

Fixture :: struct {
	arena: virtual.Arena,
	dir:   string,
	bin:   string,
	state: string,
	run:   string,
	cfg:   energy.Config,
}

join :: proc(parts: ..string) -> string {
	return strings.join(parts, "/")
}

make_dirs :: proc(t: ^testing.T, path: string) {
	err := os.make_directory_all(path)
	testing.expectf(t, err == nil || err == .Exist, "%s: %v", path, err)
}

write :: proc(t: ^testing.T, path, data: string) {
	make_dirs(t, path[:strings.last_index_byte(path, '/')])
	testing.expect_value(t, os.write_entire_file(path, transmute([]byte)data), nil)
}

// fixture is a world on the charger, with the profile balanced, no setting
// saved, no Sway, and every program present. A test takes away what it is
// about. The caller sets context.allocator to the fixture's arena.
fixture :: proc(t: ^testing.T, f: ^Fixture) {
	testing.expect_value(t, virtual.arena_init_growing(&f.arena), nil)
	context.allocator = virtual.arena_allocator(&f.arena)
	dir, err := os.make_directory_temp("", "energy-test-*", context.allocator)
	testing.expect_value(t, err, nil)
	f.dir = dir
	f.bin = join(dir, "bin")
	f.state = join(dir, "state/energy")
	f.run = join(dir, "run")
	make_dirs(t, f.bin)
	make_dirs(t, f.run)
	for name in PROGRAMS {
		testing.expect_value(t, os.symlink(FAKE, join(f.bin, name)), nil)
	}
	for c in CASES {
		write(t, join(f.bin, strings.concatenate({c[0], ".case"})), c[1])
	}
	// The one real program the stubs use, sleep, and nothing else.
	tools := join(dir, "tools")
	make_dirs(t, tools)
	sleep, found := energy.find_program(os.get_env("PATH", context.allocator), "sleep")
	testing.expect(t, found, "sleep is not on the PATH of the test")
	testing.expect_value(t, os.symlink(sleep, join(tools, "sleep")), nil)

	write(t, join(f.bin, "profile"), "balanced\n")
	write(t, join(f.bin, "online"), "1\n")
	write(t, join(f.bin, "calls"), "")
	f.cfg = energy.Config {
		state_dir   = f.state,
		run_dir     = f.run,
		online_file = join(f.bin, "online"),
		charge_mode = join(f.bin, "charge-mode"),
		path        = strings.concatenate({f.bin, ":", tools}),
		timeout     = 5 * time.Second,
	}
}

destroy :: proc(f: ^Fixture) {
	_ = os.remove_all(f.dir)
	virtual.arena_destroy(&f.arena)
}

// remove_program takes a program off the PATH of the world.
remove_program :: proc(t: ^testing.T, f: ^Fixture, name: string) {
	testing.expect_value(t, os.remove(join(f.bin, name)), nil)
}

// The state of the world, as the stubs read it.
charger :: proc(t: ^testing.T, f: ^Fixture, v: string) {
	write(t, join(f.bin, "online"), strings.concatenate({v, "\n"}))
}
profile_is :: proc(t: ^testing.T, f: ^Fixture, v: string) {
	write(t, join(f.bin, "profile"), strings.concatenate({v, "\n"}))
}
set_state :: proc(t: ^testing.T, f: ^Fixture, key, v: string) {
	write(t, join(f.state, key), strings.concatenate({v, "\n"}))
}
set_run :: proc(t: ^testing.T, f: ^Fixture, name, v: string) {
	write(t, join(f.run, name), strings.concatenate({v, "\n"}))
}
picks :: proc(t: ^testing.T, f: ^Fixture, rows: ..string) {
	write(t, join(f.bin, "picks"), strings.concatenate({strings.join(rows, "\n"), "\n"}))
}
events :: proc(t: ^testing.T, f: ^Fixture, lines: ..string) {
	write(t, join(f.bin, "events"), strings.concatenate({strings.join(lines, "\n"), "\n"}))
}

// outputs writes the list sway reports: each "NAME:ACTIVE:MHZ" is a
// 2560x1600 output.
outputs :: proc(t: ^testing.T, f: ^Fixture, list: ..string) {
	b := strings.builder_make()
	strings.write_string(&b, "[")
	for o, i in list {
		parts := strings.split(o, ":")
		if i > 0 {
			strings.write_string(&b, ",")
		}
		fmt.sbprintf(&b, `{{"name":"%s","active":%s,"current_mode":{{"width":2560,"height":1600,"refresh":%s}}}}`, parts[0], parts[1], parts[2])
	}
	strings.write_string(&b, "]\n")
	write(t, join(f.bin, "outputs"), strings.to_string(b))
}

// flag creates an empty file the stubs look for.
flag :: proc(t: ^testing.T, f: ^Fixture, name: string) {
	write(t, join(f.bin, name), "")
}

// run runs energy with the arguments, and returns the status and what it
// printed on standard output and standard error.
run :: proc(t: ^testing.T, f: ^Fixture, args: ..string) -> (code: int, out, err: string) {
	out_path, err_path := join(f.dir, "stdout"), join(f.dir, "stderr")
	out_file, e1 := os.open(out_path, {.Write, .Create, .Trunc})
	err_file, e2 := os.open(err_path, {.Write, .Create, .Trunc})
	testing.expect_value(t, e1, nil)
	testing.expect_value(t, e2, nil)
	f.cfg.stdout, f.cfg.stderr = out_file, err_file
	code = energy.run(args, &f.cfg)
	_ = os.close(out_file)
	_ = os.close(err_file)
	o, _ := os.read_entire_file(out_path, context.allocator)
	e, _ := os.read_entire_file(err_path, context.allocator)
	return code, string(o), string(e)
}

calls :: proc(f: ^Fixture) -> string {
	data, _ := os.read_entire_file(join(f.bin, "calls"), context.allocator)
	return strings.trim_right(string(data), "\n")
}

// expect_calls checks the log of the stubs, one call a line.
expect_calls :: proc(t: ^testing.T, f: ^Fixture, want: ..string, loc := #caller_location) {
	testing.expect_value(t, calls(f), strings.join(want, "\n"), loc)
}

read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	return strings.trim_right(string(data), "\n"), err == nil
}

// expect_file checks that a file holds the text, without its newline.
expect_file :: proc(t: ^testing.T, path, want: string, loc := #caller_location) {
	got, ok := read_text(path)
	testing.expectf(t, ok, "%s cannot be read", path, loc = loc)
	testing.expect_value(t, got, want, loc)
}

exists :: proc(path: string) -> bool {
	return os.exists(path)
}

// The commands of the Hz the panel is set to, as sway is called.
mode_call :: proc(name: string, hz: int) -> string {
	return fmt.aprintf("swaymsg output %s mode 2560x1600@%dHz", name, hz)
}

refreshes :: proc(f: ^Fixture) -> string {
	text, _ := read_text(join(f.bin, "refreshes"))
	return text
}

remove_file :: proc(path: string) -> bool {
	return os.remove(path) == nil
}
