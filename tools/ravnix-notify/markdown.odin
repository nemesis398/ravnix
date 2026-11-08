package ravnix_notify

import "core:strings"

// A small subset of CommonMark, enough for a notification (README.md has the
// list), rendered to the HTML that Matrix allows in formatted_body. It has
// two jobs besides rendering. Whatever the text says, no tag, attribute or
// link of the sender's own comes out: every character that means something
// to HTML is escaped, and a link is made only for http, https and mailto.
// And no text may make it slow or deep: a scan for a closing delimiter
// remembers where it failed, a link is looked for in a bounded stretch, and
// quotes and emphasis nest to a limit, beyond which text stays text.

// How deep quotes and emphasis nest before the rest is taken as text.
MAX_NESTING :: 16

// The longest label and address of a link that is looked for.
MAX_LINK_PART :: 2000

render_markdown :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	// One kind of line break: \r\n and a lone \r become \n.
	norm := strings.builder_make(0, len(text), allocator)
	defer strings.builder_destroy(&norm)
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if c == '\r' {
			if i + 1 < len(text) && text[i + 1] == '\n' {
				continue
			}
			c = '\n'
		}
		strings.write_byte(&norm, c)
	}
	lines := strings.split(strings.to_string(norm), "\n", allocator)
	defer delete(lines, allocator)
	render_blocks(&b, lines, 0, allocator)
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Characters

is_space :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t'
}

// is_white is white space as emphasis sees it: it has a line break too.
is_white :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t' || c == '\n'
}

is_blank :: proc(s: string) -> bool {
	for c in transmute([]byte)s {
		if !is_space(c) {
			return false
		}
	}
	return true
}

// is_word is a character that belongs to a word: a letter or digit, and
// every byte of a multi-byte character.
is_word :: proc(c: byte) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80
}

is_punct :: proc(c: byte) -> bool {
	return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~')
}

count_run :: proc(s: string, at: int, c: byte) -> int {
	n := 0
	for at + n < len(s) && s[at + n] == c {
		n += 1
	}
	return n
}

trim_left_ws :: proc(s: string) -> string {
	i := 0
	for i < len(s) && is_space(s[i]) {
		i += 1
	}
	return s[i:]
}

trim_right_ws :: proc(s: string) -> string {
	n := len(s)
	for n > 0 && is_space(s[n - 1]) {
		n -= 1
	}
	return s[:n]
}

trim_ws :: proc(s: string) -> string {
	return trim_right_ws(trim_left_ws(s))
}

// indent_of is how far the line is indented, a tab being four columns.
indent_of :: proc(line: string) -> int {
	n := 0
	for c in transmute([]byte)line {
		if c == ' ' {
			n += 1
		} else if c == '\t' {
			n += 4
		} else {
			break
		}
	}
	return n
}

write_escaped_byte :: proc(b: ^strings.Builder, c: byte) {
	switch c {
	case '&':
		strings.write_string(b, "&amp;")
	case '<':
		strings.write_string(b, "&lt;")
	case '>':
		strings.write_string(b, "&gt;")
	case '"':
		strings.write_string(b, "&quot;")
	case:
		strings.write_byte(b, c)
	}
}

write_escaped :: proc(b: ^strings.Builder, s: string) {
	for c in transmute([]byte)s {
		write_escaped_byte(b, c)
	}
}

// ---------------------------------------------------------------------------
// Blocks

render_blocks :: proc(b: ^strings.Builder, lines: []string, depth: int, allocator := context.allocator) {
	i := 0
	for i < len(lines) {
		line := lines[i]
		if is_blank(line) {
			i += 1
			continue
		}
		consumed := 0
		if indent_of(line) <= 3 {
			rest := trim_left_ws(line)
			switch {
			case is_fence_open(rest):
				consumed = render_fence(b, lines, i)
			case is_heading(rest):
				render_heading(b, rest)
				consumed = 1
			case is_rule(rest):
				strings.write_string(b, "<hr>")
				consumed = 1
			case rest[0] == '>' && depth < MAX_NESTING:
				consumed = render_quote(b, lines, i, depth, allocator)
			case:
				if _, _, _, ok := list_marker(line, 3); ok {
					consumed = render_list(b, lines, i, allocator)
				}
			}
		}
		if consumed == 0 {
			consumed = render_paragraph(b, lines, i, depth, allocator)
		}
		i += consumed
	}
}

