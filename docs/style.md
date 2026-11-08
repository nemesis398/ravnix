# Ravnix Style

Ravnix looks like a terminal that grew a desktop. It is flat, square, opaque, and edge to edge, drawn in one palette with one accent, where color says what state something is in and nothing moves unless you moved it. The look was not designed on paper. It was built up on a Fedora Sway laptop over four months, one config at a time, and this document writes down the rules those configs already follow, plus the few places where they disagreed with each other and a decision was made.

## 🔇 Principles

Three rules sit above all the others. A change that breaks one of them is wrong even when it looks good.

**Quiet until it matters.** Surfaces are neutral and there is one accent. Color carries state or place and is never decoration. The warm hues (Peach, Red) appear only for warnings and errors, so when something on screen is warm, something is wrong. The test: if you cannot say what a color tells the reader, it goes.

**Nothing moves.** A value that changes never pushes its neighbors. Every module that shows a number has a fixed width sized to its widest value. Space for a hover marker is reserved up front. The bar has the same height in every mode. There is no animation, no transition, no blinking cursor, and both hosts use the same keys and look the same. The test: set every value to its widest, toggle every mode, and watch for a shift of even one pixel.

**Text first.** One monospace family everywhere, Nerd Font glyphs for the shell's own icons, terminal and TUI applications before graphical ones, and a graphical application only when it can be themed to match. The system should read like a terminal. The test: a new application is a TUI or a native GTK or Qt program, or it is Electron with a written reason.

One candidate was considered and left out: an *instrument panel* look, with live numbers always on screen. The bar may show power draw, temperatures, and load, and it does by default, but the look does not depend on them and a user can drop any of them.

## 📋 Decisions at a glance

| Question | Rule |
| --- | --- |
| Palette | Catppuccin **Mocha**, always. Flavor is not an option |
| Accent | One role, `accent`, default **Mauve** `#cba6f7`, set by one typed option. An accent may not be one of the state hues (Red, Maroon, Peach, Yellow, Green, Blue) |
| Borders | A border marks something that floats. Tiled surfaces have none |
| Line widths | **1 px frames, 2 px markers.** No other widths, except the lock ring, which is a gauge and not a line |
| Corners | **Square, radius 0, everywhere**: windows, bar, menus, TUIs, diagrams, logo containers |
| Fills | Solid accent with Crust text marks where you are. Rows and hover use a grey wash |
| Host color | Mauve (huginn) and Blue (muninn) exist on paper only. The live system looks the same on both |
| Marks on the running system | Drawn in one color, the accent. The two-color version is for paper only |
| Wallpaper | Personal, per user. The shipped default is a fixed composition (see *Identity*) |
| Transparency | None. Windows, bar, menus and notifications are fully opaque. The inside of the lock ring is the one exception |
| Motion | None |
| Font | JetBrainsMono Nerd Font, everywhere |
| Lock screen | Shows identity, never information |

## 🎨 Color

### Surfaces and text

Neutrals form a ladder. Pick the rung by job, not by taste.

| Role | Catppuccin | Hex | Use |
| --- | --- | --- | --- |
| deepest | Crust | `#11111b` | Text on accent fills and on state fills, and the alternative backdrop of the one-color logo |
| dock | Mantle | `#181825` | The bar and any other strip that frames the work |
| canvas | Base | `#1e1e2e` | Windows, terminal, launcher, notifications, the desktop |
| wash | Surface0 | `#313244` | Hover wash, selected row in an unfocused view, unfocused float frame, diagram box fill |
| selected | Surface1 | `#45475a` | The selected row in a focused list or menu |
| line | Surface2 | `#585b70` | Unfocused pane frames, the idle lock ring |
| muted | Overlay0 | `#6c7086` | Things that are off or empty: an empty workspace, a muted sink, an idle toggle |
| placeholder | Overlay1 | `#7f849c` | Placeholder text, leader lines in diagrams |
| secondary | Subtext0 | `#a6adc8` | Inactive workspaces, secondary labels |
| label | Subtext1 | `#bac2de` | The focused window's title, prompts |
| text | Text | `#cdd6f4` | Everything you read |

### Accent

