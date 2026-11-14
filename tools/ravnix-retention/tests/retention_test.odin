// The tests of the retention file and the flags it gives: what restic forget
// is told for each target and host, the host overrides, and every way the
// file can be wrong. A wrong file must never give flags: the prune that
// would run with them deletes snapshots for good.
package ravnix_retention_tests

import "core:mem/virtual"
import "core:strings"
import "core:testing"
import retention ".."

// The numbers of templates/default/backups.toml, and of the plan.
TEMPLATE :: `# How many restic snapshots each backup target keeps.

[targets.nas]
daily = 7
weekly = 4
monthly = 6
yearly = 0

[targets.internxt]
daily = 7
weekly = 4
monthly = 12
yearly = 2

# A host that keeps a different number gets a table of its own:
#
# [targets.nas.hosts.muninn]
# daily = 14
`

NAS_HUGINN :: "--host huginn --group-by host --keep-daily 7 --keep-weekly 4 --keep-monthly 6"
INTERNXT_HUGINN :: "--host huginn --group-by host --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 2"

scratch :: proc(t: ^testing.T) -> (arena: virtual.Arena) {
	if virtual.arena_init_growing(&arena) != nil {
		testing.fail_now(t, "no memory")
	}
	return
}

// flags_of reads text and gives the flags for target and host, or why it
// cannot; both live in arena.
flags_of :: proc(arena: ^virtual.Arena, text, target, host: string) -> (flags: string, why: string) {
	a := virtual.arena_allocator(arena)
	r: retention.Retention
	r, why = retention.read_retention(text, a)
	if why != "" {
		return "", why
	}
	which, ok := retention.target_named(target)
	if !ok {
		return "", "unknown target"
	}
	return retention.flags(&r, which, host, a), ""
}

// expect_refused checks that text gives no flags, and that the reason
// contains want.
expect_refused :: proc(t: ^testing.T, text, want: string, loc := #caller_location) {
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	flags, why := flags_of(&arena, text, "nas", "huginn")
	testing.expectf(t, flags == "", "flags given for a refused file: %q", flags, loc = loc)
	testing.expectf(t, strings.contains(why, want), "want a reason with %q, got %q", want, why, loc = loc)
}

// with_internxt is a file whose nas target is nas, and whose internxt
// target is the template's.
with_internxt :: proc(nas: string, allocator := context.allocator) -> string {
	return strings.concatenate({nas, "\n[targets.internxt]\ndaily = 7\nweekly = 4\nmonthly = 12\nyearly = 2\n"}, allocator)
}

NAS_TABLE :: "[targets.nas]\ndaily = 7\nweekly = 4\nmonthly = 6\nyearly = 0\n"

// ---------------------------------------------------------------------------
// The flags

@(test)
gives_the_flags_for_nas_and_huginn :: proc(t: ^testing.T) {
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	flags, why := flags_of(&arena, TEMPLATE, "nas", "huginn")
	testing.expect_value(t, why, "")
	testing.expect_value(t, flags, NAS_HUGINN)
}

@(test)
gives_the_flags_for_internxt :: proc(t: ^testing.T) {
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	flags, why := flags_of(&arena, TEMPLATE, "internxt", "huginn")
	testing.expect_value(t, why, "")
	testing.expect_value(t, flags, INTERNXT_HUGINN)
}

@(test)
names_the_host_it_is_asked_for :: proc(t: ^testing.T) {
	// --host keeps the prune to that host's snapshots in a repository the
	// whole estate shares, and --group-by host keeps a change of the backup
	// paths from starting a group the policy never thins out.
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	flags, why := flags_of(&arena, TEMPLATE, "internxt", "muninn")
	testing.expect_value(t, why, "")
	testing.expect(t, strings.has_prefix(flags, "--host muninn --group-by host "))
}

@(test)
leaves_a_zero_count_out :: proc(t: ^testing.T) {
	// 0 keeps none of that kind, which is what restic does when the flag is
	// not given; restic 0.19 reads --keep-yearly 0 the same way, but an
	// older or newer one need not.
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	flags, why := flags_of(&arena, TEMPLATE, "nas", "huginn")
	testing.expect_value(t, why, "")
	testing.expect(t, !strings.contains(flags, "yearly"))
}