// fence_open is a line that opens a fenced code block: three or more
// backticks or tildes, and for backticks no backtick in the info string.
fence_open :: proc(rest: string) -> (char: byte, length: int, info: string, ok: bool) {
	if len(rest) == 0 || (rest[0] != '`' && rest[0] != '~') {
		return
	}
	char = rest[0]
	length = count_run(rest, 0, char)
	if length < 3 {
		return
	}
	info = trim_ws(rest[length:])
	if char == '`' && strings.contains_rune(info, '`') {
		return
	}
	ok = true
	return
}

is_fence_open :: proc(rest: string) -> bool {
	_, _, _, ok := fence_open(rest)
	return ok
}

// render_fence writes the code block that opens at lines[i] and returns how
// many lines it takes. An unclosed fence runs to the end, as in CommonMark.
render_fence :: proc(b: ^strings.Builder, lines: []string, i: int) -> int {
	indent := indent_of(lines[i])
	char, length, info, _ := fence_open(trim_left_ws(lines[i]))
	j := i + 1
	closed := false
	for ; j < len(lines); j += 1 {
		if indent_of(lines[j]) > 3 {
			continue
		}
		t := trim_left_ws(lines[j])
		if r := count_run(t, 0, char); r >= length && is_blank(t[r:]) {
			closed = true
			break
		}
	}
	strings.write_string(b, "<pre><code")
	// The info string lands in an attribute: only a plain language name
	// gets in.
	lang := info
	if sp := strings.index_byte(lang, ' '); sp >= 0 {
		lang = lang[:sp]
	}
	if is_language(lang) {
		strings.write_string(b, ` class="language-`)
		strings.write_string(b, lang)
		strings.write_string(b, `"`)
	}
	strings.write_string(b, ">")
	for k in i + 1 ..< j {
		l := lines[k]
		strip := indent
		for strip > 0 && len(l) > 0 && l[0] == ' ' {
			l = l[1:]
			strip -= 1
		}
		write_escaped(b, l)
		strings.write_byte(b, '\n')
	}
	strings.write_string(b, "</code></pre>")
	if closed {
		return j + 1 - i
	}
	return j - i
}

is_language :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 32 {
		return false
	}
	for c in transmute([]byte)s {
		if !(is_word(c) && c < 0x80) && c != '_' && c != '+' && c != '#' && c != '.' && c != '-' {
			return false
		}
	}
	return true
}

is_heading :: proc(rest: string) -> bool {
	level := count_run(rest, 0, '#')
	return level >= 1 && level <= 6 && (len(rest) == level || is_space(rest[level]))
}

render_heading :: proc(b: ^strings.Builder, rest: string) {
	level := count_run(rest, 0, '#')
	content := trim_ws(rest[level:])
	// A closing run of # counts only after a blank.
	k := len(content)
	for k > 0 && content[k - 1] == '#' {
		k -= 1
	}
	if k < len(content) && (k == 0 || is_space(content[k - 1])) {
		content = trim_right_ws(content[:k])
	}
	strings.write_string(b, "<h")
	strings.write_byte(b, byte('0' + level))
	strings.write_byte(b, '>')
	render_inline(b, content, 0, false)
	strings.write_string(b, "</h")
	strings.write_byte(b, byte('0' + level))
	strings.write_byte(b, '>')
}

