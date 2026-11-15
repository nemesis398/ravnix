// sway-game-mode: holds sway in mode "game" while a game window has focus.
// README.md has the why; modules/desktop/sway.nix runs it as a user service.
//
//   sway-game-mode            watch, until SIGTERM or SIGINT (exit 0) or
//                             until sway goes away (exit 1)
//   sway-game-mode --leave    leave mode "game" if sway is in it, and exit
//
// It talks to sway itself, over the IPC socket (ipc.odin), and runs no other
// program.
package sway_game_mode

import "core:fmt"
import "core:os"
import "core:sys/linux"
import "core:time"

USAGE :: `usage: sway-game-mode [--leave] [--socket PATH]

Holds sway in mode "game" while a game window has focus, and puts it back
into "default" and the cursor hiding of the sway config when focus goes
anywhere else. SIGTERM and SIGINT leave "game" and exit 0.

  --leave        leave mode "game" if sway is in it, and exit; 0 also when
                 there is no sway (the unit's ExecStopPost runs it)
  --socket PATH  sway's IPC socket (default $SWAYSOCK, then $I3SOCK)

Exit status: 0 stopped (or --leave done), 1 sway went away or broke the
protocol, 2 bad usage.`

// How long sway may take to answer one request. It answers in microseconds;
// a Sway that does not answer in this time is hung, and the unit restarts us.
REQUEST_TIMEOUT :: 10 * time.Second

Env :: struct {
	swaysock: string,
	i3sock:   string,
}

Options :: struct {
	leave:  bool,
	help:   bool,
	socket: string,
}

parse_args :: proc(args: []string) -> (o: Options, why: string) {
	has_socket := false
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-h", "--help":
			o.help = true
		case "--leave":
			o.leave = true
		case "--socket":
			if i + 1 >= len(args) {
				return {}, "--socket needs a value"
			}
			if has_socket {
				return {}, "--socket given twice"
			}
			has_socket = true
			o.socket = args[i + 1]
			i += 1
		case:
			return {}, fmt.tprintf("unknown argument %q", args[i])
		}
	}
	return o, ""
}

// socket_path is where sway's socket is, as swaymsg finds it: SWAYSOCK, then
// I3SOCK.
socket_path :: proc(o: Options, env: Env) -> string {
	switch {
	case o.socket != "":
		return o.socket
	case env.swaysock != "":
		return env.swaysock
	}
	return env.i3sock
}

cli :: proc(args: []string, env: Env, stop: linux.Fd, timeout: time.Duration, stderr: ^os.File) -> int {
	o, why := parse_args(args)
	if why != "" {
		fmt.fprintfln(stderr, "sway-game-mode: %s\n%s", why, USAGE)
		return 2
	}
	if o.help {
		fmt.fprintln(stderr, USAGE)
		return 0
	}
	cfg := Config {
		socket  = socket_path(o, env),
		stop    = stop,
		timeout = timeout,
		log     = stderr,
	}
	if cfg.socket == "" {
		// Nothing to leave without a sway; nothing to watch either.
		say(cfg, "no sway socket: SWAYSOCK is not set (use --socket)")
		return 0 if o.leave else 1
	}
	if o.leave {
		return leave_if_game(cfg)
	}
	return watch(cfg)
}

// stop_fd is the descriptor the signal handler writes to; the watcher polls
// it next to the sockets, so a signal ends a wait at once and the work of
// leaving "game" runs in the main flow, not in the handler.
stop_fd: linux.Fd = -1

on_signal :: proc "c" (sig: linux.Signal) {
	one := u64(1)
	linux.write(stop_fd, (cast(^[8]u8)&one)[:])
}

install_signals :: proc() -> bool {
	fd, e := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if e != .NONE {
		return false
	}
	stop_fd = fd
	for sig in ([?]linux.Signal{.SIGTERM, .SIGINT}) {
		act := linux.Sig_Action {
			handler = on_signal,
		}
		if linux.rt_sigaction(sig, &act, nil) != .NONE {
			return false
		}
	}
	return true
}

main :: proc() {
	if !install_signals() {
		fmt.eprintln("sway-game-mode: cannot install the signal handlers")
		os.exit(1)
	}
	env := Env {
		swaysock = os.get_env("SWAYSOCK", context.allocator),
		i3sock   = os.get_env("I3SOCK", context.allocator),
	}
	os.exit(cli(os.args[1:], env, stop_fd, REQUEST_TIMEOUT, os.stderr))
}
