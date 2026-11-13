// A flake's lock file, as far as the update needs it: which nodes belong to
// one input (the input's node and every node only it reaches), whether a
// second lock moved them and nothing else about them, and a copy of one
// lock with another's nodes for that input put in.
//
// What may move. Within the input's nodes, only `locked`'s rev, narHash,
// lastModified and revCount may change: the same repository at another
// revision. A new `original`, another owner or repository or URL in
// `locked`, an input added or taken away, another node shape, or a node
// that some other input reaches as well, is refused, because a lock that
// does any of these points the build somewhere else than the flake.nix
// that was deployed says.
//
// What these rules cannot say is whether the revision is the upstream's:
// GitHub serves a commit of any fork under the upstream's own URL, so a
// lock that passes them can still name a fork's commit. That is why root
// on the laptop runs `nix flake update` itself instead of taking the
// revision from the server's lock (update.odin).
package claude_roll

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

Lock :: struct {
	value: json.Object,
	nodes: json.Object,
	root:  string,
}

// The keys of `locked` that a new revision changes.
@(rodata)
MOVING_KEYS := [?]string{"rev", "narHash", "lastModified", "revCount"}

// A lock file larger than this is no lock file anyone wrote.
MAX_LOCK :: 4 << 20
// Nor one that nests deeper: a lock's values are four levels deep. The
// parser recurses once per level, and root reads a lock the user wrote.
MAX_NESTING :: 64

parse_lock :: proc(data: []byte, allocator: runtime.Allocator) -> (l: Lock, err: string) {
	if len(data) == 0 {
		return l, "the lock file is empty"
	}
	if len(data) > MAX_LOCK {
		return l, "the lock file is larger than 4 MiB"
	}
	if !nesting_within(data, MAX_NESTING) {
		return l, "the lock file nests deeper than any lock does"
	}
	v, e := json.parse(data, .JSON, true, allocator)
	if e != .None {
		return l, fmt.aprintf("the lock file is not JSON (%v)", e, allocator = allocator)
	}
	obj, is_obj := v.(json.Object)
	if !is_obj {
		return l, "the lock file is not a JSON object"
	}
	nodes, has_nodes := obj["nodes"].(json.Object)
	root, has_root := obj["root"].(json.String)
	if !has_nodes || !has_root {
		return l, "the lock file has no nodes or no root"
	}
	if _, ok := nodes[root].(json.Object); !ok {
		return l, "the lock file's root node is missing"
	}
	return {obj, nodes, root}, ""
}

// node_inputs is a node's inputs object; a node without one has none.
node_inputs :: proc(l: Lock, name: string) -> (inputs: json.Object, ok: bool) {
	node, is_node := l.nodes[name].(json.Object)
	if !is_node {
		return nil, false
	}
	if node["inputs"] == nil {
		return nil, true
	}
	inputs, ok = node["inputs"].(json.Object)
	return
}

// input_node is the node the root's input points at. An input that follows
// another (a list) has no node of its own, and is refused.
input_node :: proc(l: Lock, input: string) -> (name: string, err: string) {
	inputs, ok := node_inputs(l, l.root)
	if !ok {
		return "", "the root node's inputs are not an object"
	}
	v, has := inputs[input]
	if !has {
		return "", fmt.tprintf("the flake has no input %q", input)
	}
	s, is_s := v.(json.String)
	if !is_s {
		return "", fmt.tprintf("the input %q follows another input and has no node of its own", input)
	}
	if _, is_node := l.nodes[s].(json.Object); !is_node {
		return "", fmt.tprintf("the input %q points at a node %q that is not there", input, s)
	}
	return s, ""
}

// input_rev is the revision the lock holds the input at: its node's
// locked.rev, "" when there is none.
input_rev :: proc(l: Lock, input: string) -> string {
	name, err := input_node(l, input)
	if err != "" {
		return ""
	}
	node := l.nodes[name].(json.Object)
	locked, _ := node["locked"].(json.Object)
	rev, _ := locked["rev"].(json.String)
	return rev
}

