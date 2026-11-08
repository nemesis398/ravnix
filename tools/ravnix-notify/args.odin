package ravnix_notify

import "base:runtime"
import "core:fmt"
import "core:strings"

// Where the config is when --config does not say. nixosModules.glue writes
// it (modules/glue/notify.nix).
DEFAULT_CONFIG :: "/etc/ravnix/notify.json"

USAGE :: `usage: ravnix-notify --topic TOPIC [--config FILE] [--dry-run] MESSAGE...
       ravnix-notify --topic TOPIC [--config FILE] [--dry-run] -`

HELP :: USAGE + `

Posts MESSAGE to the Matrix room of TOPIC, as that topic's bot. The words of
MESSAGE are joined with blanks; a lone - reads the message from standard input.
The message is Markdown (bold, italic, code, links, lists, headings, quotes)
and goes out as the event's formatted_body, with the text itself as its body.

  --topic TOPIC   the topic: its room and bot are in the config
  --config FILE   the config file (default: ` + DEFAULT_CONFIG + `)
  --dry-run       print the request, send nothing, ask rbw for nothing
  --              the rest is the message, whatever it looks like

The bot's access token is read from Bitwarden with rbw when the message goes
out; it is never on a command line, in a file or in a log.

How long it takes: up to 4 tries of 20 seconds each (timeoutSecs in the
config), 7 seconds of waiting between them, and 30 seconds for each of the two
rbw calls (rbwTimeoutMs): about 90 seconds against a homeserver that does not
answer, up to 250 with one that keeps asking to wait. A caller with a shorter
timeout, a hook say, runs it in the background (ravnix-notify ... &) or lowers
those two keys; one that is killed in the middle writes no journal line.

Exit status: 0 sent; 64 bad usage or an unknown topic; 65 the message is too
large for an event; 69 no usable token, or rbw or curl cannot run; 74 the
message on standard input could not be read to its end; 75 the vault is
locked, or the homeserver stayed out of reach after three retries; 76 the
homeserver's answer is no success and no retry will change it; 77 it refused
the token; 78 the config is missing or wrong, or the topic has no room.`

Args :: struct {
	topic:       string,
	config_path: string,
	message:     string,
	// The message is on standard input.
	from_stdin:  bool,
	dry_run:     bool,
	help:        bool,
}

// parse_args reads the arguments after the program's name. err says what is
// wrong, "" when nothing is. Strings are allocated with allocator.
parse_args :: proc(args: []string, allocator := context.allocator) -> (a: Args, err: string) {
	a.config_path = DEFAULT_CONFIG
	words := make([dynamic]string, allocator)
	defer delete(words)
	have_topic, have_config, only_words := false, false, false

	take_value :: proc(args: []string, i: ^int, name: string, allocator: runtime.Allocator) -> (value: string, err: string) {
		eq := len(name)
		if len(args[i^]) > eq {
			// --name=value
			value = args[i^][eq + 1:]
		} else if i^ + 1 < len(args) {
			i^ += 1
			value = args[i^]
		} else {
			return "", fmt.aprintf("%s needs a value", name, allocator = allocator)
		}
		if value == "" {
			return "", fmt.aprintf("%s is empty", name, allocator = allocator)
		}
		return value, ""
	}

	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch {
		case only_words:
			append(&words, arg)
		case arg == "--":
			only_words = true
		case arg == "-h" || arg == "--help":
			a.help = true
			return
		case arg == "--dry-run":
			a.dry_run = true
		case arg == "--topic" || strings.has_prefix(arg, "--topic="):
			if have_topic {
				return a, fmt.aprintf("--topic is given twice", allocator = allocator)
			}
			have_topic = true
			a.topic, err = take_value(args, &i, "--topic", allocator)
			if err != "" {
				return
			}
		case arg == "--config" || strings.has_prefix(arg, "--config="):
			if have_config {
				return a, fmt.aprintf("--config is given twice", allocator = allocator)
			}
			have_config = true
			a.config_path, err = take_value(args, &i, "--config", allocator)
			if err != "" {
				return
			}
		case len(arg) > 1 && arg[0] == '-':
			return a, fmt.aprintf("unknown option %s", arg, allocator = allocator)
		case:
			append(&words, arg)
		}
	}
	if !have_topic {
		return a, fmt.aprintf("--topic is missing", allocator = allocator)
	}
	if len(words) == 1 && words[0] == "-" && !only_words {
		a.from_stdin = true
		return
	}
	a.message = strings.trim_space(strings.join(words[:], " ", allocator))
	if a.message == "" {
		return a, fmt.aprintf("there is no message", allocator = allocator)
	}
	return
}
