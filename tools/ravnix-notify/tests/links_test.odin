// parse_link scans from each [ until the scans of a text have looked at more
// than it can need, and then asks the index, which finds where brackets and
// parentheses close in one pass. The two must give the same answers, and are
// compared on random texts built from the pieces that make and break links,
// and on the edges of the length limit. They may differ only at a [ that a
// backslash has made plain, which render_inline never asks about, so those
// are left out. The scan is also compared with parse_link as it was before
// the index, kept here as the reference.
package ravnix_notify_tests

import "core:strings"
import "core:testing"
import notify ".."

// The reference: parse_link as it was before the index, scanning from at.
reference_parse_link :: proc(s: string, at: int) -> (label, href: string, end: int, ok: bool) {
	// The label ends at the matching ].
	depth := 0
	k := at
	close := -1
	for k < len(s) && k - at <= notify.MAX_LINK_PART {
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
	if close < 0 || close == at + 1 || close + 1 >= len(s) || s[close + 1] != '(' {
		return
	}
	label = s[at + 1:close]

	// The address runs to the ) that closes the (, or to a blank.
	start := close + 2
	k = start
	parens := 0
	for k < len(s) && k - start <= notify.MAX_LINK_PART {
		c := s[k]
		if c == '(' {
			parens += 1
		} else if c == ')' {
			if parens == 0 {
				break
			}
			parens -= 1
		} else if notify.is_white(c) || c < 0x20 || c == 0x7f {
			break
		}
		k += 1
	}
	if k >= len(s) || k - start > notify.MAX_LINK_PART {
		return
	}
	href = s[start:k]
	// A title, in quotes, after blanks.
	if s[k] != ')' {
		t := k
		for t < len(s) && notify.is_white(s[t]) {
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
		for k < len(s) && notify.is_white(s[k]) {
			k += 1
		}
		if k >= len(s) || s[k] != ')' {
			return
		}
	}
	if !notify.has_link_scheme(href) {
		return
	}
	return label, href, k + 1, true
}



// compare_all asks the reference, the scan and the index for every [ of s
// that a backslash has not made plain, and counts where they differ.
@(private = "file")
compare_all :: proc(t: ^testing.T, s: string) -> (mismatches: int) {
	indexed: notify.Memo
	indexed.links = notify.link_index_make(s)
	indexed.has_links = true
	defer notify.link_index_destroy(&indexed.links)
	for at in 0 ..< len(s) {
		if s[at] != '[' {
			continue
		}
		backslashes := 0
		for at - 1 - backslashes >= 0 && s[at - 1 - backslashes] == '\\' {
			backslashes += 1
		}
		if backslashes % 2 == 1 {
			continue
		}
		want_label, want_href, want_end, want_ok := reference_parse_link(s, at)
		// A fresh memo for the scan, so that it never gets as far as the index.
		scan: notify.Memo
		for way, got in ([?]string{"the scan", "the index"}) {
			memo := &scan if got == 0 else &indexed
			label, href, end, ok := notify.parse_link(s, at, memo)
			if ok != want_ok || (ok && (label != want_label || href != want_href || end != want_end)) {
				mismatches += 1
				if mismatches <= 3 {
					testing.expectf(
						t,
						false,
						"%q at %d: %s says %v %q %q %d, the reference says %v %q %q %d",
						s[:min(len(s), 80)], at, way, ok, label[:min(len(label), 20)], href[:min(len(href), 20)], end,
						want_ok, want_label[:min(len(want_label), 20)], want_href[:min(len(want_href), 20)], want_end,
					)
				}
			}
		}
	}
	return
}

@(test)
the_index_gives_the_answers_of_a_scan_on_random_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pieces := [?]string {
		"[", "]", "(", ")", "\\", " ", "\n", "\t", "\"", "'", "a", "b c",
		"http://x", "https://y/z", "mailto:q", "ftp://n", "](", "[a](http://b)",
		"[a](http://b \"t\")", "[[", "]]", "((", "))", "\\[", "\\]", "`", "*", "\x01", "\x7f",
	}
	// xorshift64: the same texts on every run.
	state: u64 = 0x9E3779B97F4A7C15
	next :: proc(state: ^u64) -> u64 {
		state^ ~= state^ << 13
		state^ ~= state^ >> 7
		state^ ~= state^ << 17
		return state^
	}
	b := strings.builder_make(context.temp_allocator)
	total, links := 0, 0
	for _ in 0 ..< 60000 {
		strings.builder_reset(&b)
		count := 1 + int(next(&state) % 24)
		for _ in 0 ..< count {
			strings.write_string(&b, pieces[next(&state) % u64(len(pieces))])
		}
		s := strings.to_string(b)
		if compare_all(t, s) > 0 {
			return
		}
		total += 1
		for at in 0 ..< len(s) {
			if s[at] == '[' {
				memo: notify.Memo
				if _, _, _, ok := notify.parse_link(s, at, &memo); ok {
					links += 1
				}
			}
		}
	}
	// The texts must make links often enough for the comparison to mean
	// something.
	testing.expectf(t, links > total / 20, "only %d links in %d texts", links, total)
}

@(test)
the_index_gives_the_answers_of_a_scan_at_the_length_limit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	limit := notify.MAX_LINK_PART
	for label_len in ([?]int{limit - 2, limit - 1, limit, limit + 1}) {
		for href_len in ([?]int{limit - 8, limit - 7, limit - 6, limit - 5, limit - 1, limit, limit + 1}) {
			for escape in 0 ..< 2 {
				label := strings.repeat("a", label_len, context.temp_allocator)
				href := strings.repeat("b", href_len, context.temp_allocator)
				// A backslash at the end of the label's room skips the byte
				// after it, which is a ] that does not close.
				mid := "\\]" if escape == 1 else ""
				s := strings.concatenate({"[", label, mid, "](http://", href, ")"}, context.temp_allocator)
				testing.expectf(t, compare_all(t, s) == 0, "label %d, address %d, escape %d", label_len, href_len, escape)
				// And an address cut by a blank, or by a ( that never closes.
				s2 := strings.concatenate({"[x](http://", href, " ", href, ")"}, context.temp_allocator)
				testing.expectf(t, compare_all(t, s2) == 0, "blank in the address %d", href_len)
				s3 := strings.concatenate({"[x](http://(", href, ")", href, ")"}, context.temp_allocator)
				testing.expectf(t, compare_all(t, s3) == 0, "parens in the address %d", href_len)
			}
		}
	}
}

@(test)
the_index_gives_the_answers_of_a_scan_on_hostile_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n := 3000
	rep :: proc(s: string, n: int) -> string {
		return strings.repeat(s, n, context.temp_allocator)
	}
	cases := [?]string {
		rep("[", n),
		strings.concatenate({rep("[", n), "]"}, context.temp_allocator),
		strings.concatenate({rep("[", n), rep("]", n / 2)}, context.temp_allocator),
		rep("[a](", n),
		rep("[a]((", n),
		strings.concatenate({rep("[a](http://x", n), rep(")", n)}, context.temp_allocator),
		strings.concatenate({rep("[a](http://x(", n), rep(")", n / 2)}, context.temp_allocator),
		rep("[a](http://x \"", n),
		rep("[\\", n),
		rep("](", n),
		rep(")[a](http://x", n),
	}
	for c, i in cases {
		testing.expectf(t, compare_all(t, c) == 0, "case %d", i)
	}
}
