// The tests of the Markdown renderer: the subset that formatted_body gets
// (README.md), and what must never come out of it. The input is a message
// from any script, so every case that could let it write HTML of its own, or
// hang the renderer, is a test.
package ravnix_notify_tests

import "core:strings"
import "core:testing"
import "core:time"
import notify ".."

// renders expects that text becomes want.
expect_html :: proc(t: ^testing.T, text, want: string, loc := #caller_location) {
	got := notify.render_markdown(text)
	defer delete(got)
	testing.expectf(t, got == want, "render_markdown(%q)\n got: %s\nwant: %s", text, got, want, loc = loc)
}

@(test)
renders_a_paragraph :: proc(t: ^testing.T) {
	expect_html(t, "hello", "<p>hello</p>")
	expect_html(t, "  hello  ", "<p>hello</p>")
	expect_html(t, "one\n\ntwo", "<p>one</p><p>two</p>")
}

@(test)
renders_nothing_for_nothing :: proc(t: ^testing.T) {
	expect_html(t, "", "")
	expect_html(t, " \n\n\t \n", "")
}

@(test)
keeps_line_breaks :: proc(t: ^testing.T) {
	// A notification is read as typed: a new line is a new line.
	expect_html(t, "build failed\nsee the log", "<p>build failed<br>see the log</p>")
	expect_html(t, "a\r\nb\r\n\r\nc", "<p>a<br>b</p><p>c</p>")
	expect_html(t, "a  \nb", "<p>a<br>b</p>")
}

@(test)
escapes_html :: proc(t: ^testing.T) {
	expect_html(t, "a < b & c > \"d\"", "<p>a &lt; b &amp; c &gt; &quot;d&quot;</p>")
	expect_html(t, "<script>alert(1)</script>", "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>")
	expect_html(t, "<img src=x onerror=alert(1)>", "<p>&lt;img src=x onerror=alert(1)&gt;</p>")
	expect_html(t, "&amp; &lt;b&gt;", "<p>&amp;amp; &amp;lt;b&amp;gt;</p>")
	expect_html(t, "`<b>`", "<p><code>&lt;b&gt;</code></p>")
	expect_html(t, "```\n<b>x</b>\n```", "<pre><code>&lt;b&gt;x&lt;/b&gt;\n</code></pre>")
	expect_html(t, "# <u>h</u>", "<h1>&lt;u&gt;h&lt;/u&gt;</h1>")
	expect_html(t, "- <i>x</i>", "<ul><li>&lt;i&gt;x&lt;/i&gt;</li></ul>")
	expect_html(t, "> <b>x</b>", "<blockquote><p>&lt;b&gt;x&lt;/b&gt;</p></blockquote>")
}

@(test)
renders_emphasis_and_code :: proc(t: ^testing.T) {
	expect_html(t, "**bold** and *it* and `code` and ~~gone~~",
		"<p><strong>bold</strong> and <em>it</em> and <code>code</code> and <del>gone</del></p>")
	expect_html(t, "__bold__ and _it_", "<p><strong>bold</strong> and <em>it</em></p>")
	expect_html(t, "***both***", "<p><strong><em>both</em></strong></p>")
	expect_html(t, "**a *b* c**", "<p><strong>a <em>b</em> c</strong></p>")
	expect_html(t, "**bold `code`**", "<p><strong>bold <code>code</code></strong></p>")
	expect_html(t, "`a **b** c`", "<p><code>a **b** c</code></p>")
	expect_html(t, "``a ` b``", "<p><code>a ` b</code></p>")
	expect_html(t, "` pad `", "<p><code>pad</code></p>")
	expect_html(t, "2*3*4", "<p>2<em>3</em>4</p>")
}

@(test)
leaves_what_is_not_emphasis :: proc(t: ^testing.T) {
	expect_html(t, "snake_case_name", "<p>snake_case_name</p>")
	expect_html(t, "foo__bar__baz", "<p>foo__bar__baz</p>")
	expect_html(t, "a * b * c", "<p>a * b * c</p>")
	expect_html(t, "**unclosed", "<p>**unclosed</p>")
	expect_html(t, "unclosed*", "<p>unclosed*</p>")
	expect_html(t, "`unclosed", "<p>`unclosed</p>")
	expect_html(t, "~single~", "<p>~single~</p>")
	expect_html(t, "a ** b", "<p>a ** b</p>")
	expect_html(t, "a ****", "<p>a ****</p>")
	expect_html(t, "a **** b", "<p>a **** b</p>")
	expect_html(t, "5 > 3 and 2 < 4", "<p>5 &gt; 3 and 2 &lt; 4</p>")
}