@(test)
a_host_override_wins :: proc(t: ^testing.T) {
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	text := strings.concatenate({TEMPLATE, "\n[targets.nas.hosts.muninn]\ndaily = 14\n"}, virtual.arena_allocator(&arena))
	flags, why := flags_of(&arena, text, "nas", "muninn")
	testing.expect_value(t, why, "")
	testing.expect_value(t, flags, "--host muninn --group-by host --keep-daily 14 --keep-weekly 4 --keep-monthly 6")
}

@(test)
an_override_is_for_its_host_and_target_alone :: proc(t: ^testing.T) {
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	text := strings.concatenate({TEMPLATE, "\n[targets.nas.hosts.muninn]\ndaily = 14\n"}, virtual.arena_allocator(&arena))
	flags, why := flags_of(&arena, text, "nas", "huginn")
	testing.expect_value(t, why, "")
	testing.expect_value(t, flags, NAS_HUGINN)
	flags, why = flags_of(&arena, text, "internxt", "muninn")
	testing.expect_value(t, why, "")
	testing.expect_value(t, flags, "--host muninn --group-by host --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 2")
}

@(test)
an_override_of_zero_drops_that_kind :: proc(t: ^testing.T) {
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	text := strings.concatenate({TEMPLATE, "\n[targets.internxt.hosts.huginn]\nyearly = 0\nmonthly = 3\n"}, virtual.arena_allocator(&arena))
	flags, why := flags_of(&arena, text, "internxt", "huginn")
	testing.expect_value(t, why, "")
	testing.expect_value(t, flags, "--host huginn --group-by host --keep-daily 7 --keep-weekly 4 --keep-monthly 3")
}

@(test)
an_override_can_raise_a_kind_the_target_keeps_none_of :: proc(t: ^testing.T) {
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	text := strings.concatenate({TEMPLATE, "[targets.nas.hosts.muninn]\nyearly = 1\n"}, virtual.arena_allocator(&arena))
	flags, why := flags_of(&arena, text, "nas", "muninn")
	testing.expect_value(t, why, "")
	testing.expect_value(t, flags, "--host muninn --group-by host --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 1")
}

@(test)
knows_the_two_targets_and_no_other :: proc(t: ^testing.T) {
	nas, ok_nas := retention.target_named("nas")
	testing.expect(t, ok_nas)
	testing.expect_value(t, nas, retention.Target.Nas)
	internxt, ok_internxt := retention.target_named("internxt")
	testing.expect(t, ok_internxt)
	testing.expect_value(t, internxt, retention.Target.Internxt)
	for name in ([]string{"", "NAS", "b2", "nas ", "hosts", "targets.nas"}) {
		_, ok := retention.target_named(name)
		testing.expectf(t, !ok, "%q taken as a target", name)
	}
}

// ---------------------------------------------------------------------------
// Values that are not counts

@(test)
refuses_a_negative_count_naming_the_key :: proc(t: ^testing.T) {
	text := strings.concatenate({NAS_TABLE, "[targets.internxt]\ndaily = 7\nweekly = 4\nmonthly = 12\nyearly = -1\n"})
	defer delete(text)
	expect_refused(t, text, "targets.internxt.yearly is not a whole number of 0 or more")
}

@(test)
refuses_a_value_that_is_not_an_integer_naming_the_key :: proc(t: ^testing.T) {
	cases := [?]string{"7.5", "7e0", `"7"`, "'7'", "true", "inf", "nan", "[7]", "{ n = 7 }", "seven", "1979-05-27", "0x7", "0o7", "0b111", "07", "7_", "_7", "7__0", "+", "-", ""}
	for value in cases {
		text := strings.concatenate({"[targets.nas]\ndaily = ", value, "\nweekly = 4\nmonthly = 6\nyearly = 0\n"})
		nas := with_internxt(text)
		expect_refused(t, nas, "targets.nas.daily")
		delete(nas)
		delete(text)
	}
}

