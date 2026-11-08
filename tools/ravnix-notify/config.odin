package ravnix_notify

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// The curl that sends the request. default.nix sets it to curl's store path;
// a bare name is looked up on PATH. Odin's core has no TLS, and a homeserver
// is reached over https.
CURL :: #config(CURL, "curl")

DEFAULT_RETRY_BASE_MS :: 1000
DEFAULT_TIMEOUT_SECS :: 20.0
DEFAULT_RBW_TIMEOUT_MS :: 30000

// Room is what the config says of a topic. room_id is "" for a room that
// does not exist yet.
Room :: struct {
	room_id:    string,
	token_item: string,
}

// Config is modules/glue/notify.nix's notify.json.
Config :: struct {
	homeserver:     string,
	rbw:            string,
	curl:           string,
	rooms:          map[string]Room,
	retry_base_ms:  int,
	timeout_secs:   f64,
	rbw_timeout_ms: int,
}

// parse_config reads the config's JSON. err names the key that is wrong,
// and is "" when nothing is. The strings of cfg belong to the tree the JSON
// parser built with allocator, so allocator should be an arena or a
// temporary allocator that is freed as a whole.
parse_config :: proc(data: []byte, allocator := context.allocator) -> (cfg: Config, err: string) {
	value, perr := json.parse(data, parse_integers = true, allocator = allocator)
	if perr != .None {
		return cfg, fmt.aprintf("it is not valid JSON (%v)", perr, allocator = allocator)
	}
	root, is_obj := value.(json.Object)
	if !is_obj {
		return cfg, fmt.aprintf("it is not a JSON object", allocator = allocator)
	}

	homeserver, e1 := string_key(root, "homeserver", allocator)
	if e1 != "" {
		return cfg, e1
	}
	scheme_len := 0
	for scheme in ([?]string{"https://", "http://"}) {
		if strings.has_prefix(homeserver, scheme) {
			scheme_len = len(scheme)
			break
		}
	}
	homeserver = strings.trim_right(homeserver, "/")
	if scheme_len == 0 || len(homeserver) <= scheme_len || has_unquotable(homeserver, true) {
		return cfg, fmt.aprintf("homeserver is not an http or https address without blanks, quotes or control characters", allocator = allocator)
	}
	cfg.homeserver = homeserver

	cfg.rbw, err = string_key(root, "rbw", allocator)
	if err != "" {
		return
	}
	cfg.curl = CURL
	if _, present := root["curl"]; present {
		cfg.curl, err = string_key(root, "curl", allocator)
		if err != "" {
			return
		}
	}

	cfg.retry_base_ms = DEFAULT_RETRY_BASE_MS
	if v, present := root["retryBaseMs"]; present {
		n, is_int := v.(json.Integer)
		if !is_int || n < 0 || n > 60000 {
			return cfg, fmt.aprintf("retryBaseMs is not a whole number of milliseconds from 0 to 60000", allocator = allocator)
		}
		cfg.retry_base_ms = int(n)
	}
	cfg.timeout_secs = DEFAULT_TIMEOUT_SECS
	if v, present := root["timeoutSecs"]; present {
		secs: f64
		#partial switch n in v {
		case json.Integer:
			secs = f64(n)
		case json.Float:
			secs = f64(n)
		}
		if !(secs > 0 && secs <= 600) {
			return cfg, fmt.aprintf("timeoutSecs is not a number of seconds above 0 and up to 600", allocator = allocator)
		}
		cfg.timeout_secs = secs
	}
	cfg.rbw_timeout_ms = DEFAULT_RBW_TIMEOUT_MS
	if v, present := root["rbwTimeoutMs"]; present {
		n, is_int := v.(json.Integer)
		if !is_int || n < 1 || n > 600000 {
			return cfg, fmt.aprintf("rbwTimeoutMs is not a whole number of milliseconds from 1 to 600000", allocator = allocator)
		}
		cfg.rbw_timeout_ms = int(n)
	}

	rooms_value, has_rooms := root["rooms"]
	rooms, rooms_ok := rooms_value.(json.Object)
	if !has_rooms || !rooms_ok {
		return cfg, fmt.aprintf("rooms is not an object of topics", allocator = allocator)
	}
	cfg.rooms = make(map[string]Room, allocator)
	for topic, room_value in rooms {
		where_ := fmt.aprintf("rooms.%s", topic, allocator = allocator)
		room, is_room := room_value.(json.Object)
		if !is_room {
			return cfg, fmt.aprintf("%s is not an object", where_, allocator = allocator)
		}
		r: Room
		r.token_item, err = string_key(room, "tokenItem", allocator, where_)
		if err != "" {
			return
		}
		#partial switch id in room["roomId"] {
		case json.String:
			r.room_id = string(id)
			if len(r.room_id) < 2 || r.room_id[0] != '!' || has_unquotable(r.room_id, true) {
				return cfg, fmt.aprintf("%s.roomId is not a room id (! and no blanks)", where_, allocator = allocator)
			}
		case json.Null, nil:
		case:
			return cfg, fmt.aprintf("%s.roomId is neither a room id nor null", where_, allocator = allocator)
		}
		cfg.rooms[topic] = r
	}
	return
}

// string_key is the non-empty string root[key]. where_ names the object the
// key is in, for the message.
string_key :: proc(root: json.Object, key: string, allocator := context.allocator, where_ := "") -> (value: string, err: string) {
	name := key if where_ == "" else fmt.aprintf("%s.%s", where_, key, allocator = allocator)
	v, present := root[key]
	s, is_str := v.(json.String)
	if !present || !is_str || len(s) == 0 || has_unquotable(string(s), false) {
		return "", fmt.aprintf("%s is not a string, or is empty or holds a control character", name, allocator = allocator)
	}
	return string(s), ""
}

// has_unquotable is a control character in s, and with strict also a blank
// or a quote or backslash: what must not be in a value that goes into curl's
// config or a URL as it is.
has_unquotable :: proc(s: string, strict: bool) -> bool {
	for c in transmute([]byte)s {
		if c < 0x20 || c == 0x7f || (strict && (c == ' ' || c == '"' || c == '\\')) {
			return true
		}
	}
	return false
}