// is_rule is a line of three or more of -, * or _, and blanks between them.
is_rule :: proc(rest: string) -> bool {
	if len(rest) == 0 || (rest[0] != '-' && rest[0] != '*' && rest[0] != '_') {
		return false
	}
	n := 0
	for c in transmute([]byte)rest {
		if c == rest[0] {
			n += 1
		} else if !is_space(c) {
			return false
		}
	}
	return n >= 3
}

render_quote :: proc(b: ^strings.Builder, lines: []string, i, depth: int, allocator := context.allocator) -> int {
	inner := make([dynamic]string, allocator)
	defer delete(inner)
	j := i
	for j < len(lines) {
		t := trim_left_ws(lines[j])
		if indent_of(lines[j]) > 3 || len(t) == 0 || t[0] != '>' {
			break
		}
		t = t[1:]
		if len(t) > 0 && is_space(t[0]) {
			t = t[1:]
		}
		append(&inner, t)
		j += 1
	}
	strings.write_string(b, "<blockquote>")
	render_blocks(b, inner[:], depth + 1, allocator)
	strings.write_string(b, "</blockquote>")
	return j - i
}

List_Kind :: enum {
	Bullet,
	Ordered,
}

// list_marker reads a list item from a line indented at most max_indent: its
// kind, its text after the marker, and its number (an ordered item's). An
// item with no text, and a number of more than nine digits, are no item.
list_marker :: proc(line: string, max_indent: int) -> (kind: List_Kind, content: string, number: int, ok: bool) {
	if indent_of(line) > max_indent {
		return
	}
	rest := trim_left_ws(line)
	if len(rest) >= 2 && (rest[0] == '-' || rest[0] == '*' || rest[0] == '+') && is_space(rest[1]) {
		content = trim_ws(rest[1:])
		return .Bullet, content, 0, content != ""
	}
	digits := 0
	for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' {
		digits += 1
	}
	if digits >= 1 && digits <= 9 && digits + 1 < len(rest) && (rest[digits] == '.' || rest[digits] == ')') && is_space(rest[digits + 1]) {
		for c in transmute([]byte)rest[:digits] {
			number = number * 10 + int(c - '0')
		}
		content = trim_ws(rest[digits + 1:])
		return .Ordered, content, number, content != ""
	}
	return
}

// render_list writes the list that starts at lines[i]: items of one kind in a
// row. A line indented two or more under an item belongs to it. A blank line
// ends the list; there are no nested lists, and a nested item stays text.
render_list :: proc(b: ^strings.Builder, lines: []string, i: int, allocator := context.allocator) -> int {
	kind, content, number, _ := list_marker(lines[i], 3)
	if kind == .Bullet {
		strings.write_string(b, "<ul>")
	} else {
		strings.write_string(b, "<ol")
		if number != 1 {
			strings.write_string(b, ` start="`)
			write_int(b, number)
			strings.write_string(b, `"`)
		}
		strings.write_string(b, ">")
	}
	j := i
	for {
		item := strings.builder_make(allocator)
		strings.write_string(&item, content)
		j += 1
		for j < len(lines) && !is_blank(lines[j]) && indent_of(lines[j]) >= 2 {
			strings.write_byte(&item, '\n')
			strings.write_string(&item, trim_ws(lines[j]))
			j += 1
		}
		strings.write_string(b, "<li>")
		render_inline(b, strings.to_string(item), 0, false)
		strings.write_string(b, "</li>")
		strings.builder_destroy(&item)
		if j < len(lines) {
			if next_kind, next_content, _, ok := list_marker(lines[j], 1); ok && next_kind == kind {
				content = next_content
				continue
			}
		}
		break
	}
	strings.write_string(b, kind == .Bullet ? "</ul>" : "</ol>")
	return j - i
}

write_int :: proc(b: ^strings.Builder, n: int) {
	digits: [20]byte
	i := len(digits)
	v := n
	for {
		i -= 1
		digits[i] = byte('0' + v % 10)
		v /= 10
		if v == 0 {
			break
		}
	}
	strings.write_bytes(b, digits[i:])
}

