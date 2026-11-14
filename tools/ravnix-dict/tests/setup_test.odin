// Which adapters main syncs, and where they look: RAVNIX_DICT_ADAPTERS and
// the paths, from the environment.
package ravnix_dict_tests

import "core:strings"
import "core:testing"
import dict ".."
import tools "../adapters"

names_of :: proc(list: []dict.Adapter) -> string {
	out := make([dynamic]string, context.temp_allocator)
	for a in list {
		append(&out, a.name)
	}
	return strings.join(out[:], ",", context.temp_allocator)
}

@(test)
the_adapters_come_from_the_environment :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	defer free_all(context.temp_allocator)

	// None named, none synced: the bench, a test, a shell without the module.
	list, why := dict.adapters({home = "/home/alice"})
	testing.expect_value(t, why, "")
	testing.expect_value(t, len(list), 0)

	// In the order sync reads them, whatever the order named, each once.
	list, why = dict.adapters({names = " prose,handy, ,languagetool,prose", home = "/home/alice"})
	testing.expect_value(t, why, "")
	testing.expect_value(t, names_of(list), "handy,languagetool,prose")
	testing.expect(t, list[0].must_stop)
	testing.expect(t, list[1].unavailable != nil)
	testing.expect_value(t, tools.handy.settings, "/home/alice/.local/share/com.pais.handy/settings_store.json")
	testing.expect_value(t, tools.prose.file, "/home/alice/.config/prose/dictionary.txt")
	testing.expect_value(t, tools.languagetool.credentials, "/home/alice/.config/languagetool/credentials")

	// The XDG directories, when absolute, and the paths given, win.
	list, why = dict.adapters({names = "handy,prose", home = "/home/alice", data_home = "/d", config_home = "relative"})
	testing.expect_value(t, tools.handy.settings, "/d/com.pais.handy/settings_store.json")
	testing.expect_value(t, tools.prose.file, "/home/alice/.config/prose/dictionary.txt")
	list, why = dict.adapters({names = "handy,prose", handy_settings = "/h.json", prose_file = "/p.txt"})
	testing.expect_value(t, why, "")
	testing.expect_value(t, tools.handy.settings, "/h.json")
	testing.expect_value(t, tools.prose.file, "/p.txt")

	// An adapter that does not exist, and one with nowhere to look.
	list, why = dict.adapters({names = "handy,vim", home = "/home/alice"})
	testing.expectf(t, strings.contains(why, "vim") && strings.contains(why, "handy, languagetool, prose"), "%q", why)
	list, why = dict.adapters({names = "prose"})
	testing.expectf(t, strings.contains(why, "RAVNIX_DICT_PROSE_FILE"), "%q", why)
}