@(test)
refuses_a_count_too_large_to_hold :: proc(t: ^testing.T) {
	text := with_internxt("[targets.nas]\ndaily = 9223372036854775808\nweekly = 4\nmonthly = 6\nyearly = 0\n")
	defer delete(text)
	expect_refused(t, text, "targets.nas.daily")
}

@(test)
reads_the_integers_toml_allows :: proc(t: ^testing.T) {
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	text := with_internxt("[targets.nas]\ndaily = +7\nweekly = 1_0\nmonthly = -0\nyearly = 9223372036854775807\n", virtual.arena_allocator(&arena))
	flags, why := flags_of(&arena, text, "nas", "huginn")
	testing.expect_value(t, why, "")
	testing.expect_value(t, flags, "--host huginn --group-by host --keep-daily 7 --keep-weekly 10 --keep-yearly 9223372036854775807")
}

@(test)
refuses_a_bad_value_in_a_host_override_naming_the_key :: proc(t: ^testing.T) {
	text := strings.concatenate({TEMPLATE, "[targets.nas.hosts.muninn]\ndaily = -14\n"})
	defer delete(text)
	expect_refused(t, text, "targets.nas.hosts.muninn.daily is not a whole number of 0 or more")
}

// ---------------------------------------------------------------------------
// Targets and keys

@(test)
refuses_a_target_ravnix_does_not_back_up_to :: proc(t: ^testing.T) {
	text := strings.concatenate({TEMPLATE, "[targets.b2]\ndaily = 1\nweekly = 0\nmonthly = 0\nyearly = 0\n"})
	defer delete(text)
	expect_refused(t, text, "targets.b2 is not a target ravnix backs up to")
}

@(test)
refuses_a_file_without_a_target :: proc(t: ^testing.T) {
	expect_refused(t, NAS_TABLE, "targets.internxt is missing")
	expect_refused(t, "", "targets.nas is missing")
	expect_refused(t, "# nothing but a comment\n", "targets.nas is missing")
}

@(test)
refuses_a_target_without_a_count :: proc(t: ^testing.T) {
	text := with_internxt("[targets.nas]\ndaily = 7\nweekly = 4\nyearly = 0\n")
	defer delete(text)
	expect_refused(t, text, "targets.nas has no monthly")
}

@(test)
refuses_a_misspelt_key :: proc(t: ^testing.T) {
	text := with_internxt("[targets.nas]\ndayly = 7\ndaily = 7\nweekly = 4\nmonthly = 6\nyearly = 0\n")
	defer delete(text)
	expect_refused(t, text, "targets.nas.dayly is not a key of the file")
}

@(test)
refuses_a_key_outside_the_targets :: proc(t: ^testing.T) {
	text := strings.concatenate({"version = 1\n", TEMPLATE})
	defer delete(text)
	expect_refused(t, text, "version is not a key of the file")
}

@(test)
refuses_a_misspelt_key_in_a_host_override :: proc(t: ^testing.T) {
	text := strings.concatenate({TEMPLATE, "[targets.nas.hosts.muninn]\nhourly = 24\n"})
	defer delete(text)
	expect_refused(t, text, "targets.nas.hosts.muninn.hourly is not a key of the file")
}

@(test)
refuses_hosts_inside_a_host_override :: proc(t: ^testing.T) {
	text := strings.concatenate({TEMPLATE, "[targets.nas.hosts.muninn.hosts.x]\ndaily = 1\n"})
	defer delete(text)
	expect_refused(t, text, "targets.nas.hosts.muninn.hosts is not a key of the file")
}

@(test)
refuses_what_should_be_a_table_and_is_not :: proc(t: ^testing.T) {
	expect_refused(t, "targets = \"x\"\n", "targets is not a table")
	text := strings.concatenate({"[targets]\nnas = 5\n\n", "[targets.internxt]\ndaily = 7\nweekly = 4\nmonthly = 12\nyearly = 2\n"})
	defer delete(text)
	expect_refused(t, text, "targets.nas is not a table")
	hosts := with_internxt("[targets.nas]\ndaily = 7\nweekly = 4\nmonthly = 6\nyearly = 0\nhosts = 5\n")
	defer delete(hosts)
	expect_refused(t, hosts, "targets.nas.hosts is not a table")
	host := strings.concatenate({TEMPLATE, "[targets.nas.hosts]\nmuninn = 14\n"})
	defer delete(host)
	expect_refused(t, host, "targets.nas.hosts.muninn is not a table")
}

