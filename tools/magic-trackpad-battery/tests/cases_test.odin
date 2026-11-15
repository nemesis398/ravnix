// The cases of testdata/cases.txt, one fake system each, through the whole
// command. Every case without "new:" also passed on the Python tool that this
// one replaced (see the header of cases.txt).
package magic_trackpad_battery_tests

import "core:fmt"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:testing"
import tool ".."

CASES :: #load("../testdata/cases.txt", string)

Dev :: struct {
	id, driver, models, uevent, nodes: string,
}

Case :: struct {
	name:    string,
	is_new:  bool,
	args:    []string,
	devs:    [dynamic]Dev,
	answers: map[string]Answer,
	out:     [dynamic]string,
}

// unescape reads \n, \t, \r, \\ and \xNN.
unescape :: proc(s: string) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&b, '\n')
				i += 1
				continue
			case 't':
				strings.write_byte(&b, '\t')
				i += 1
				continue
			case 'r':
				strings.write_byte(&b, '\r')
				i += 1
				continue
			case '\\':
				strings.write_byte(&b, '\\')
				i += 1
				continue
			case 'x':
				if i + 3 < len(s) {
					if v, ok := strconv.parse_uint(s[i + 2:i + 4], 16); ok {
						strings.write_byte(&b, u8(v))
						i += 3
						continue
					}
				}
			}
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

parse_answer :: proc(fields: []string) -> Answer {
	if len(fields) == 1 && fields[0] == "denied" {
		return Answer{kind = .Missing}
	}
	if len(fields) == 1 && fields[0] == "fail" {
		return Answer{kind = .Fails}
	}
	a := Answer{kind = .Report, ret = tool.REPORT_LEN}
	for f, i in fields {
		if strings.has_prefix(f, "ret=") {
			a.ret = strconv.parse_int(f[4:]) or_else -1
		} else if i < 3 {
			v, _ := strconv.parse_uint(f, 16)
			a.bytes[i] = u8(v)
		}
	}
	return a
}

parse_cases :: proc() -> [dynamic]Case {
	cases := make([dynamic]Case)
	text := CASES
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "#") || strings.trim_space(line) == "" {
			continue
		}
		key, _, value := strings.partition(line, ":")
		value = value[1:] if strings.has_prefix(value, " ") else value
		if key == "case" {
			append(&cases, Case{name = value})
			continue
		}
		c := &cases[len(cases) - 1]
		switch key {
		case "new":
			c.is_new = true
		case "args":
			c.args = strings.fields(value)
		case "dev":
			f := strings.split(value, " | ")
			assert(len(f) == 5, line)
			d := Dev{strings.trim_space(f[0]), strings.trim_space(f[1]), strings.trim_space(f[2]), strings.trim_space(f[3]), strings.trim_space(f[4])}
			append(&c.devs, d)
		case "node":
			f := strings.fields(value)
			c.answers[f[0]] = parse_answer(f[1:])
		case "out":
			append(&c.out, unescape(value))
		case:
			panic(line)
		}
	}
	return cases
}

// build makes the devices of the case in the tree.
build :: proc(t: ^testing.T, tree: Tree, c: ^Case) {
	for d in c.devs {
		nodes: []string
		if d.nodes != "-" {
			nodes = strings.split(d.nodes, ",")
		}
		dev := add_device(t, tree, d.id, d.driver if d.driver != "-" else "", ..nodes)
		if d.models != "-" {
			for m, i in strings.split(d.models, ";") {
				ps := fmt.aprintf("%s/power_supply/ps%d", dev, i)
				make_dirs(t, ps)
				switch m {
				case "!":
				case "@":
					make_dirs(t, strings.concatenate({ps, "/model_name"}))
				case:
					write(t, strings.concatenate({ps, "/model_name"}), unescape(m))
				}
			}
		}
		if d.uevent != "-" {
			write(t, strings.concatenate({dev, "/uevent"}), unescape(d.uevent))
		}
	}
}

@(test)
runs_every_case_of_the_file :: proc(t: ^testing.T) {
	cases_arena: virtual.Arena
	_ = virtual.arena_init_growing(&cases_arena)
	defer virtual.arena_destroy(&cases_arena)
	context.allocator = virtual.arena_allocator(&cases_arena)
	cases := parse_cases()
	testing.expect(t, len(cases) > 30, "the case file was not read")

	for &c in cases {
		arena: virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		context.allocator = virtual.arena_allocator(&arena)
		tree := make_tree(t)
		build(t, tree, &c)
		fake := Fake {
			answers = c.answers,
		}
		code, out, err := run_command(&fake, tree, ..c.args)
		want := strings.builder_make()
		for line in c.out {
			strings.write_string(&want, line)
			strings.write_byte(&want, '\n')
		}
		testing.expectf(t, code == 0, "%s: exit %d, stderr %q", c.name, code, err)
		testing.expectf(t, err == "", "%s: stderr %q", c.name, err)
		testing.expectf(t, out == strings.to_string(want), "%s:\n  want %q\n  got  %q", c.name, strings.to_string(want), out)
		remove_tree(tree)
		virtual.arena_destroy(&arena)
		context.allocator = virtual.arena_allocator(&cases_arena)
	}
}