// interrupts is a line that ends the paragraph above it: another block that
// can start without a blank line before it.
interrupts :: proc(line: string, depth: int) -> bool {
	if indent_of(line) > 3 {
		return false
	}
	rest := trim_left_ws(line)
	if is_fence_open(rest) || is_heading(rest) || is_rule(rest) || (rest[0] == '>' && depth < MAX_NESTING) {
		return true
	}
	kind, _, number, ok := list_marker(line, 3)
	return ok && (kind == .Bullet || number == 1)
}

render_paragraph :: proc(b: ^strings.Builder, lines: []string, i, depth: int, allocator := context.allocator) -> int {
	text := strings.builder_make(allocator)
	defer strings.builder_destroy(&text)
	j := i
	for j < len(lines) && !is_blank(lines[j]) {
		if j > i && interrupts(lines[j], depth) {
			break
		}
		if j > i {
			strings.write_byte(&text, '\n')
		}
		strings.write_string(&text, trim_ws(lines[j]))
		j += 1
	}
	strings.write_string(b, "<p>")
	render_inline(b, strings.to_string(text), 0, false)
	strings.write_string(b, "</p>")
	return j - i
}

// ---------------------------------------------------------------------------
// Inline

// What a scan for a closing delimiter has learned. A closing delimiter does
// not depend on the opener that looks for it, so a search that found none
// from a position finds none from any later one: the position is kept, and
// the next opener is not searched at all. Without it, a line of ten thousand
// openers is ten thousand scans of the line.
Memo :: struct {
	closer_fail: [3][4]int,
	tick_fail:   [32]int,
	// Where the brackets and parentheses close, made when the scans for a
	// link have looked at more of the text than a text of this size can need.
	links:       Link_Index,
	has_links:   bool,
	// How many bytes those scans have looked at.
	link_work:   int,
}

memo_make :: proc() -> (m: Memo) {
	for &row in m.closer_fail {
		for &v in row {
			v = max(int)
		}
	}
	for &v in m.tick_fail {
		v = max(int)
	}
	return
}

// Where the brackets and parentheses of a text close, found in one pass
// each. A link is looked for by scanning from its [, up to MAX_LINK_PART
// bytes, which costs nothing for a message and is quadratic-ish for a text of
// sixty thousand [ (sixty thousand scans of two thousand bytes). So the scans
// count the bytes they look at, and once those pass what a text of this size
// can need (link_work_limit), the index is made and answers every later link
// at once. The answers are those of scanning from each opener, which the
// tests compare them with.
Link_Index :: struct {
	// For a [ at i: where the ] that closes it is, or -1. A backslash makes
	// the byte after it plain.
	bracket_close: []int,
	// For an address that starts at i, which may be len(s): where it ends,
	// at a blank or control character, at the ) that closes the ( it has
	// not opened (the end of the address), or at len(s) when nothing does.
	address_end:   []int,
}

is_address_stop :: proc(c: byte) -> bool {
	return is_white(c) || c < 0x20 || c == 0x7f
}

