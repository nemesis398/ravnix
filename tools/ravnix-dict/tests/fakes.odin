// The stand-ins the adapter tests run as real processes: a Handy and an rbw.
// Both are this test program itself, started through a link whose name
// says which one to be: fake_programs runs before the test runner does,
// and plays the part and exits when the name is one of theirs.
//
//   fh-N SETTINGS READY [stubborn]
//       Handy as it treats its settings: it reads SETTINGS into memory as
//       it starts, then makes READY. On SIGTERM it writes what it holds in
//       memory back to SETTINGS, in place, as Handy does when it quits, and
//       exits; "stubborn" ignores SIGTERM, so only SIGKILL ends it.
//   rbw unlocked | get ITEM | get --field username ITEM
//       rbw as the LanguageTool adapter asks it, from the files next to the
//       link: rbw-unlocked (there or not), rbw-item, rbw-key, rbw-user.
//       Every call is logged in rbw-log, without what it prints.
//   systemctl --user stop UNIT
//       systemd stopping Handy's unit, next to a file systemctl-fake: it
//       logs its arguments in systemctl-log, sends SIGTERM to each process
//       listed in systemctl-pids and waits until it has ended. With
//       systemctl-fail it then exits 1, as a stop job that timed out does;
//       with systemctl-keep as well it fails without stopping anything.
package ravnix_dict_tests

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

@(init)
fake_programs :: proc "contextless" () {
	context = runtime.default_context()
	data, err := os.read_entire_file("/proc/self/cmdline", context.allocator)
	if err != nil {
		return
	}
	args := strings.split(strings.trim_right(string(data), "\x00"), "\x00")
	if len(args) == 0 {
		return
	}
	slash := strings.last_index_byte(args[0], '/')
	base := args[0][slash + 1:]
	dir := args[0][:max(slash, 0)]
	switch {
	case strings.has_prefix(base, "fh-") && len(args) >= 3:
		fake_handy(args[1], args[2], len(args) > 3 && args[3] == "stubborn")
	case base == "rbw" && os.exists(strings.concatenate({dir, "/rbw-item"})):
		fake_rbw(dir, args[1:])
	case base == "systemctl" && os.exists(strings.concatenate({dir, "/systemctl-fake"})):
		fake_systemctl(dir, args[1:])
	}
}

fake_handy :: proc(settings, ready: string, stubborn: bool) -> ! {
	memory, _ := os.read_entire_file(settings, context.allocator)
	set: linux.Sig_Set
	set[0] = 1 << (uint(linux.Signal.SIGTERM) - 1)
	linux.rt_sigprocmask(.SIG_BLOCK, &set, nil)
	_ = os.write_entire_file(ready, "ready\n")
	for {
		info: linux.Sig_Info
		// A safety net: a stand-in left behind by a failed test ends itself.
		limit := linux.Time_Spec{time_sec = 60}
		sig, e := linux.rt_sigtimedwait(&set, &info, &limit)
		if e == .EINTR {
			continue
		}
		if e != .NONE {
			os.exit(2)
		}
		if sig == .SIGTERM && !stubborn {
			// Handy's store saves with fs::write: truncate, then write.
			_ = os.write_entire_file(settings, memory)
			os.exit(0)
		}
	}
}

fake_rbw :: proc(dir: string, args: []string) -> ! {
	file :: proc(dir, name: string) -> (string, bool) {
		data, err := os.read_entire_file(strings.concatenate({dir, "/", name}), context.allocator)
		return string(data), err == nil
	}
	log, _ := file(dir, "rbw-log")
	_ = os.write_entire_file(strings.concatenate({dir, "/rbw-log"}), strings.concatenate({log, strings.join(args, " "), "\n"}))
	item, _ := file(dir, "rbw-item")
	switch {
	case len(args) == 1 && args[0] == "unlocked":
		_, unlocked := file(dir, "rbw-unlocked")
		os.exit(0 if unlocked else 1)
	case len(args) == 2 && args[0] == "get" && args[1] == item:
		key, ok := file(dir, "rbw-key")
		if ok {
			os.write(os.stdout, transmute([]u8)strings.concatenate({key, "\n"}))
			os.exit(0)
		}
	case len(args) == 4 && args[0] == "get" && args[1] == "--field" && args[2] == "username" && args[3] == item:
		user, ok := file(dir, "rbw-user")
		if ok {
			os.write(os.stdout, transmute([]u8)strings.concatenate({user, "\n"}))
			os.exit(0)
		}
	}
	os.write(os.stderr, transmute([]u8)string("rbw: no such entry\n"))
	os.exit(1)
}

fake_systemctl :: proc(dir: string, args: []string) -> ! {
	log_path := strings.concatenate({dir, "/systemctl-log"})
	log, _ := os.read_entire_file(log_path, context.allocator)
	_ = os.write_entire_file(log_path, strings.concatenate({string(log), strings.join(args, " "), "\n"}))
	failing := os.exists(strings.concatenate({dir, "/systemctl-fail"}))
	if failing && os.exists(strings.concatenate({dir, "/systemctl-keep"})) {
		os.exit(1)
	}
	if len(args) == 3 && args[0] == "--user" && args[1] == "stop" {
		listed, _ := os.read_entire_file(strings.concatenate({dir, "/systemctl-pids"}), context.allocator)
		for line in strings.split_lines(string(listed)) {
			pid, ok := strconv.parse_int(line)
			if !ok {
				continue
			}
			linux.kill(linux.Pid(pid), .SIGTERM)
			for _ in 0 ..< 500 {
				stat, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.allocator)
				s := string(stat)
				close := strings.last_index_byte(s, ')')
				if err != nil || close < 0 || close + 2 >= len(s) || s[close + 2] == 'Z' {
					break
				}
				time.sleep(10 * time.Millisecond)
			}
		}
	}
	os.exit(1 if failing else 0)
}

// self_exe is the test program, which the links point at.
self_exe :: proc(f: ^Fixture) -> string {
	path, err := os.read_link("/proc/self/exe", f.a)
	if err != nil {
		return ""
	}
	return path
}

// link makes dir/name point at the test program.
link :: proc(f: ^Fixture, dir, name: string) -> string {
	path := strings.concatenate({dir, "/", name}, f.a)
	if err := os.symlink(self_exe(f), path); err != nil {
		return ""
	}
	return path
}