There is exactly one accent. Mauve is the default, and the user can set another. The accent marks **focus and place**: the frame of a floating thing, the active workspace, a non-default mode, the icon of every bar module, the clock, the prompt, matched letters in a search, the cursor, a text selection, a link, a progress bar. It never means a state.

The accent option accepts Mauve (default), Lavender, Pink, Flamingo, Rosewater, Teal, Sky, and Sapphire. It refuses the hues that already carry a state, because an accent that looks like an error is a bug waiting to happen.

Text on an accent fill is always Crust. Text-colored text on Mauve measures about 1.4 to 1, which is unreadable.

### State

State colors are fixed and do not follow the accent.

| State | Color | Hex | Seen today |
| --- | --- | --- | --- |
| warning, needs a person | Peach | `#fab387` | CPU, memory and battery warnings, a critical notification's frame, Caps Lock on the lock screen |
| failure, urgent | Red | `#f38ba8` | An urgent workspace, a wrong password, a lost network, critical thresholds, unstaged changes in lazygit |
| Caps Lock, backspace | Maroon | `#eba0ac` | The lock ring's backspace highlight while Caps Lock is on |
| busy | Blue | `#89b4fa` | The lock ring while it verifies |
| pending, cleared | Yellow | `#f9e2af` | The lock ring after the field is cleared |
| success | Green | `#a6e3a1` | ANSI green in a terminal. It has no place in the bar |

The remaining hues (Rosewater, Flamingo, Pink, Sky, Sapphire, Lavender, Teal) are not used in the shell chrome. Syntax highlighting, diagrams and applications that bring their own Catppuccin theme use them.

### Rules

- One accent, never two. No gradients, no glow, no shadow.
- No transparency and no blur. The one exception is the inside of the lock ring, which is clear so the mark shows through and turns Base at 80 percent while it prints a word. Hover is the Surface0 wash plus the 2 px marker, never an alpha.
- Terminal colors map to the palette this way: black is Surface1, red Red, green Green, yellow Yellow, blue Blue, magenta Pink, cyan Teal, white Subtext1. The bright set is Surface2, Red, Green, Yellow, Blue, **the accent** in the bright magenta slot, Teal, Subtext0.
- A terminal selection is accent fill with Crust text. A terminal cursor is an accent block with Crust text.

## 📐 Borders, shape and layout

### Borders

**A border marks something that floats.** Anything tiled into the layout stays bare, so the screen is made of touching rectangles and the few things lifted above them are the only ones outlined. This rule governs what the desktop draws. Inside an application's own canvas, a TUI pane or a diagram box draws its own line, at the same widths.

| Thing | Frame |
| --- | --- |
| Tiled window, any application | none |
| The bar | none, and it is separated from the windows by Mantle against Base |
| Launcher and menus | 1 px accent |
| Notification | 1 px accent, 1 px Peach when critical |
| Floating window, dialog | 1 px accent while focused, 1 px Surface0 when not |
| Tooltip | 1 px Surface0. The one exception: it is passive and should not compete |
| TUI pane | one box-drawing line, accent when focused, Surface2 when not |
| Diagram box | 1 px in its category color, plus the bar below |

**A marker is 2 px.** A marker says "this one": the hover underline in the bar, the bottom bar on a diagram box, an active tab. Its space is reserved from the start and stays invisible until the marker appears, so it never shifts a layout. Invisible means drawn in the color of what is behind it, the role color or `inherit` for a child that shows its parent, never `transparent`.

Other rules:

- Focus on a tiled window is shown by its title in the bar, not by a frame.
- On the desktop, group things with space or with one step on the surface ladder. A frame never groups.
- The lock ring is 10 px thick. It is a gauge that shows state, not a frame or a marker, so the two widths do not apply to it.
- TUIs use the single light line (`┌ ─ ┐ │ └ ┘`). No rounded corners, no double lines.

### Shape and layout