// ---------------------------------------------------------------------------
// Keeping nothing

@(test)
refuses_a_target_that_keeps_nothing :: proc(t: ^testing.T) {
	text := with_internxt("[targets.nas]\ndaily = 0\nweekly = 0\nmonthly = 0\nyearly = 0\n")
	defer delete(text)
	expect_refused(t, text, "targets.nas keeps nothing, so a prune would delete every snapshot")
}

@(test)
refuses_a_host_override_that_keeps_nothing :: proc(t: ^testing.T) {
	text := strings.concatenate({TEMPLATE, "[targets.internxt.hosts.muninn]\ndaily = 0\nweekly = 0\nmonthly = 0\nyearly = 0\n"})
	defer delete(text)
	expect_refused(t, text, "targets.internxt.hosts.muninn keeps nothing, so a prune would delete every snapshot")
}

@(test)
refuses_an_override_that_zeroes_what_the_target_keeps :: proc(t: ^testing.T) {
	// nas keeps no yearlies, so zeroing the other three keeps nothing, even
	// though the override itself does not say yearly = 0.
	text := strings.concatenate({TEMPLATE, "[targets.nas.hosts.huginn]\ndaily = 0\nweekly = 0\nmonthly = 0\n"})
	defer delete(text)
	expect_refused(t, text, "targets.nas.hosts.huginn keeps nothing")
}

@(test)
refuses_the_whole_file_for_a_mistake_elsewhere :: proc(t: ^testing.T) {
	// A mistake in another target's or another host's numbers is still a
	// mistake: whoever wrote it meant something else everywhere.
	text := strings.concatenate({TEMPLATE, "[targets.internxt.hosts.muninn]\ndaily = -1\n"})
	defer delete(text)
	expect_refused(t, text, "targets.internxt.hosts.muninn.daily")
}

// ---------------------------------------------------------------------------
// The TOML itself

@(test)
reads_comments_blanks_and_spacing :: proc(t: ^testing.T) {
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	text := "\xef\xbb\xbf# top\r\n\r\n  [ targets . nas ]   # the NAS\r\n\tdaily=7 # a week\r\nweekly =\t4\r\nmonthly = 6\r\nyearly = 0\r\n[targets.\"internxt\"]\ndaily = 7\nweekly = 4\nmonthly = 12\nyearly = 2"
	flags, why := flags_of(&arena, text, "nas", "huginn")
	testing.expect_value(t, why, "")
	testing.expect_value(t, flags, NAS_HUGINN)
}

@(test)
reads_dotted_and_quoted_keys :: proc(t: ^testing.T) {
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	text := strings.concatenate({TEMPLATE, "[targets.nas.hosts]\nmuninn.daily = 14\n\"box-2\" . weekly = 9\n"}, virtual.arena_allocator(&arena))
	flags, why := flags_of(&arena, text, "nas", "muninn")
	testing.expect_value(t, why, "")
	testing.expect_value(t, flags, "--host muninn --group-by host --keep-daily 14 --keep-weekly 4 --keep-monthly 6")
	flags, why = flags_of(&arena, text, "nas", "box-2")
	testing.expect_value(t, why, "")
	testing.expect_value(t, flags, "--host box-2 --group-by host --keep-daily 7 --keep-weekly 9 --keep-monthly 6")
}

@(test)
names_an_inline_table_it_does_not_read :: proc(t: ^testing.T) {
	text := strings.concatenate({TEMPLATE, "[targets.nas.hosts]\nmuninn = { daily = 14 }\n"})
	defer delete(text)
	expect_refused(t, text, "line 20: targets.nas.hosts.muninn is an inline table")
}

@(test)
refuses_a_key_given_twice :: proc(t: ^testing.T) {
	text := with_internxt("[targets.nas]\ndaily = 7\nweekly = 4\nmonthly = 6\nyearly = 0\ndaily = 8\n")
	defer delete(text)
	expect_refused(t, text, "line 6: targets.nas.daily is given twice")
}