link_index_make :: proc(s: string) -> (x: Link_Index) {
	n := len(s)
	x.bracket_close = make([]int, n)
	x.address_end = make([]int, n + 1)
	paren_close := make([]int, n)
	defer delete(paren_close)
	stack := make([dynamic]int, 0, 16)
	defer delete(stack)

	for k in 0 ..< n {
		x.bracket_close[k] = -1
		paren_close[k] = -1
	}
	for k := 0; k < n; k += 1 {
		switch s[k] {
		case '\\':
			k += 1
		case '[':
			append(&stack, k)
		case ']':
			if len(stack) > 0 {
				x.bracket_close[pop(&stack)] = k
			}
		}
	}

	// A ( closes at the ) that brings the count back to where it began; a
	// blank ends the address, so nothing is open across one.
	clear(&stack)
	for k in 0 ..< n {
		c := s[k]
		switch {
		case c == '(':
			append(&stack, k)
		case c == ')':
			if len(stack) > 0 {
				paren_close[pop(&stack)] = k
			}
		case is_address_stop(c):
			clear(&stack)
		}
	}

	// From the end: the address that starts at i ends where the one that
	// starts after its first byte does, unless that byte ends it, or opens
	// a ( (the address goes on after the ) that closes it, or without
	// end to the next blank).
	x.address_end[n] = n
	next_stop := n
	for k := n - 1; k >= 0; k -= 1 {
		c := s[k]
		if is_address_stop(c) {
			next_stop = k
		}
		switch {
		case is_address_stop(c) || c == ')':
			x.address_end[k] = k
		case c == '(':
			if paren_close[k] >= 0 {
				x.address_end[k] = x.address_end[paren_close[k] + 1]
			} else {
				x.address_end[k] = next_stop
			}
		case:
			x.address_end[k] = x.address_end[k + 1]
		}
	}
	return
}

link_index_destroy :: proc(x: ^Link_Index) {
	delete(x.bracket_close)
	delete(x.address_end)
}

// find_tick_close is where the backtick run of exactly the given length that
// closes a code span begins after from, or -1.
find_tick_close :: proc(s: string, from, run: int, memo: ^Memo) -> int {
	if run < len(memo.tick_fail) && from >= memo.tick_fail[run] {
		return -1
	}
	k := from
	for k < len(s) {
		if s[k] == '`' {
			r := count_run(s, k, '`')
			if r == run {
				return k
			}
			k += r
		} else {
			k += 1
		}
	}
	if run < len(memo.tick_fail) {
		memo.tick_fail[run] = min(memo.tick_fail[run], from)
	}
	return -1
}

delimiter_index :: proc(c: byte) -> int {
	switch c {
	case '*':
		return 0
	case '_':
		return 1
	}
	return 2
}

// find_closer is where the delimiter run that closes an emphasis begins: a
// run of exactly m of c, after at least one character, not preceded by
// white space, and for _ not followed by a word character. Code spans and
// escaped characters are skipped.
find_closer :: proc(s: string, from: int, c: byte, m: int, memo: ^Memo) -> int {
	kind := delimiter_index(c)
	if from >= memo.closer_fail[kind][m] {
		return -1
	}
	k := from
	for k < len(s) {
		x := s[k]
		switch {
		case x == '\\':
			k += 2
		case x == '`':
			run := count_run(s, k, '`')
			if end := find_tick_close(s, k + run, run, memo); end >= 0 {
				k = end + run
			} else {
				k += run
			}
		case x == c:
			r := count_run(s, k, c)
			if r == m && k > from && !is_white(s[k - 1]) && (c != '_' || k + r >= len(s) || !is_word(s[k + r])) {
				return k
			}
			k += r
		case:
			k += 1
		}
	}
	memo.closer_fail[kind][m] = min(memo.closer_fail[kind][m], from)
	return -1
}