- Radius 0 everywhere. A rounded corner is a bug.
- Gaps are 0, inside and outside. Tiles touch. There are no title bars, because the title lives in the bar.
- A floating window opens centered. The quick terminal is 40 percent wide and 70 percent high of the workspace. A window pinned on top of every workspace is 960 by 600.
- The bar sits on the top edge, 32 px high, in every mode. Workspaces are numbers, with no names and no icons. The active one is an accent fill, an empty one is Overlay0, an urgent one is a Red fill. Every module has an icon in the accent and a value in Text. A module under the pointer gets the Surface0 wash and the 2 px accent underline. A focus mode drops the right-hand cluster and the workspace numbers and keeps everything else, the height included. Every module that shows a value has a fixed width sized to its widest value. Three strips grow by item count instead: the workspace strip, the mode pill and the tray. With the peripherals battery, which appears at its fixed width only while a mouse, keyboard or trackpad is low or charging, they are the only parts of the bar that may move.
- The terminal pads its content by 14 px on every side and has no window decoration.
- The pointer hides while you type and after 8 seconds idle. The cursor theme is Catppuccin Mocha in the accent, at 24 px.

### Fills

| Looks like | Means | Where |
| --- | --- | --- |
| accent fill, Crust text | where you are | the active workspace, a non-default mode, a text selection |
| Surface wash, accent on the matches | which row | menus, lists, hover |
| accent text only | what it is | icons, the clock, the prompt |

Within one list or strip, at most one item carries an accent fill: one active workspace, one selected row. The mode pill is its own strip. A second fill in the same list means the first stopped meaning anything.

## 🔤 Type

One family: **JetBrainsMono Nerd Font**, in the terminal, the bar, the launcher, notifications, the lock screen, the TUIs, GTK and Qt applications, diagrams, and code.

Text you read is small and text you glance at is large.

| Surface | Size |
| --- | --- |
| Terminal, editor, notifications | 9 pt |
| Launcher and menus | 11 pt |
| Bar | 14 px |

Weight and slant carry meaning and nothing else. **Bold** means where or when you are: the directory in the prompt, the clock, the active workspace, a mode. *Italic* means context: the focused window's title in the bar, the git branch, comments. Everything else is regular. Underline is for the 2 px marker and for links.

Icons are Nerd Font glyphs, one per module, in the accent, followed by the value in Text. Application icons use Papirus-Dark with folders in the accent.

## 🪟 Surfaces

The exact values live in the theme module. This table lists the choices that are easy to get wrong.

| Surface | Choices |
| --- | --- |
| Desktop | Base. See *Identity* for what sits on it |
| Terminal | Base, 14 px padding, block cursor with no blink, no confirmation on close, copy only on an explicit key |
| Prompt | Directory bold accent, branch italic accent followed by the git status symbols in the accent, `❯` bold accent, a failed command shows `✗` bold Red. Nothing else: no time, no user, no host, no language versions |
| Launcher | Base, 1 px accent frame, selection Surface1, matched letters accent, placeholder Overlay1, fixed width of 50 characters |
| Notifications | Base, 1 px accent frame, Peach frame when critical, a stacked pair separated by the frame color |
| Lock screen | See *Identity* |
| Login | The same palette, text only |
| Boot | Text only. No splash screen. The disk-unlock prompt is plain text |
| TUIs | The Catppuccin Mocha theme each one ships or accepts, with the accent on the focus marker: lazygit, Neovim, btop, bat, herdr |
| GTK and Qt applications | Catppuccin Mocha in the accent; Qt through Fusion and a KDE color scheme so Kirigami applications follow |
| Web applications | Catppuccin userstyles for the app, Mocha, in the accent |

## 🖼️ Identity: wallpaper, lock screen, logo

### Wallpaper

The wallpaper is the one surface with no rule, because it should be individual. A user supplies their own image through an option.

The **shipped default** is a fixed composition on Base:

- the ravnix mark in the middle,
- the author's phyllon mark in the top left, at the same size as the ravnix mark,
- the NixOS logo and the system facts, drawn through fastfetch, in the top right.

Everything is drawn in palette colors: the NixOS logo in Blue and Sapphire, never its brand blues. The facts appear on the desktop only. Both marks are drawn in one color, the accent, so the screen holds a single accent and the lock ring's Blue keeps meaning "verifying".

### Lock screen

**A locked screen shows identity, never information.** On the default, that means the mark inside the ring and nothing else: no logos, no machine facts, no clock, no notifications. Anyone who walks past learns nothing about the machine.

