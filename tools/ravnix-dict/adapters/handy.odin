// Handy: its custom words are settings.custom_words in its settings store,
// ~/.local/share/com.pais.handy/settings_store.json (../README.md, "Handy").
//
// Handy keeps the store in memory and writes all of it back whenever a
// setting changes and when it quits (tauri-plugin-store), so a list written
// into the file while Handy runs is undone by its next save. A write
// therefore stops a running Handy first, reads the file again, writes it,
// and starts Handy again; Handy then reads the new list. Only the value of
// custom_words changes: every other byte of the file, its other settings
// and the API keys among them included, stays as it is.
package adapters

import "base:intrinsics"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

Handy :: struct {
	// The settings store.
	settings:     string,
	// The names under which a running Handy shows in /proc/PID/stat: the
	// wrapped binary of nixpkgs' package, and the plain one.
	names:        []string,
	// How long Handy may take to quit before it is killed.
	stop_timeout: time.Duration,
	// Starts Handy again after a write; nil is start_unit.
	start:        proc() -> Error,
	// The systemd user unit that start_unit starts: the one the session's
	// XDG autostart makes of handy-launch's entry.
	unit:         string,
}

HANDY_NAMES :: []string{".handy-wrapped", "handy"}
HANDY_UNIT :: "app-handy@autostart.service"
HANDY_STOP_TIMEOUT :: 10 * time.Second
// The largest settings store read.
HANDY_MAX_SIZE :: 16 * 1024 * 1024

@(thread_local)
handy: Handy
// What the last read returned, so that write can tell a word Handy got in
// the meantime from one the core took out.
@(thread_local)
handy_seen: []string

handy_read :: proc() -> ([]string, Error) {
	handy_seen = nil
	words, _, why := handy_load()
	if why != "" {
		return nil, why
	}
	handy_seen = words
	out := make([]string, len(words))
	copy(out, words)
	return out, nil
}

// handy_load reads the store. Handy writes it in place, not through a
// rename, so a read may meet half a file; it is read again, three times.
@(private)
handy_load :: proc() -> (words: []string, text: string, why: string) {
	for attempt in 0 ..< 3 {
		if attempt > 0 {
			time.sleep(100 * time.Millisecond)
		}
		missing: bool
		text, missing, why = read_text(handy.settings, HANDY_MAX_SIZE, context.allocator)
		if why != "" {
			return
		}
		if missing {
			return nil, "", ""
		}
		words, why = handy_words(text)
		if why == "" {
			return
		}
		why = fmt.tprintf("%s is not Handy's settings: %s", handy.settings, why)
	}
	return
}

// handy_words is settings.custom_words of a store: none when the store has
// no settings or they have no custom_words, as Handy reads it.
handy_words :: proc(text: string) -> (words: []string, why: string) {
	doc, dwhy := check_document(text)
	if dwhy != "" {
		return nil, dwhy
	}
	settings, found := member(text, doc, "settings")
	if !found {
		return nil, ""
	}
	if text[settings.value.start] != '{' {
		return nil, "settings is not an object"
	}
	list, has := member(text, settings.value, "custom_words")
	if !has {
		return nil, ""
	}
	words, why = string_array(text, list.value)
	if why != "" {
		why = fmt.tprintf("settings.custom_words %s", why)
	}
	return
}

// handy_splice is text with settings.custom_words set to words, and every
// other byte as it was; a store without the member gets it, at the end of
// its object, in the store's own layout.
handy_splice :: proc(text: string, words: []string) -> (string, string) {
	if strings.trim_space(text) == "" {
		b := strings.builder_make()
		strings.write_string(&b, "{\n  \"settings\": ")
		write_settings(&b, words, "  ", true)
		strings.write_string(&b, "\n}")
		return strings.to_string(b), ""
	}
	doc, why := check_document(text)
	if why != "" {
		return "", why
	}
	pretty := strings.contains_rune(text, '\n')
	settings, found := member(text, doc, "settings")
	if !found {
		return insert_member(text, doc, "settings", words, pretty, true), ""
	}
	if text[settings.value.start] != '{' {
		return "", "settings is not an object"
	}
	list, has := member(text, settings.value, "custom_words")
	if !has {
		return insert_member(text, settings.value, "custom_words", words, pretty, false), ""
	}
	if text[list.value.start] != '[' {
		return "", "settings.custom_words is not an array"
	}
	b := strings.builder_make()
	strings.write_string(&b, text[:list.value.start])
	write_array(&b, words, indent_of(text, list.key_s.start), pretty)
	strings.write_string(&b, text[list.value.end:])
	return strings.to_string(b), ""
}

