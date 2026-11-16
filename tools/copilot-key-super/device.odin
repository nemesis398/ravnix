// The devices: finding the keyboard by name in sysfs, the ioctls of evdev and
// uinput, and the daemon's start: the virtual device first, then the grab.
package copilot_key_super

import "core:fmt"
import "core:io"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/linux"

// The keyboard, by name and never by event number: /dev/input/eventN is not
// stable across boots.
KEYBOARD_NAME :: "AT Translated Set 2 keyboard"

// The virtual device. Sway's config names it as 1:1:copilot-key-super
// (vendor, product, name), so these three must not change.
VIRTUAL_NAME :: "copilot-key-super"
VIRTUAL_VENDOR :: 1
VIRTUAL_PRODUCT :: 1
VIRTUAL_VERSION :: 1

// A sysfs name is far shorter; reading stops here, and a longer one is no
// match.
MAX_NAME_BYTES :: 512

// The start polls the keyboard's keys until none is down before it grabs
// (wait_keys_up): every WAIT_STEP_NS for the first WAIT_FAST_NS, then at a
// doubling interval up to WAIT_MAX_NS, so a key that stays down costs one
// wakeup a second. It says so after WAIT_FAST_NS, and every WAIT_NOTICE_NS
// after that.
WAIT_STEP_NS :: 10_000_000
WAIT_FAST_NS :: 1_000_000_000
WAIT_MAX_NS :: 1_000_000_000
WAIT_NOTICE_NS :: 60_000_000_000
// The notice names at most this many key codes.
WAIT_NAMED_KEYS :: 8

Find_Error :: enum {
	None,
	No_Memory, // no arena for the listing
	No_Input_Class, // ROOT/sys/class/input cannot be listed
	Not_Found, // no eventN there has the name
}

// event_number is N of an entry named eventN, or -1.
event_number :: proc(entry: string) -> int {
	if !strings.has_prefix(entry, "event") {
		return -1
	}
	digits := entry[len("event"):]
	if len(digits) == 0 || len(digits) > 9 {
		return -1
	}
	n := 0
	for c in transmute([]u8)digits {
		if c < '0' || c > '9' {
			return -1
		}
		n = n * 10 + int(c - '0')
	}
	return n
}

// read_name reads a sysfs name file without its one trailing newline. A file
// that cannot be read, or is longer than MAX_NAME_BYTES, gives ok false.
read_name :: proc(path: string, buf: []u8) -> (name: string, ok: bool) {
	f, err := os.open(path)
	if err != nil {
		return "", false
	}
	defer os.close(f)
	have := 0
	for have < len(buf) {
		n, rerr := os.read(f, buf[have:])
		if n <= 0 || rerr != nil {
			break
		}
		have += n
	}
	if have == len(buf) {
		return "", false
	}
	s := string(buf[:have])
	return strings.trim_suffix(s, "\n"), true
}

// find_keyboard returns the N of the lowest /sys/class/input/eventN under
// root whose device is named name.
find_keyboard :: proc(root, name: string) -> (number: int, err: Find_Error) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return -1, .No_Memory
	}
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)

	class := strings.concatenate({root, "/sys/class/input"}, a)
	entries, lerr := os.read_all_directory_by_path(class, a)
	if lerr != nil {
		return -1, .No_Input_Class
	}
	number = -1
	buf: [MAX_NAME_BYTES]u8
	for entry in entries {
		n := event_number(entry.name)
		if n < 0 || (number >= 0 && n >= number) {
			continue
		}
		got, ok := read_name(strings.concatenate({class, "/", entry.name, "/device/name"}, a), buf[:])
		if ok && got == name {
			number = n
		}
	}
	if number < 0 {
		return -1, .Not_Found
	}
	return number, .None
}

// Input_Id is struct input_id of linux/input.h.
Input_Id :: struct {
	bustype: u16,
	vendor:  u16,
	product: u16,
	version: u16,
}

// Uinput_Setup is struct uinput_setup of linux/uinput.h.
Uinput_Setup :: struct {
	id:             Input_Id,
	name:           [80]u8,
	ff_effects_max: u32,
}
#assert(size_of(Input_Id) == 8)
#assert(size_of(Uinput_Setup) == 92)

IOC_WRITE :: 1
IOC_READ :: 2

// ioc is the kernel's _IOC(dir, type, nr, size) of linux/ioctl.h: nr in bits
// 0-7, type in 8-15, size in 16-29, direction in 30-31.
ioc :: proc "contextless" (direction: u32, letter: u8, nr: u32, size: u32) -> u32 {
	return direction << 30 | size << 16 | u32(letter) << 8 | nr
}