// reach is every node reached from start through inputs that name a node,
// start included, but never through the node skip. A list (an input that
// follows a path) names no node and is not walked.
reach :: proc(l: Lock, start, skip: string, allocator: runtime.Allocator) -> (seen: map[string]bool, err: string) {
	seen = make(map[string]bool, allocator)
	queue := make([dynamic]string, allocator)
	append(&queue, start)
	seen[start] = true
	for len(queue) > 0 {
		name := pop(&queue)
		inputs, ok := node_inputs(l, name)
		if !ok {
			return seen, fmt.tprintf("the node %q is missing or has inputs that are not an object", name)
		}
		for _, v in inputs {
			#partial switch ref in v {
			case json.String:
				if ref == skip || seen[ref] {
					continue
				}
				if _, is_node := l.nodes[ref].(json.Object); !is_node {
					return seen, fmt.tprintf("the node %q names a node %q that is not there", name, ref)
				}
				seen[ref] = true
				append(&queue, ref)
			case json.Array:
			case:
				return seen, fmt.tprintf("the node %q has an input that is neither a node nor a path", name)
			}
		}
	}
	return seen, ""
}

// input_nodes is the input's node and every node that only it reaches, in
// sorted order. A node the input reaches that the root also reaches some
// other way is shared, and refused: moving it would move another input.
input_nodes :: proc(l: Lock, input: string, allocator: runtime.Allocator) -> (names: []string, err: string) {
	start, e := input_node(l, input)
	if e != "" {
		return nil, e
	}
	own, e2 := reach(l, start, "", allocator)
	if e2 != "" {
		return nil, e2
	}
	others, e3 := reach(l, l.root, start, allocator)
	if e3 != "" {
		return nil, e3
	}
	list := make([dynamic]string, allocator)
	for name in own {
		if name == l.root || others[name] {
			return nil, fmt.tprintf("the node %q of the input %q is also used by another input", name, input)
		}
		append(&list, name)
	}
	slice.sort(list[:])
	return list[:], ""
}

// compare_input says whether new moved the input's nodes of old, and
// refuses a new that changes them in any other way. Nodes outside the
// input are not looked at.
compare_input :: proc(old, new: Lock, input: string, allocator: runtime.Allocator) -> (moved: bool, names: []string, err: string) {
	old_names, e := input_nodes(old, input, allocator)
	if e != "" {
		return false, nil, fmt.tprintf("the deployed lock: %s", e)
	}
	new_names, e2 := input_nodes(new, input, allocator)
	if e2 != "" {
		return false, nil, fmt.tprintf("the new lock: %s", e2)
	}
	old_start, _ := input_node(old, input)
	new_start, _ := input_node(new, input)
	if old_start != new_start || !slice.equal(old_names, new_names) {
		return false, nil, fmt.tprintf("the input %q has other nodes in the new lock (%s, was %s)", input, strings.join(new_names, ", ", allocator), strings.join(old_names, ", ", allocator))
	}
	for name in old_names {
		a := old.nodes[name].(json.Object)
		b := new.nodes[name].(json.Object)
		if !same_keys(a, b) {
			return false, nil, fmt.tprintf("the node %q has other fields in the new lock", name)
		}
		for key, av in a {
			if key == "locked" {
				continue
			}
			if !json_equal(av, b[key]) {
				return false, nil, fmt.tprintf("the node %q has another %s in the new lock", name, key)
			}
		}
		la, la_ok := a["locked"].(json.Object)
		lb, lb_ok := b["locked"].(json.Object)
		if la_ok != lb_ok || (a["locked"] != nil && !la_ok) {
			return false, nil, fmt.tprintf("the node %q's locked is not an object", name)
		}
		if !la_ok {
			continue
		}
		if !same_keys(la, lb) {
			return false, nil, fmt.tprintf("the node %q is locked by other fields in the new lock", name)
		}
		for key, av in la {
			if json_equal(av, lb[key]) {
				continue
			}
			if !slice.contains(MOVING_KEYS[:], key) {
				return false, nil, fmt.tprintf("the node %q is locked to another %s in the new lock", name, key)
			}
			moved = true
		}
	}
	return moved, old_names, ""
}

// others_equal says whether old and new are the same lock outside names:
// the same root, version and every other node.
others_equal :: proc(old, new: Lock, names: []string) -> (differs: string, equal: bool) {
	if old.root != new.root {
		return "root", false
	}
	if !json_equal(old.value["version"], new.value["version"]) {
		return "version", false
	}
	for key in old.value {
		if key != "nodes" && !json_equal(old.value[key], new.value[key]) {
			return key, false
		}
	}
	if len(old.value) != len(new.value) {
		return "the top level", false
	}
	for name, v in old.nodes {
		if slice.contains(names, name) {
			continue
		}
		if !json_equal(v, new.nodes[name]) {
			return name, false
		}
	}
	for name in new.nodes {
		if !slice.contains(names, name) && old.nodes[name] == nil {
			return name, false
		}
	}
	return "", true
}