// write_array writes words as serde_json's to_vec_pretty does, one per line
// under indent, or on one line as its to_vec does.
@(private)
write_array :: proc(b: ^strings.Builder, words: []string, indent: string, pretty: bool) {
	if len(words) == 0 {
		strings.write_string(b, "[]")
		return
	}
	strings.write_byte(b, '[')
	for w, i in words {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		if pretty {
			strings.write_byte(b, '\n')
			strings.write_string(b, indent)
			strings.write_string(b, "  ")
		}
		encode_string(b, w)
	}
	if pretty {
		strings.write_byte(b, '\n')
		strings.write_string(b, indent)
	}
	strings.write_byte(b, ']')
}

@(private)
write_settings :: proc(b: ^strings.Builder, words: []string, indent: string, pretty: bool) {
	if pretty {
		inner := strings.concatenate({indent, "  "}, context.temp_allocator)
		fmt.sbprintf(b, "{{\n%s\"custom_words\": ", inner)
		write_array(b, words, inner, true)
		fmt.sbprintf(b, "\n%s}}", indent)
	} else {
		strings.write_string(b, `{"custom_words":`)
		write_array(b, words, "", false)
		strings.write_byte(b, '}')
	}
}

// insert_member adds key to the object at span, after its last member:
// custom_words (an array of words) or settings (an object holding it).
@(private)
insert_member :: proc(text: string, object: Span, key: string, words: []string, pretty: bool, settings: bool) -> string {
	b := strings.builder_make()
	all := members(text, object)
	value :: proc(b: ^strings.Builder, words: []string, indent: string, pretty, settings: bool) {
		if settings {
			write_settings(b, words, indent, pretty)
		} else {
			write_array(b, words, indent, pretty)
		}
	}
	if len(all) > 0 {
		last := all[len(all) - 1]
		indent := indent_of(text, last.key_s.start)
		strings.write_string(&b, text[:last.value.end])
		if pretty {
			fmt.sbprintf(&b, ",\n%s\"%s\": ", indent, key)
		} else {
			fmt.sbprintf(&b, ",\"%s\":", key)
		}
		value(&b, words, indent, pretty, settings)
		strings.write_string(&b, text[last.value.end:])
		return strings.to_string(b)
	}
	// An empty object: the member goes between its braces.
	outer := indent_of(text, object.start)
	strings.write_string(&b, text[:object.start])
	if pretty {
		inner := strings.concatenate({outer, "  "}, context.temp_allocator)
		fmt.sbprintf(&b, "{{\n%s\"%s\": ", inner, key)
		value(&b, words, inner, pretty, settings)
		fmt.sbprintf(&b, "\n%s}}", outer)
	} else {
		fmt.sbprintf(&b, "{{\"%s\":", key)
		value(&b, words, "", pretty, settings)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, text[object.end:])
	return strings.to_string(b)
}

handy_write :: proc(words: []string) -> Error {
	pids := handy_processes()
	if len(pids) > 0 {
		if why := handy_stop(pids); why != "" {
			return why
		}
	}
	why := handy_store(words)
	if len(pids) > 0 {
		start := handy.start if handy.start != nil else start_unit
		if err := start(); err != nil {
			if why != "" {
				return fmt.tprintf("%s; and Handy, stopped to write it, could not be started again: %s", why, err.?)
			}
			return fmt.tprintf("the words are written, but Handy, stopped to write them, could not be started again: %s", err.?)
		}
	}
	if why != "" {
		return why
	}
	return nil
}

// handy_store writes words into the store as it is now: what Handy saved
// as it quit is read again, and a word it got since the last read (typed
// into its window) is kept after the words given, so the next sync takes
// it into the dictionary.
@(private)
handy_store :: proc(words: []string) -> string {
	now, text, why := handy_load()
	if why != "" {
		return why
	}
	seen := make(map[string]struct{}, context.temp_allocator)
	for w in handy_seen {
		seen[lower(strings.trim_space(w))] = {}
	}
	for w in words {
		seen[lower(strings.trim_space(w))] = {}
	}
	all := make([dynamic]string, 0, len(words) + 8)
	append(&all, ..words)
	for w in now {
		k := lower(strings.trim_space(w))
		if k not_in seen {
			seen[k] = {}
			append(&all, w)
		}
	}
	data, swhy := handy_splice(text, all[:])
	if swhy != "" {
		return fmt.tprintf("%s is not Handy's settings: %s", handy.settings, swhy)
	}
	if rwhy := replace(handy.settings, data, 0o644); rwhy != "" {
		return rwhy
	}
	handy_seen = all[:]
	return ""
}