// linux/input.h
eviocgrab :: proc "contextless" () -> u32 {return ioc(IOC_WRITE, 'E', 0x90, size_of(i32))}
eviocgname :: proc "contextless" (length: u32) -> u32 {return ioc(IOC_READ, 'E', 0x06, length)}
eviocgid :: proc "contextless" () -> u32 {return ioc(IOC_READ, 'E', 0x02, size_of(Input_Id))}
eviocgbit :: proc "contextless" (type: u32, length: u32) -> u32 {return ioc(IOC_READ, 'E', 0x20 + type, length)}
eviocgkey :: proc "contextless" (length: u32) -> u32 {return ioc(IOC_READ, 'E', 0x18, length)}
eviocsclockid :: proc "contextless" () -> u32 {return ioc(IOC_WRITE, 'E', 0xa0, size_of(i32))}
// linux/uinput.h
ui_set_evbit :: proc "contextless" () -> u32 {return ioc(IOC_WRITE, 'U', 100, size_of(i32))}
ui_set_keybit :: proc "contextless" () -> u32 {return ioc(IOC_WRITE, 'U', 101, size_of(i32))}
ui_set_mscbit :: proc "contextless" () -> u32 {return ioc(IOC_WRITE, 'U', 104, size_of(i32))}
ui_set_ledbit :: proc "contextless" () -> u32 {return ioc(IOC_WRITE, 'U', 105, size_of(i32))}
ui_set_phys :: proc "contextless" () -> u32 {return ioc(IOC_WRITE, 'U', 108, size_of(rawptr))}
ui_dev_setup :: proc "contextless" () -> u32 {return ioc(IOC_WRITE, 'U', 3, size_of(Uinput_Setup))}
ui_dev_create :: proc "contextless" () -> u32 {return ioc(0, 'U', 1, 0)}

// virtual_setup is what UI_DEV_SETUP gets: the keyboard's own bus, so that
// libinput sorts the virtual device as the same kind of keyboard (a PS/2 one
// is an internal keyboard, which the touchpad's disable-while-typing and the
// lid switch pair with), and the vendor, product and name Sway looks for.
virtual_setup :: proc "contextless" (bustype: u16) -> Uinput_Setup {
	s := Uinput_Setup {
		id = {bustype = bustype, vendor = VIRTUAL_VENDOR, product = VIRTUAL_PRODUCT, version = VIRTUAL_VERSION},
	}
	name := VIRTUAL_NAME
	#assert(len(VIRTUAL_NAME) < len(s.name))
	for i in 0 ..< len(name) {
		s.name[i] = name[i]
	}
	return s
}

// An Ioctl is call, or a stand-in in the tests.
Ioctl :: #type proc(fd: linux.Fd, request: u32, arg: uintptr) -> linux.Errno

// call runs an ioctl and returns its errno.
call :: proc(fd: linux.Fd, request: u32, arg: uintptr) -> linux.Errno {
	ret := int(linux.ioctl(fd, request, arg))
	if ret < 0 {
		return linux.Errno(-ret)
	}
	return .NONE
}

// held_keys is the daemon's Held_Reader: EVIOCGKEY.
held_keys :: proc(fd: linux.Fd, held: ^Key_Bits) -> linux.Errno {
	return call(fd, eviocgkey(size_of(Key_Bits)), uintptr(held))
}

// Caps is what the keyboard can send, as EVIOCGBIT reads it.
Caps :: struct {
	id:     Input_Id,
	types:  u32,
	keys:   Key_Bits,
	mscs:   u8,
	leds:   u16,
}

#assert(EV_CNT / 8 == size_of(u32))
#assert(MSC_CNT / 8 == size_of(u8))
#assert(LED_CNT / 8 == size_of(u16))

read_caps :: proc(fd: linux.Fd) -> (caps: Caps, errno: linux.Errno) {
	call(fd, eviocgid(), uintptr(&caps.id)) or_return
	call(fd, eviocgbit(0, size_of(caps.types)), uintptr(&caps.types)) or_return
	call(fd, eviocgbit(EV_KEY, size_of(caps.keys)), uintptr(&caps.keys)) or_return
	if caps.types & (1 << EV_MSC) != 0 {
		call(fd, eviocgbit(EV_MSC, size_of(caps.mscs)), uintptr(&caps.mscs)) or_return
	}
	if caps.types & (1 << EV_LED) != 0 {
		call(fd, eviocgbit(EV_LED, size_of(caps.leds)), uintptr(&caps.leds)) or_return
	}
	return caps, .NONE
}