// splice is base with from's nodes of names in their place, as JSON text.
splice :: proc(base, from: Lock, names: []string, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	keys := sorted_keys(base.value, allocator)
	strings.write_byte(&b, '{')
	for key, i in keys {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		write_json_string(&b, key)
		strings.write_byte(&b, ':')
		if key != "nodes" {
			write_json(&b, base.value[key], allocator)
			continue
		}
		strings.write_byte(&b, '{')
		for name, j in sorted_keys(base.nodes, allocator) {
			if j > 0 {
				strings.write_byte(&b, ',')
			}
			write_json_string(&b, name)
			strings.write_byte(&b, ':')
			if slice.contains(names, name) {
				write_json(&b, from.nodes[name], allocator)
			} else {
				write_json(&b, base.nodes[name], allocator)
			}
		}
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

json_equal :: proc(a, b: json.Value) -> bool {
	switch x in a {
	case json.Null:
		_, ok := b.(json.Null)
		return ok
	case json.Integer:
		y, ok := b.(json.Integer)
		return ok && x == y
	case json.Float:
		y, ok := b.(json.Float)
		return ok && x == y
	case json.Boolean:
		y, ok := b.(json.Boolean)
		return ok && x == y
	case json.String:
		y, ok := b.(json.String)
		return ok && x == y
	case json.Array:
		y, ok := b.(json.Array)
		if !ok || len(x) != len(y) {
			return false
		}
		for v, i in x {
			if !json_equal(v, y[i]) {
				return false
			}
		}
		return true
	case json.Object:
		y, ok := b.(json.Object)
		if !ok || !same_keys(x, y) {
			return false
		}
		for k, v in x {
			if !json_equal(v, y[k]) {
				return false
			}
		}
		return true
	}
	return b == nil
}

same_keys :: proc(a, b: json.Object) -> bool {
	if len(a) != len(b) {
		return false
	}
	for k in a {
		if _, has := b[k]; !has {
			return false
		}
	}
	return true
}

sorted_keys :: proc(o: json.Object, allocator: runtime.Allocator) -> []string {
	keys := make([dynamic]string, 0, len(o), allocator)
	for k in o {
		append(&keys, k)
	}
	slice.sort(keys[:])
	return keys[:]
}

write_json :: proc(b: ^strings.Builder, v: json.Value, allocator: runtime.Allocator) {
	switch x in v {
	case json.Null:
		strings.write_string(b, "null")
	case json.Integer:
		strings.write_i64(b, x)
	case json.Float:
		buf: [64]byte
		strings.write_string(b, strconv.write_float(buf[:], x, 'g', -1, 64))
	case json.Boolean:
		strings.write_string(b, "true" if x else "false")
	case json.String:
		write_json_string(b, x)
	case json.Array:
		strings.write_byte(b, '[')
		for e, i in x {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			write_json(b, e, allocator)
		}
		strings.write_byte(b, ']')
	case json.Object:
		strings.write_byte(b, '{')
		for k, i in sorted_keys(x, allocator) {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			write_json_string(b, k)
			strings.write_byte(b, ':')
			write_json(b, x[k], allocator)
		}
		strings.write_byte(b, '}')
	case:
		strings.write_string(b, "null")
	}
}

write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\t':
			strings.write_string(b, `\t`)
		case '\r':
			strings.write_string(b, `\r`)
		case 0 ..< 0x20, 0x7f:
			fmt.sbprintf(b, `\u%04x`, c)
		case:
			strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}

// json_value is the whole lock as one JSON value.
json_value :: proc(l: Lock) -> json.Value {
	return l.value
}

// nesting_within says whether the brackets outside strings nest no deeper
// than limit. It only bounds the parser's recursion; the parser refuses
// what is not JSON.
nesting_within :: proc(data: []byte, limit: int) -> bool {
	depth := 0
	in_string, escaped := false, false
	for c in data {
		switch {
		case in_string:
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				in_string = false
			}
		case c == '"':
			in_string = true
		case c == '{' || c == '[':
			depth += 1
			if depth > limit {
				return false
			}
		case c == '}' || c == ']':
			depth -= 1
		}
	}
	return true
}