// render_inline writes text with its code spans, emphasis, links and line
// breaks. depth is how deep emphasis and link labels have nested; in_link is
// true inside a link's label, where a link is not made again.
render_inline :: proc(b: ^strings.Builder, s: string, depth: int, in_link: bool) {
	memo := memo_make()
	defer if memo.has_links {
		link_index_destroy(&memo.links)
	}
	n := len(s)
	i := 0
	for i < n {
		c := s[i]
		switch c {
		case '\n':
			strings.write_string(b, "<br>")
			i += 1
		case '\\':
			// A backslash before a [ is taken here, so parse_link is never
			// asked about an escaped [ (see the assert there).
			if i + 1 < n && is_punct(s[i + 1]) {
				write_escaped_byte(b, s[i + 1])
				i += 2
			} else {
				strings.write_byte(b, '\\')
				i += 1
			}
		case '`':
			run := count_run(s, i, '`')
			if end := find_tick_close(s, i + run, run, &memo); end >= 0 {
				write_code_span(b, s[i + run:end])
				i = end + run
			} else {
				for _ in 0 ..< run {
					strings.write_byte(b, '`')
				}
				i += run
			}
		case '[':
			if !in_link && depth < MAX_NESTING {
				if label, href, end, ok := parse_link(s, i, &memo); ok {
					strings.write_string(b, `<a href="`)
					write_escaped(b, href)
					strings.write_string(b, `">`)
					render_inline(b, label, depth + 1, true)
					strings.write_string(b, "</a>")
					i = end
					continue
				}
			}
			strings.write_byte(b, '[')
			i += 1
		case '*', '_', '~':
			run := count_run(s, i, c)
			m := min(run, 3)
			if c == '~' {
				m = 2 if run == 2 else 0
			}
			if m > 0 && depth < MAX_NESTING && i + run < n && !is_white(s[i + run]) && (c != '_' || i == 0 || !is_word(s[i - 1])) {
				start := i + run
				if j := find_closer(s, start, c, m, &memo); j >= 0 {
					for _ in 0 ..< run - m {
						strings.write_byte(b, c)
					}
					write_open_tags(b, c, m)
					render_inline(b, s[start:j], depth + 1, in_link)
					write_close_tags(b, c, m)
					i = j + m
					continue
				}
			}
			for _ in 0 ..< run {
				strings.write_byte(b, c)
			}
			i += run
		case:
			write_escaped_byte(b, c)
			i += 1
		}
	}
}

write_open_tags :: proc(b: ^strings.Builder, c: byte, m: int) {
	switch {
	case c == '~':
		strings.write_string(b, "<del>")
	case m == 1:
		strings.write_string(b, "<em>")
	case m == 2:
		strings.write_string(b, "<strong>")
	case:
		strings.write_string(b, "<strong><em>")
	}
}

write_close_tags :: proc(b: ^strings.Builder, c: byte, m: int) {
	switch {
	case c == '~':
		strings.write_string(b, "</del>")
	case m == 1:
		strings.write_string(b, "</em>")
	case m == 2:
		strings.write_string(b, "</strong>")
	case:
		strings.write_string(b, "</em></strong>")
	}
}

// write_code_span writes the text between two backtick runs: line breaks are
// blanks, and one blank at each end goes, unless the text is nothing else.
write_code_span :: proc(b: ^strings.Builder, code: string) {
	text := code
	if len(text) >= 2 && (text[0] == ' ' || text[0] == '\n') && (text[len(text) - 1] == ' ' || text[len(text) - 1] == '\n') && !is_all_white(text) {
		text = text[1:len(text) - 1]
	}
	strings.write_string(b, "<code>")
	for c in transmute([]byte)text {
		write_escaped_byte(b, ' ' if c == '\n' else c)
	}
	strings.write_string(b, "</code>")
}

is_all_white :: proc(s: string) -> bool {
	for c in transmute([]byte)s {
		if !is_white(c) {
			return false
		}
	}
	return true
}

// link_work_limit is how many bytes the scans for links may look at in a
// text before the index is made: a few passes over the text, and a floor for
// short ones. A message with links in it never gets near.
link_work_limit :: proc(s: string) -> int {
	return 4 * len(s) + 4096
}

// scan_label is where the ] that closes the [ at s[at] is, or -1, looking
// at most MAX_LINK_PART bytes ahead. looked is how many bytes it read.
scan_label :: proc(s: string, at: int) -> (close, looked: int) {
	depth := 0
	k := at
	close = -1
	for k < len(s) && k - at <= MAX_LINK_PART {
		switch s[k] {
		case '\\':
			k += 1
		case '[':
			depth += 1
		case ']':
			depth -= 1
			if depth == 0 {
				close = k
			}
		}
		if close >= 0 {
			break
		}
		k += 1
	}
	return close, k - at
}