@(test)
refuses_a_table_given_twice :: proc(t: ^testing.T) {
	text := strings.concatenate({TEMPLATE, "[targets.nas]\nyearly = 1\n"})
	defer delete(text)
	expect_refused(t, text, "[targets.nas] is given twice")
}

@(test)
refuses_a_table_over_a_count :: proc(t: ^testing.T) {
	text := strings.concatenate({TEMPLATE, "[targets.nas.daily]\nx = 1\n"})
	defer delete(text)
	expect_refused(t, text, "targets.nas.daily is given twice")
}

@(test)
refuses_toml_it_does_not_read_naming_the_line :: proc(t: ^testing.T) {
	cases := [?]struct {
		line: string,
		want: string,
	} {
		{"[targets.nas", "line 1:"},
		{"[targets..nas]", "line 1:"},
		{"[]", "line 1:"},
		{"[[targets.nas]]", "line 1:"},
		{"[targets.nas] x", "line 1:"},
		{"\"da\\\"ily\" = 7", "line 1:"},
		{"[\"\"]", "line 1:"},
		{"[targets.'nas']", "line 4: [targets.nas] is given twice"},
		{"targets.nas.daily = 7", "line 4: [targets.nas] is given twice"},
		{"daily = 7 7", "line 1:"},
		{"daily = \"\"\"", "line 1:"},
		{"daily", "line 1:"},
		{"= 7", "line 1:"},
		{"[targets.na s]", "line 1:"},
		{"[targets.\"na\\s\"]", "line 1:"},
		{"[targets.\"nas]", "line 1:"},
	}
	for c in cases {
		text := strings.concatenate({c.line, "\n", TEMPLATE})
		expect_refused(t, text, c.want)
		delete(text)
	}
}

@(test)
refuses_a_control_character :: proc(t: ^testing.T) {
	text := strings.concatenate({"[targets.nas]\x00\n", TEMPLATE})
	defer delete(text)
	expect_refused(t, text, "line 1:")
}

@(test)
reads_a_huge_file_of_comments :: proc(t: ^testing.T) {
	// The size limit is the command's; the reader itself takes any length.
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	b := strings.builder_make(a)
	for _ in 0 ..< 20000 {
		strings.write_string(&b, "# a comment line that says nothing at all\n")
	}
	strings.write_string(&b, TEMPLATE)
	flags, why := flags_of(&arena, strings.to_string(b), "nas", "huginn")
	testing.expect_value(t, why, "")
	testing.expect_value(t, flags, NAS_HUGINN)
}

@(test)
reads_many_hosts :: proc(t: ^testing.T) {
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	b := strings.builder_make(a)
	strings.write_string(&b, TEMPLATE)
	for i in 0 ..< 500 {
		strings.write_string(&b, "[targets.nas.hosts.host-")
		strings.write_int(&b, i)
		strings.write_string(&b, "]\ndaily = ")
		strings.write_int(&b, i + 1)
		strings.write_string(&b, "\n")
	}
	flags, why := flags_of(&arena, strings.to_string(b), "nas", "host-499")
	testing.expect_value(t, why, "")
	testing.expect_value(t, flags, "--host host-499 --group-by host --keep-daily 500 --keep-weekly 4 --keep-monthly 6")
}

// ---------------------------------------------------------------------------
// The host

@(test)
takes_a_host_name_restic_would_record :: proc(t: ^testing.T) {
	for host in ([]string{"huginn", "muninn", "host-1", "a", "Box_2", "x2"}) {
		testing.expectf(t, retention.check_host(host) == "", "%q refused: %s", host, retention.check_host(host))
	}
}

@(test)
refuses_a_host_name_that_would_break_the_command_line :: proc(t: ^testing.T) {
	// The flags are split on blanks by the shell that runs restic, and a
	// name with a leading dash would be read as an option.
	long := strings.repeat("a", 254)
	defer delete(long)
	for host in ([]string{"", "-v", "--keep-last", "a b", "a\tb", "a\nb", "a/b", "a.b", "*", "$(x)", "ä", long}) {
		testing.expectf(t, retention.check_host(host) != "", "%q taken as a host", host)
	}
}