// handy_processes is the running Handy processes of this user: those
// named as in handy.names, and not yet ended.
handy_processes :: proc() -> []int {
	out := make([dynamic]int)
	me := int(linux.getpid())
	uid := linux.getuid()
	names := handy.names if handy.names != nil else HANDY_NAMES
	for pid in process_ids() {
		if pid == me {
			continue
		}
		dir := fmt.tprintf("/proc/%d", pid)
		st: linux.Stat
		if linux.stat(cstr(dir), &st) != .NONE || st.uid != uid {
			continue
		}
		stat, _, why := read_text(fmt.tprintf("%s/stat", dir), 64 * 1024, context.temp_allocator)
		if why != "" {
			continue
		}
		open := strings.index_byte(stat, '(')
		close := strings.last_index_byte(stat, ')')
		if open < 0 || close < open || close + 2 >= len(stat) {
			continue
		}
		comm := stat[open + 1:close]
		state := stat[close + 2]
		if state == 'Z' || state == 'X' {
			continue
		}
		for n in names {
			if comm == n {
				append(&out, pid)
			}
		}
	}
	return out[:]
}

// process_ids is the processes in /proc. The names come straight from
// getdents: os.read_all_directory_by_path also looks at each entry, and
// fails as a whole when a process ends while it reads.
process_ids :: proc() -> []int {
	out := make([dynamic]int, context.temp_allocator)
	fd, e := linux.open("/proc", {.DIRECTORY, .CLOEXEC})
	if e != .NONE {
		return nil
	}
	defer linux.close(fd)
	buf: [16 * 1024]u8
	for {
		n, ge := linux.getdents(fd, buf[:])
		if ge == .EINTR {
			continue
		}
		if ge != .NONE || n <= 0 {
			break
		}
		offset := 0
		for d in linux.dirent_iterate_buf(buf[:n], &offset) {
			if pid, ok := strconv.parse_int(linux.dirent_name(d), 10); ok && pid > 0 {
				append(&out, pid)
			}
		}
	}
	return out[:]
}

// handy_stop asks each process to quit, waits, and kills what is left.
// What Handy saves as it quits is read again by handy_store.
@(private)
handy_stop :: proc(pids: []int) -> string {
	fds := make([dynamic]linux.Pid_FD, context.temp_allocator)
	for pid in pids {
		fd, e := linux.pidfd_open(linux.Pid(pid), {})
		if e == .ESRCH {
			continue
		}
		if e != .NONE {
			return fmt.tprintf("cannot stop Handy (process %d): %s", pid, errno_text(e))
		}
		append(&fds, fd)
	}
	defer for fd in fds {
		linux.close(linux.Fd(fd))
	}
	signal :: proc(fd: linux.Pid_FD, sig: linux.Signal) {
		intrinsics.syscall(linux.SYS_pidfd_send_signal, uintptr(fd), uintptr(sig), 0, 0)
	}
	for fd in fds {
		signal(fd, .SIGTERM)
	}
	timeout := handy.stop_timeout if handy.stop_timeout > 0 else HANDY_STOP_TIMEOUT
	if wait_ended(fds[:], timeout) {
		return ""
	}
	for fd in fds {
		signal(fd, .SIGKILL)
	}
	if wait_ended(fds[:], 5 * time.Second) {
		return ""
	}
	return "Handy did not quit, and not even when killed; its words are not written"
}

// wait_ended waits until every process has ended: a pidfd is readable
// once its process has, whether or not anyone has reaped it.
@(private)
wait_ended :: proc(fds: []linux.Pid_FD, timeout: time.Duration) -> bool {
	start := time.tick_now()
	for {
		polls := make([]linux.Poll_Fd, len(fds), context.temp_allocator)
		for fd, i in fds {
			polls[i] = {fd = linux.Fd(fd), events = {.IN}}
		}
		n, e := linux.poll(polls, 0)
		if e == .NONE && int(n) == len(fds) {
			ended := true
			for p in polls {
				ended &&= .IN in p.revents || .HUP in p.revents || .ERR in p.revents
			}
			if ended {
				return true
			}
		}
		if time.tick_since(start) >= timeout {
			return false
		}
		time.sleep(20 * time.Millisecond)
	}
}

// start_unit starts the session's Handy, the unit of handy-launch's
// autostart entry, with the session's environment.
start_unit :: proc() -> Error {
	unit := handy.unit if handy.unit != "" else HANDY_UNIT
	ran, why := run_program({"systemctl", "--user", "start", unit}, "", 30 * time.Second, context.allocator)
	if why != "" {
		return why
	}
	if ran.status != 0 {
		return fmt.tprintf("systemctl --user start %s: %s", unit, strings.trim_space(ran.output))
	}
	return nil
}