The ring is 110 px in radius and 10 px thick. Its color is the state:

| State | Ring |
| --- | --- |
| idle | Surface2 |
| key press | accent highlight |
| backspace | Red highlight |
| verifying | Blue |
| cleared | Yellow |
| wrong | Red |
| Caps Lock | Peach |

The inside is transparent while typing, so the mark shows through. It turns Base at 80 percent while it has to print a word over it.

### Host color

The mark has two ravens, Mauve for `huginn` and Blue for `muninn`. Those colors are identity on paper: the logo, the diagrams, and the README. In the running system the hosts look identical, down to the prompt, which shows no host. The two are meant to feel like one computer.

### Logo

- Two geometric ravens with long beaks passing each other. Straight edges, flat fills, no gradient, no outline softness.
- Palette colors only. The logo's Mauve and Blue are brand colors and do **not** follow the accent option. On the running system the mark is drawn in one color, the accent. The two-color version is for paper: the README, the docs and the diagrams.
- It must read at 16 px. It ships in a one-color version in Text, for use on Base and on Crust.
- The README header image carries its own Base background, so it looks the same on a light or a dark GitHub theme.

## 🗺️ Diagrams and docs

Diagrams share one layout language, taken from the author's keyboard-layout diagrams and made square.

- **Canvas** Base. Monospace throughout.
- **Title** at the top left, bold, Text, about two and a half times the body size. Under it one subtitle line in Subtext0 that says the version, the date, and the scope.
- **Boxes** are square: Surface0 fill, a 1 px frame and a 2 px bar along the bottom edge in the category color. The label is centered in Text, bold when it is the primary one. A secondary label (a key, a port, a host) sits above the bar in the category color. An unused box has Surface2 for frame and bar and an Overlay0 label in parentheses.
- **Leader lines** are 1 px, from the object to its note, in Overlay1. Notes are small, in Subtext1. Arrowheads only when direction matters.
- **Legend** as the last row: a square swatch and a label per category, in a fixed order. Every colored diagram has one.
- **Category order**: accent, Blue, Green, Teal, Pink, Lavender, Sky, then Surface2 for neutral or unused. Seven at most. Color names a category and the legend explains it. Peach and Red are never categories: they keep their meaning, a warning and a failure, in diagrams that show either.

**Mermaid** carries the same language so diagrams can live as text in the Markdown they explain. One shared init block sets the theme. It names Mauve, the default accent, because a diagram is static and does not follow a user's setting. `docs/mermaid-theme.json` holds the same values, and the style check compares every init block in the docs against it:

```text
%%{init: {"theme": "base", "themeVariables": {
  "background": "#1e1e2e", "primaryColor": "#313244",
  "primaryTextColor": "#cdd6f4", "primaryBorderColor": "#cba6f7",
  "lineColor": "#7f849c", "secondaryColor": "#181825",
  "tertiaryColor": "#181825",
  "fontFamily": "JetBrainsMono Nerd Font, ui-monospace, monospace" }}}%%
```

Use rectangles (`[ ]`) and, for a decision, a diamond. Never the rounded, stadium or circle shapes. Map categories to classes in the order above. Whether GitHub honors these theme variables is checked first, and if it does not, a script renders SVGs from the same sources.

## ✅ Applying this to something new

When a new application, screen or document needs styling, walk this list in order.

1. Background is Base. A strip that frames the work is Mantle. Text is Text.
2. Is it floating? Then a 1 px accent frame. Otherwise no frame.
3. Spend the accent on focus and place only: the active item, icons, the prompt, matches, and the cursor.
4. State gets a state color. Warm hues are for warnings and errors and nothing else.
5. Square corners. No shadow, no gradient, no blur, no transparency, no animation.
6. JetBrainsMono Nerd Font. Pick the size by job: small to read, large to glance at.
7. Anything whose value changes gets a fixed width.
8. A row is a Surface wash. A fill is for where you are, and only one per list.
9. If the application cannot be made to follow this, list it as an exception with the reason, in the module that installs it.

## 🔧 Integration into ravnix

The style becomes code in four places.