// scan_address is where the address that starts at s[start] ends: at a
// blank or control character, at the ) that closes no ( of the address, or
// where MAX_LINK_PART bytes are over (the result is then past the limit).
scan_address :: proc(s: string, start: int) -> (k, looked: int) {
	k = start
	parens := 0
	for k < len(s) && k - start <= MAX_LINK_PART {
		c := s[k]
		if c == '(' {
			parens += 1
		} else if c == ')' {
			if parens == 0 {
				break
			}
			parens -= 1
		} else if is_address_stop(c) {
			break
		}
		k += 1
	}
	return k, k - start
}

// parse_link reads [label](address) at s[at]. The address is a run without
// blanks, with balanced parentheses, and must be an http, https or mailto
// address; a title after it is accepted and dropped. Anything else is no
// link: the caller writes the text as it is. The label and the address are
// each at most MAX_LINK_PART bytes. It scans from the [, until the scans of
// this text have looked at more than link_work_limit bytes, and asks the
// index after that. The index scans from the start of s, which is the same
// as scanning from at, because at is no escaped byte (a backslash before a
// [ is an escape, and render_inline does not come here for it).
parse_link :: proc(s: string, at: int, memo: ^Memo) -> (label, href: string, end: int, ok: bool) {
	if !memo.has_links && memo.link_work > link_work_limit(s) {
		memo.links = link_index_make(s)
		memo.has_links = true
	}

	// The label ends at the matching ].
	close: int
	if memo.has_links {
		// The index counts a backslash and the byte after it as a pair from
		// the start of the text, the scan from at. They agree only if the [
		// at at is no escaped byte. render_inline holds that by taking a
		// backslash before a [ as an escape (is_punct has the [), and this
		// checks it: the backslashes right before at must come in pairs. The
		// runs before two different [ do not overlap, so all the checks of a
		// text cost one pass.
		backslashes := 0
		for at - 1 - backslashes >= 0 && s[at - 1 - backslashes] == '\\' {
			backslashes += 1
		}
		assert(backslashes % 2 == 0, "parse_link: asked about a [ that a backslash escapes")
		close = memo.links.bracket_close[at]
		if close - at > MAX_LINK_PART {
			close = -1
		}
	} else {
		looked: int
		close, looked = scan_label(s, at)
		memo.link_work += looked
	}
	if close < 0 || close == at + 1 || close + 1 >= len(s) || s[close + 1] != '(' {
		return
	}
	label = s[at + 1:close]

	// The address runs to the ) that closes the (, or to a blank.
	start := close + 2
	k: int
	if memo.has_links {
		k = memo.links.address_end[start]
	} else {
		looked: int
		k, looked = scan_address(s, start)
		memo.link_work += looked
	}
	if k >= len(s) || k - start > MAX_LINK_PART {
		return
	}
	href = s[start:k]
	// A title, in quotes, after blanks.
	if s[k] != ')' {
		t := k
		for t < len(s) && is_white(s[t]) {
			t += 1
		}
		if t == k || t >= len(s) || (s[t] != '"' && s[t] != '\'') {
			return
		}
		q := strings.index_byte(s[t + 1:], s[t])
		if q < 0 || t + 1 + q + 1 >= len(s) {
			return
		}
		k = t + 1 + q + 1
		for k < len(s) && is_white(s[k]) {
			k += 1
		}
		if k >= len(s) || s[k] != ')' {
			return
		}
	}
	if !has_link_scheme(href) {
		return
	}
	return label, href, k + 1, true
}

// has_link_scheme is an address of a scheme the Matrix specification lets a
// link have, and that does nothing on a click but open a page or a mail.
has_link_scheme :: proc(href: string) -> bool {
	for scheme in ([?]string{"http://", "https://", "mailto:"}) {
		if len(href) > len(scheme) && strings.equal_fold(href[:len(scheme)], scheme) {
			return true
		}
	}
	return false
}