// create_virtual makes the virtual keyboard on an open /dev/uinput, through
// ioctl (call, or a stand-in in the tests, which have no /dev/uinput): the
// keys, scancodes and LEDs the keyboard has (as the Python copied them), the
// two keys the filter writes itself, and no EV_REP, so the kernel does not
// repeat keys on its own: the keyboard's repeats are forwarded instead.
create_virtual :: proc(ui: linux.Fd, caps: ^Caps, ioctl: Ioctl = call) -> linux.Errno {
	ioctl(ui, ui_set_evbit(), EV_KEY) or_return
	keys := caps.keys
	set_bit(&keys, KEY_LEFTSHIFT, true)
	set_bit(&keys, KEY_LEFTMETA, true)
	for code in u16(0) ..< KEY_CNT {
		if bit(&keys, code) {
			ioctl(ui, ui_set_keybit(), uintptr(code)) or_return
		}
	}
	if caps.types & (1 << EV_MSC) != 0 {
		ioctl(ui, ui_set_evbit(), EV_MSC) or_return
		for code in u32(0) ..< MSC_CNT {
			if caps.mscs & (1 << code) != 0 {
				ioctl(ui, ui_set_mscbit(), uintptr(code)) or_return
			}
		}
	}
	if caps.types & (1 << EV_LED) != 0 {
		ioctl(ui, ui_set_evbit(), EV_LED) or_return
		for code in u32(0) ..< LED_CNT {
			if caps.leds & (1 << code) != 0 {
				ioctl(ui, ui_set_ledbit(), uintptr(code)) or_return
			}
		}
	}
	phys: cstring = VIRTUAL_NAME
	ioctl(ui, ui_set_phys(), uintptr(rawptr(phys))) or_return
	setup := virtual_setup(caps.id.bustype)
	ioctl(ui, ui_dev_setup(), uintptr(&setup)) or_return
	return ioctl(ui, ui_dev_create(), 0)
}

// A Sleeper sleeps ns nanoseconds: nanosleep, or a stand-in in the tests.
Sleeper :: #type proc(ns: i64)

nanosleep :: proc(ns: i64) {
	step := linux.Time_Spec{time_sec = uint(ns / 1_000_000_000), time_nsec = uint(ns % 1_000_000_000)}
	linux.nanosleep(&step, nil)
}

// wait_keys_up waits, before the grab, until no key of the keyboard is down,
// for as long as that takes: a key held across the grab would stay down for
// whoever saw its press, and without the grab the keyboard works as it does
// stock, so waiting is the safe state. It polls as the WAIT_ constants say
// and names the codes still down in its notice, so a stuck key shows in the
// journal. It holds nothing a stop has to wait for: SIGTERM ends it in its
// sleep. A failed EVIOCGKEY ends the wait with its errno. The time waited is
// the sum of the sleeps asked for, so the tests' sleep can take none.
wait_keys_up :: proc(fd: linux.Fd, held: Held_Reader, sleep: Sleeper, err: io.Writer) -> linux.Errno {
	waited: i64 = 0
	notice: i64 = WAIT_FAST_NS
	step: i64 = WAIT_STEP_NS
	for {
		keys: Key_Bits
		held(fd, &keys) or_return
		if !any_down(&keys) {
			return .NONE
		}
		if waited >= notice {
			fmt.wprint(err, "copilot-key-super: the grab waits until every key is up; still down:")
			named := 0
			for code in u16(0) ..< KEY_CNT {
				if !bit(&keys, code) {
					continue
				}
				if named == WAIT_NAMED_KEYS {
					fmt.wprint(err, " ...")
					break
				}
				fmt.wprintf(err, " %d", code)
				named += 1
			}
			fmt.wprintln(err)
			notice += WAIT_NOTICE_NS
		}
		sleep(step)
		waited += step
		if waited >= WAIT_FAST_NS {
			step = min(step * 2, WAIT_MAX_NS)
		}
	}
}