@(test)
honors_backslash_escapes :: proc(t: ^testing.T) {
	expect_html(t, `\*not bold\*`, "<p>*not bold*</p>")
	expect_html(t, "\\`not code\\`", "<p>`not code`</p>")
	expect_html(t, `\\ and \a and \`, `<p>\ and \a and \</p>`)
	expect_html(t, `\[x\](https://example.org)`, "<p>[x](https://example.org)</p>")
}

@(test)
renders_links_with_a_known_scheme :: proc(t: ^testing.T) {
	expect_html(t, "[the log](https://example.org/log)", `<p><a href="https://example.org/log">the log</a></p>`)
	expect_html(t, "[a](http://example.org/)", `<p><a href="http://example.org/">a</a></p>`)
	expect_html(t, "[mail](mailto:alice@example.org)", `<p><a href="mailto:alice@example.org">mail</a></p>`)
	expect_html(t, "[**x**](https://example.org)", `<p><a href="https://example.org"><strong>x</strong></a></p>`)
	// The URL is an attribute: & and a quote cannot leave it.
	expect_html(t, "[q](https://example.org/?a=1&b=2)", `<p><a href="https://example.org/?a=1&amp;b=2">q</a></p>`)
	expect_html(t, `[q](https://example.org/"onmouseover="x)`, `<p><a href="https://example.org/&quot;onmouseover=&quot;x">q</a></p>`)
	expect_html(t, "[wiki](https://example.org/a_(b))", `<p><a href="https://example.org/a_(b)">wiki</a></p>`)
	expect_html(t, "see [a](https://example.org) and [b](https://example.net)",
		`<p>see <a href="https://example.org">a</a> and <a href="https://example.net">b</a></p>`)
}

@(test)
refuses_links_with_another_scheme :: proc(t: ^testing.T) {
	// A scheme the Matrix specification does not allow, or one that runs
	// code, is shown as the text it is, never as a link.
	expect_html(t, "[x](javascript:alert(1))", "<p>[x](javascript:alert(1))</p>")
	expect_html(t, "[x](JavaScript:alert(1))", "<p>[x](JavaScript:alert(1))</p>")
	expect_html(t, "[x](data:text/html,<b>)", "<p>[x](data:text/html,&lt;b&gt;)</p>")
	expect_html(t, "[x](file:///etc/passwd)", "<p>[x](file:///etc/passwd)</p>")
	expect_html(t, "[x](//example.org)", "<p>[x](//example.org)</p>")
	expect_html(t, "[x](relative/path)", "<p>[x](relative/path)</p>")
	expect_html(t, "[x](https://a b)", "<p>[x](https://a b)</p>")
	expect_html(t, "[x]()", "<p>[x]()</p>")
	expect_html(t, "[x] (https://example.org)", "<p>[x] (https://example.org)</p>")
	expect_html(t, "[x](https://example.org", "<p>[x](https://example.org</p>")
	expect_html(t, "[](https://example.org)", "<p>[](https://example.org)</p>")
}

@(test)
renders_headings :: proc(t: ^testing.T) {
	expect_html(t, "# Title\ntext", "<h1>Title</h1><p>text</p>")
	expect_html(t, "###### Six", "<h6>Six</h6>")
	expect_html(t, "## With **bold** ##", "<h2>With <strong>bold</strong></h2>")
	// Seven hashes, or none and a space, are no heading.
	expect_html(t, "####### Seven", "<p>####### Seven</p>")
	expect_html(t, "#hashtag", "<p>#hashtag</p>")
	expect_html(t, "#", "<h1></h1>")
}

@(test)
renders_lists :: proc(t: ^testing.T) {
	expect_html(t, "- a\n- b", "<ul><li>a</li><li>b</li></ul>")
	expect_html(t, "* a\n+ b", "<ul><li>a</li><li>b</li></ul>")
	expect_html(t, "1. a\n2. b", "<ol><li>a</li><li>b</li></ol>")
	expect_html(t, "3) a\n4) b", `<ol start="3"><li>a</li><li>b</li></ol>`)
	expect_html(t, "- **a** `b`\n- [c](https://example.org)", `<ul><li><strong>a</strong> <code>b</code></li><li><a href="https://example.org">c</a></li></ul>`)
	expect_html(t, "Failed:\n- one\n- two", "<p>Failed:</p><ul><li>one</li><li>two</li></ul>")
	expect_html(t, "- a\n  more\n- b", "<ul><li>a<br>more</li><li>b</li></ul>")
	expect_html(t, "-a", "<p>-a</p>")
	expect_html(t, "2 - 1", "<p>2 - 1</p>")
	expect_html(t, "- a\n\ntext", "<ul><li>a</li></ul><p>text</p>")
	// More digits than a list number has are text.
	expect_html(t, "1234567890. x", "<p>1234567890. x</p>")
}

@(test)
renders_code_blocks :: proc(t: ^testing.T) {
	expect_html(t, "```\nls -l\n```", "<pre><code>ls -l\n</code></pre>")
	expect_html(t, "```sh\necho **hi**\n```", "<pre><code class=\"language-sh\">echo **hi**\n</code></pre>")
	expect_html(t, "~~~\nx\n~~~", "<pre><code>x\n</code></pre>")
	expect_html(t, "```\na\n\n\nb\n```", "<pre><code>a\n\n\nb\n</code></pre>")
	// An unclosed fence runs to the end, as in CommonMark.
	expect_html(t, "```\nx\ny", "<pre><code>x\ny\n</code></pre>")
	expect_html(t, "```\n```", "<pre><code></code></pre>")
	// The info string is an attribute: only a plain language name gets in.
	expect_html(t, "```\"><script>\nx\n```", "<pre><code>x\n</code></pre>")
	expect_html(t, "text\n```\ncode\n```\nafter", "<p>text</p><pre><code>code\n</code></pre><p>after</p>")
	expect_html(t, "````\n```\n````", "<pre><code>```\n</code></pre>")
}

@(test)
renders_quotes_and_rules :: proc(t: ^testing.T) {
	expect_html(t, "> quoted\n> more", "<blockquote><p>quoted<br>more</p></blockquote>")
	expect_html(t, ">tight", "<blockquote><p>tight</p></blockquote>")
	expect_html(t, "> a\n>\n> b", "<blockquote><p>a</p><p>b</p></blockquote>")
	expect_html(t, "> > deep", "<blockquote><blockquote><p>deep</p></blockquote></blockquote>")
	expect_html(t, "---", "<hr>")
	expect_html(t, "a\n***\nb", "<p>a</p><hr><p>b</p>")
	expect_html(t, "--", "<p>--</p>")
	expect_html(t, "* * *", "<hr>")
	expect_html(t, "****", "<hr>")
	expect_html(t, "_ _ _", "<hr>")
}

@(test)
survives_text_that_is_not_markdown_at_all :: proc(t: ^testing.T) {
	// A log excerpt, with a stack of characters Markdown means something by.
	expect_html(t, "error: [E0] at src/x.rs:3:4 -> *ptr = 0;",
		"<p>error: [E0] at src/x.rs:3:4 -&gt; *ptr = 0;</p>")
	expect_html(t, "日本語 *強調* und ümläut", "<p>日本語 <em>強調</em> und ümläut</p>")
	expect_html(t, "emoji 🎉 `ok`", "<p>emoji 🎉 <code>ok</code></p>")
	// A NUL or another control byte is the encoder's to escape, not this
	// renderer's to drop.
	expect_html(t, "a\x00b\x01c", "<p>a\x00b\x01c</p>")
}

@(test)
terminates_on_hostile_input :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Each of these once made a naive renderer quadratic or recursive
	// without bound. The size is that of the longest message the tool
	// renders (an event holds 60 000 bytes), and each case has a budget of
	// its own: one quadratic path of 60 000 steps squared takes seconds, and
	// would hide in a budget shared by two dozen cases.
	n := notify.MAX_EVENT_BYTES
	rep :: proc(s: string, n: int) -> string {
		return strings.repeat(s, n, context.temp_allocator)
	}
	Case :: struct {
		text:   string,
		budget: time.Duration,
	}
	QUICK :: 100 * time.Millisecond
	cases := [?]Case {
		{rep("*", n), QUICK},
		{rep("**a ", n / 4), QUICK},
		{rep("`", n), QUICK},
		{rep("`a``", n / 4), QUICK},
		{rep("[", n), QUICK},
		{rep("[a](", n / 4), QUICK},
		{strings.concatenate({rep("[", n - 1), "]"}, context.temp_allocator), QUICK},
		{rep("[a]((", n / 5), QUICK},
		// An escaped [ between openers: the index must give the answers of the
		// scan past it, and parse_link asserts it is never asked about the
		// escaped one (a mutation of is_punct trips it through here).
		{rep("[\\", n / 2), QUICK},
		{rep("[[\\", n / 3), QUICK},
		{strings.concatenate({rep("[a](http://x(", n / 14), rep(")", n / 14)}, context.temp_allocator), QUICK},
		{rep("[a](http://x \"", n / 14), QUICK},
		{rep("*a ", n / 3), QUICK},
		{rep("_a ", n / 3), QUICK},
		{rep("~~a ", n / 4), QUICK},
		{rep("> ", n / 2), QUICK},
		{rep("> a\n", n / 4), QUICK},
		{rep("- ", n / 2), QUICK},
		{rep("1. a\n", n / 5), QUICK},
		{strings.concatenate({rep("*", n / 2), "a", rep("*", n / 2)}, context.temp_allocator), QUICK},
		{strings.concatenate({rep("(", n / 2), rep(")", n / 2)}, context.temp_allocator), QUICK},
		{rep("\\", n), QUICK},
		{rep("# ", n / 2), QUICK},
		{rep("a_", n / 2), QUICK},
		{rep("*a*", n / 3), QUICK},
		{rep("[a]", n / 3), QUICK},
		{rep("\n", n), QUICK},
		{rep("```\n", n / 4), QUICK},
	}
	for c, i in cases {
		started := time.tick_now()
		html := notify.render_markdown(c.text)
		elapsed := time.tick_diff(started, time.tick_now())
		delete(html)
		testing.expectf(t, elapsed < c.budget, "case %d (%d bytes, %q...) took %v, the budget is %v", i, len(c.text), c.text[:min(len(c.text), 12)], elapsed, c.budget)
	}
}

@(test)
a_link_after_thousands_of_open_brackets_is_still_a_link :: proc(t: ^testing.T) {
	// The scans for links count the bytes they look at, and hand over to the
	// index once a text has needed more than it should. A link that comes
	// after that point must come out as it would before it.
	opens := strings.repeat("[", 8000)
	defer delete(opens)
	for tail in ([?]string{
		"[a](http://b.example.org/x)",
		"[a](http://b.example.org/x \"title\") and [c](mailto:d@example.org)",
		"[a [b] c](http://b.example.org/(x))",
	}) {
		html := notify.render_markdown(strings.concatenate({opens, tail}, context.temp_allocator))
		defer delete(html)
		testing.expectf(t, strings.contains(html, `<a href="http://b.example.org/`), "no link in the output for %q", tail)
		testing.expectf(t, !strings.contains(html, "<a href=\"\">"), "an empty link for %q", tail)
	}
	html := notify.render_markdown(strings.concatenate({opens, "[a](http://b.example.org/x)"}, context.temp_allocator))
	defer delete(html)
	testing.expect(t, strings.has_suffix(html, `<a href="http://b.example.org/x">a</a></p>`), html[len(html) - 80:])
	free_all(context.temp_allocator)
}

@(test)
nests_to_a_limit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Openers that each have a closer: emphasis nests to the limit, then the
	// rest is text.
	depth := notify.MAX_NESTING + 8
	text := strings.concatenate({strings.repeat("*a ", depth, context.temp_allocator), strings.repeat("a* ", depth, context.temp_allocator)}, context.temp_allocator)
	html := notify.render_markdown(text)
	defer delete(html)
	testing.expect(t, strings.has_prefix(html, "<p>"))
	testing.expect(t, strings.has_suffix(html, "</p>"))
	testing.expect(t, strings.count(html, "<em>") <= notify.MAX_NESTING)
	testing.expect(t, strings.count(html, "<em>") == strings.count(html, "</em>"))

	// Quotes too: the depth that is allowed is a quote each, the rest text.
	quotes := strings.repeat("> ", notify.MAX_NESTING + 30, context.temp_allocator)
	quoted := strings.concatenate({quotes, "deep"}, context.temp_allocator)
	html2 := notify.render_markdown(quoted)
	defer delete(html2)
	testing.expect_value(t, strings.count(html2, "<blockquote>"), notify.MAX_NESTING)
	testing.expect_value(t, strings.count(html2, "</blockquote>"), notify.MAX_NESTING)
	testing.expect(t, strings.contains(html2, "deep"))
}

@(test)
renders_large_text_fast :: proc(t: ^testing.T) {
	// The size of the longest message the tool sends.
	line := "**build** `huginn` failed: see [the log](https://example.org/x?a=1&b=2) _now_ ~~later~~\n"
	text := strings.repeat(line, 400)
	defer delete(text)
	started := time.tick_now()
	html := notify.render_markdown(text)
	defer delete(html)
	elapsed := time.tick_diff(started, time.tick_now())
	testing.expectf(t, elapsed < time.Second, "rendering %d bytes took %v", len(text), elapsed)
	testing.expect_value(t, strings.count(html, "<strong>build</strong>"), 400)
}