- **One theme module** holds the roles. It exposes the typed `accent` option, the role-to-hex table, the two line widths, the font, and the sizes. Every other module reads from it and never writes a hex value itself. Where an application has a `catppuccin/nix` integration, that is used and fed the same flavor and accent.
- **A style check in the local gate** (`scripts/check-style.sh`), next to the deny-list check, that fails on a hex color outside the theme module, the vendored files, this document and a Mermaid init block identical to the shared one, on any `border-radius` other than 0, on any opacity below 1 outside the inside of the lock ring (the keyword `transparent` is one), and on any `transition` or `animation` key.
- **The repo's agent rules** (`AGENTS.md`) get a *Style* section that points here and carries the checklist above, so an agent styling a new thing meets the rules before it picks a color.
- **Acceptance** is a side-by-side screenshot of the Fedora reference and `huginn` for each surface and each state: every lock-ring state, a critical notification, the focus-mode bar, and each bar module at its widest value. The reference is shot before Fedora is retired, at the same scale. The list in the next section holds the only allowed differences.

## ⚠️ Where the Fedora configs differ

Verified against the configs on 2026-11-07. A later audit of the Fedora setup found eight more rows, which are added before the last row. Everything not listed already matches. The login greeter, the boot text and the NixOS logo have no Fedora counterpart, and the wallpaper and the lock image change by design (see *Identity*), so screenshots cannot judge them: they are judged against this document.

| Config | Today | Ravnix |
| --- | --- | --- |
| dunst `frame_width` | 2 | 1 |
| fuzzel `background` | `1e1e2edd`, 87 percent opaque | `1e1e2eff` |
| fuzzel `selection` | `585b70` (Surface2) | `45475a` (Surface1) |
| ghostty `selection-foreground` | `cdd6f4` (Text) | `11111b` (Crust) |
| Sway `default_floating_border` | `none` | `pixel 1`; the `client.*` colors are already set |
| Waybar module hover | `alpha(@accent, 0.18)` wash plus a 2 px underline | `@surface0` wash plus the same underline |
| Waybar focus bar | 34 px high, spacing 6 | 32 px, spacing 2, same as the full bar |
| starship `error_symbol` | accent | Red |
| lazy.nvim `ui.border` | `rounded` | `single`; also check the `winborder` of Neovim's own floats |
| swaylock `indicator-idle-visible` | unset, so an idle lock shows no ring | set: the Surface2 ring is always there |
| swaylock `ring-caps-lock-color`, `line-caps-lock-color` | unset, swaylock's own default shows | Peach |
| Waybar focus bar | drops the right-hand cluster and the workspaces | the same; the rule in *Shape and layout* now says so |
| Waybar `custom/peripherals`, `custom/powerdraw`, `sway/window`, `network` | grow with their value and push their neighbours | a fixed width sized to the widest value; the window title is truncated to it |
| GTK and Qt UI font | Adwaita Sans 11, Adwaita Mono 11 | JetBrainsMono Nerd Font 11 |
| `sway-radial` | alpha 0.92 and an 80 ms opacity fade | opaque, no fade; the round ring stays |
| MangoHud `background_alpha` | 0.8 | 1 |
| starship git status, `❯` and `✗` weight | shown after the branch; bold | unchanged; the *Prompt* row now says so |
| keyboard-layout diagram | rounded boxes | square boxes |

## 🧭 Left to the builder

- The shape of the theme module, and which applications use `catppuccin/nix` and which are generated from the roles.
- Producing the wallpaper and the lock image from a user's own image. Today a Python tool called `backdrop` draws both, and it ports to Odin with the other tools. It must accept a user's image and place the marks as described.
- The login greeter's exact values, within the rules above.
- The logo itself. No file exists yet, and the wallpaper, the lock image, the README header and the bar icon wait for it. Until it exists, the wordmark `ravnix` in the font and the accent stands in. It must read at 16 px. The ravnix and phyllon marks are drawn at the same size, on the shipped default and on the author's own wallpaper. The phyllon mark exists as an SVG.
- GTK and Qt assets for each accent in the option's list.
- Installing the userstyles. Stylus in the browser plus the userstyles repository is the mechanism. Whether the flake installs them declaratively or documents a manual step depends on what the browser allows.
