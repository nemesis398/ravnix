package energy

import "core:fmt"
import "core:strings"

// How long keep-awake's swayidle waits before it runs `energy idle-suspend`.
IDLE_SUSPEND_MIN :: 30

// The icons of the rows, Nerd Font glyphs.
ICON_PROFILE :: "\U000F0F85"
ICON_REFRESH :: "\U000F0379"
ICON_KEEP_AWAKE :: "\U000F0176"
ICON_IDLE :: "\U000F04B2"
ICON_CHARGE :: "\U000F0084"
ICON_FOCUS :: "\U000F056E"
ICON_CHECK :: "\U000F012C"

// pick shows rows in a fuzzel dropdown and returns the row chosen. ok is
// false when nothing was chosen (Escape), and when fuzzel is not there or
// fails, which the caller treats alike: the menu ends quietly.
pick :: proc(cfg: ^Config, prompt: string, lines: int, rows: []string) -> (choice: string, ok: bool) {
	input := strings.concatenate({strings.join(rows, "\n", context.temp_allocator), "\n"}, context.temp_allocator)
	res := run_child(
		cfg,
		{argv = {"fuzzel", "--dmenu", "--prompt", prompt, "--width", "42", "--lines", fmt.tprint(lines)}, input = input, capture = true, stderr_to = cfg.stderr, wait_forever = true},
		context.temp_allocator,
	)
	if !res.started {
		say(cfg, "energy: fuzzel is not on the PATH")
		return
	}
	if res.code != 0 {
		return
	}
	return strings.trim_right(string(res.stdout), "\n"), true
}

// mark is one row of a choice list: the current value wears a check mark.
mark :: proc(current, value, label: string) -> string {
	if current == value {
		return fmt.tprintf("%s %s", ICON_CHECK, label)
	}
	return fmt.tprintf("   %s", label)
}

// last_field is the last white-space separated word of text, or "".
last_field :: proc(text: string) -> string {
	fields := strings.fields(text, context.temp_allocator)
	return fields[len(fields) - 1] if len(fields) > 0 else ""
}

// charge_mode_now is what charge-mode says, or unknown.
charge_mode_now :: proc(cfg: ^Config) -> string {
	res := run_child(cfg, {argv = {cfg.charge_mode}, capture = true}, context.temp_allocator)
	if res.code != 0 {
		return "unknown"
	}
	return strings.trim_right(string(res.stdout), "\n")
}

// menu is `energy menu` (middle click on waybar's power-profile icon): a
// fuzzel dropdown with one row per setting and its current value. Picking a
// row opens that setting's choices. The status is that of the last thing it
// ran, as the shell version's was.
menu :: proc(cfg: ^Config) -> int {
	refresh_key, _ := find_key("refresh")
	idle_key, _ := find_key("idle_suspend")
	focus_key, _ := find_key("focus_bar")

	prof := profile(cfg)
	ka := "off"
	if text, _ := read_text(run_path(cfg, "keep-awake")); text == "1" {
		ka = "on"
	}
	cm := charge_mode_now(cfg)
	refresh_now := state_get(cfg, refresh_key)
	idle_now := state_get(cfg, idle_key)
	focus_now := state_get(cfg, focus_key)

	r_prof := fmt.tprintf("%s  Power profile: %s", ICON_PROFILE, prof)
	r_ref := fmt.tprintf("%s  Refresh rate: %s", ICON_REFRESH, refresh_now)
	if refresh_now == "auto" {
		r_ref = fmt.tprintf("%s (%d Hz now)", r_ref, target_hz(cfg))
	}
	r_ka := fmt.tprintf("%s  Keep-awake: %s", ICON_KEEP_AWAKE, ka)
	r_is := fmt.tprintf("%s  Idle suspend on battery: %s", ICON_IDLE, idle_now)
	r_cm := fmt.tprintf("%s  Charge mode: %s", ICON_CHARGE, cm)
	r_fb := fmt.tprintf("%s  Focus bar on battery: %s", ICON_FOCUS, focus_now)

	choice, ok := pick(cfg, "  Energy   ", 6, {r_prof, r_ref, r_ka, r_is, r_cm, r_fb})
	if !ok {
		return 0
	}
	switch choice {
	case r_prof:
		sub, chosen := pick(cfg, "  Power profile   ", 3, {mark(prof, "power-saver", "power-saver"), mark(prof, "balanced", "balanced"), mark(prof, "performance", "performance")})
		if !chosen {
			return 0
		}
		// The watcher follows with the refresh rate.
		name := last_field(sub)
		if name == "" {
			return 0
		}
		return set_profile(cfg, name)
	case r_ref:
		sub, chosen := pick(
			cfg,
			"  Refresh rate   ",
			3,
			{mark(refresh_now, "auto", "auto  (60 Hz on power-saver, else 120 Hz)"), mark(refresh_now, "120", "120 Hz always"), mark(refresh_now, "60", "60 Hz always")},
		)
		if !chosen {
			return 0
		}
		// The first match decides, in this order, as the rows read.
		switch {
		case strings.contains(sub, "auto"):
			state_set(cfg, refresh_key, "auto")
		case strings.contains(sub, "120"):
			state_set(cfg, refresh_key, "120")
		case strings.contains(sub, "60"):
			state_set(cfg, refresh_key, "60")
		}
		return refresh(cfg)
	case r_ka:
		sub, chosen := pick(cfg, "  Keep-awake   ", 2, {mark(ka, "on", "on   (no idle lock or screen-off)"), mark(ka, "off", "off  (normal idle)")})
		if !chosen {
			return 0
		}
		if !need(cfg, "keep-awake", "keep-awake is unchanged") {
			return 1
		}
		switch {
		case strings.contains(sub, "on "):
			return keep_awake(cfg, "on", "off")
		case strings.contains(sub, "off"):
			return keep_awake(cfg, "off", "on")
		}
	case r_is:
		sub, chosen := pick(
			cfg,
			"  Idle suspend   ",
			2,
			{mark(idle_now, "on", fmt.tprintf("on   (suspend after %d min idle, on battery)", IDLE_SUSPEND_MIN)), mark(idle_now, "off", "off")},
		)
		if !chosen {
			return 0
		}
		return choose_on_off(cfg, idle_key, sub)
	case r_cm:
		sub, chosen := pick(
			cfg,
			"  Charge mode   ",
			3,
			{
				mark(cm, "Long_Life", "Long_Life  (parks the cell, refills to 80%)"),
				mark(cm, "Standard", "Standard   (charges to 100%)"),
				mark(cm, "Fast", "Fast       (100%, hardest on the cell)"),
			},
		)
		if !chosen {
			return 0
		}
		for word in strings.fields_iterator(&sub) {
			if word == "Long_Life" || word == "Standard" || word == "Fast" {
				return run_child(cfg, {argv = {cfg.charge_mode, "set", word}, stderr_to = cfg.stderr}, context.temp_allocator).code
			}
		}
	case r_fb:
		sub, chosen := pick(cfg, "  Focus bar   ", 2, {mark(focus_now, "on", "on   (focus layout while on battery)"), mark(focus_now, "off", "off")})
		if !chosen {
			return 0
		}
		return choose_on_off(cfg, focus_key, sub)
	}
	return 0
}

// choose_on_off saves the on or off of a chosen row.
choose_on_off :: proc(cfg: ^Config, key: Key, row: string) -> int {
	switch {
	case strings.contains(row, "on "):
		return state_set(cfg, key, "on")
	case strings.contains(row, "off"):
		return state_set(cfg, key, "off")
	}
	return 0
}