// daemon is the command without --filter. Every step that fails ends it with
// 1, before the grab or after it; the kernel then gives the keyboard back.
daemon :: proc(root: string, err: io.Writer) -> int {
	number, ferr := find_keyboard(root, KEYBOARD_NAME)
	switch ferr {
	case .None:
	case .No_Memory:
		fmt.wprintln(err, "copilot-key-super: there is no memory to list the input devices")
		return 1
	case .No_Input_Class:
		fmt.wprintfln(err, "copilot-key-super: cannot list %s/sys/class/input", root)
		return 1
	case .Not_Found:
		fmt.wprintfln(err, "copilot-key-super: no input device named %q", KEYBOARD_NAME)
		return 1
	}

	path := fmt.tprintf("%s/dev/input/event%d", root, number)
	kbd, oerr := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {.CLOEXEC})
	if oerr != .NONE {
		fmt.wprintfln(err, "copilot-key-super: cannot open %s: %v", path, oerr)
		return 1
	}
	kbd_open := true
	defer if kbd_open {linux.close(kbd)}

	// The node is the keyboard still, and not one renumbered since sysfs was
	// read.
	name: [256]u8
	if e := call(kbd, eviocgname(len(name) - 1), uintptr(&name)); e != .NONE {
		if e == .ENOTTY || e == .EINVAL {
			fmt.wprintfln(err, "copilot-key-super: %s is not an input device", path)
		} else {
			fmt.wprintfln(err, "copilot-key-super: cannot read the name of %s: %v", path, e)
		}
		return 1
	}
	if got := string(cstring(&name[0])); got != KEYBOARD_NAME {
		fmt.wprintfln(err, "copilot-key-super: %s is %q now, not the keyboard", path, got)
		return 1
	}

	// The window is measured on the events' times: on the monotonic clock
	// they cannot step back. Without it the realtime clock is used, which a
	// step back only makes miss one macro (translate checks the order).
	monotonic: i32 = i32(linux.Clock_Id.MONOTONIC)
	if e := call(kbd, eviocsclockid(), uintptr(&monotonic)); e != .NONE {
		fmt.wprintfln(err, "copilot-key-super: %s keeps the realtime clock: %v", path, e)
	}

	caps, cerr := read_caps(kbd)
	if cerr != .NONE {
		fmt.wprintfln(err, "copilot-key-super: cannot read what %s sends: %v", path, cerr)
		return 1
	}

	uinput := fmt.tprintf("%s/dev/uinput", root)
	ui, uerr := linux.open(strings.clone_to_cstring(uinput, context.temp_allocator), {.WRONLY, .CLOEXEC})
	if uerr != .NONE {
		fmt.wprintfln(err, "copilot-key-super: cannot open %s: %v", uinput, uerr)
		return 1
	}
	ui_open := true
	defer if ui_open {linux.close(ui)}
	if e := create_virtual(ui, &caps); e != .NONE {
		fmt.wprintfln(err, "copilot-key-super: cannot create the virtual keyboard: %v", e)
		return 1
	}

	if e := wait_keys_up(kbd, held_keys, nanosleep, err); e != .NONE {
		fmt.wprintfln(err, "copilot-key-super: cannot read the keys of %s: %v", path, e)
		return 1
	}
	// Nothing goes to standard error while the grab is held: it is the
	// journal's socket, and a write there blocks when journald does not
	// read, which would hang the daemon with the keyboard in its hands. So
	// the line comes before the grab, and a failure closes both devices
	// (which ends the grab and the virtual keyboard) before it says why.
	fmt.wprintfln(err, "copilot-key-super: grabbing %s, its events go to %s", path, VIRTUAL_NAME)
	if e := call(kbd, eviocgrab(), 1); e != .NONE {
		fmt.wprintfln(err, "copilot-key-super: cannot grab %s: %v", path, e)
		return 1
	}

	t: Translator
	result := pump(&t, kbd, ui, read_fd, write_fd, held_keys)
	linux.close(ui)
	linux.close(kbd)
	ui_open, kbd_open = false, false
	switch result.stop {
	case .Ended:
		fmt.wprintfln(err, "copilot-key-super: %s ended", path)
	case .Gone:
		fmt.wprintfln(err, "copilot-key-super: %s is gone", path)
	case .Read_Failed:
		fmt.wprintfln(err, "copilot-key-super: cannot read %s: %v", path, result.errno)
	case .Write_Failed:
		fmt.wprintfln(err, "copilot-key-super: cannot write to %s: %v", uinput, result.errno)
	case .Resync_Failed:
		fmt.wprintfln(err, "copilot-key-super: cannot read the keys of %s after lost events: %v", path, result.errno)
	}
	// The daemon only ever stops on a failure, and systemd restarts it on
	// one.
	return 1
}
