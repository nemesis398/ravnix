# chrome-devtools-mcp-helium

The Chrome DevTools MCP server (`packages/chrome-devtools-mcp`) driving a
headless Helium (`packages/helium`) whose built-in uBlock Origin is switched
off, carried over from the Fedora setup (commit `c76dfe0`,
`stow/bin-chrome-devtools-mcp-helium`). Claude Code starts it over stdio as the
user-scope MCP server `chrome-devtools` on both hosts
(`modules/common/chrome-devtools-mcp.nix`). The header of
`chrome-devtools-mcp-helium.sh` holds the root cause that makes the wrapper
necessary: Helium's uBlock Origin reloads every tab that made requests before
its filter lists were loaded, so the server's first `navigate_page` fails with
`net::ERR_ABORTED` and `new_page` hangs, and no flag keeps the extension out.

Every launch gets a directory of its own, `cdh.PID.XXXXXX` (mode 700), with two
directories in it: `profile/`, whose `Default/Preferences` mark the extension
(`blockjmkbacgjkknlgpkjjiijinjdanf`) as switched off by the user
(`disable_reasons: [1]`), and `t/`, an empty directory that is the `TMPDIR` of
the server and the browser. The profile is per launch because a second browser
on a shared profile refuses to start. The wrapper passes `TERM`, `INT` and `HUP`
on to the server, removes the directory when the server ends, and removes the
directories of wrappers that were killed (their PID is in the name). A third
file, `owner`, holds the boot id and the start time of the wrapper, so that a
leftover from before a reboot, or one whose PID went to another process, is
recognized as gone and not taken for a running launch.

## Changed from the original

- The server and the browser are store paths (`chrome-devtools-mcp`,
  `helium`), and no `npx` runs. `CHROME_DEVTOOLS_HELIUM` still overrides the
  browser.
- The server is told not to look for a newer version
  (`CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1`). Its check starts a detached
  process that asks the npm registry; Nix decides the version.
- Where the launch goes. The original used `${TMPDIR:-/tmp}` and only said "keep
  TMPDIR short" (Chromium's singleton socket is under TMPDIR, and a socket path
  is limited to 108 bytes; a longer one makes the browser exit at once, which
  the server reports as "Target closed"). The wrapper now takes the first of
  `TMPDIR` and `/tmp` that is a writable directory of at most 40 bytes (bytes,
  not characters: the length is taken in the C locale) and is not inside
  `XDG_RUNTIME_DIR`, and says on stderr why it passed one over. Measured with
  Helium 0.21.1.1: a `TMPDIR` of 62 bytes starts, one of 63 aborts; the socket is
  46 bytes, `/cdh.PID.XXXXXX/t` is 21 with a 7-digit PID, so 40 leaves a byte to
  spare. The VM test starts the real Helium with a `TMPDIR` of exactly 40 bytes and
  a 7-digit PID (it sets `/proc/sys/kernel/ns_last_pid` to 1999989 first).
- A `TMPDIR` of its own for every launch, never the runtime directory. The server
  writes the files its tools make (screenshots, Lighthouse reports, screencasts)
  to `chrome-devtools-mcp-XXXXXX` directories under `os.tmpdir()` and never
  removes them, and its file tools (the `filePath` of screenshots, traces and
  heap snapshots, `upload_file`) may read and write below it. With
  `XDG_RUNTIME_DIR` as `TMPDIR`, as the first version of this port had it, those
  files would pile up in RAM, and the root of the file tools would cover the
  user's sockets and credentials. With `t/` the root is an empty private
  directory that goes with the launch. (`XDG_RUNTIME_DIR` itself is left
  alone: the wrapper does not change it, and the browser needs nothing there.)
  A client that sends roots of its own adds them, and the server accepts paths
  in them as well.
- The test of the original, 12 tests against a stub `npx`, is
  `tests/wrapper.test.sh` on top of `scripts/tests/lib.sh`, against stand-ins for
  the server (`tests/stub-server.sh`) and the browser, 36 tests in all. The
  check `common-chrome-devtools-mcp-helium` builds the wrapper with the
  stand-ins, runs them, and then looks at the real wrapper. Every path the
  wrapper reads is a throwaway tree (`CHROME_DEVTOOLS_HELIUM_FALLBACK_TMP`
  names the directory it uses in place of `/tmp`, only so that tests can reach
  it); no test touches `/tmp` or a home.
  `tests/desktop/chrome-devtools-mcp.nix` runs the real server and the real
  Helium in two VMs, on the desktop and on the server shape.

## Findings that are not fixed

- A launch of a wrapper killed with SIGKILL is removed by the next launch, not
  at once, and only from the directory that launch uses. A `TMPDIR` that changes
  between launches (short, then long) leaves the first directory's launch
  until a launch uses that directory again.
- A launch with no usable `owner` file (one an older wrapper made, or one whose
  wrapper stopped between making the directory and writing the file) goes by the
  PID in its name alone, and stays while a process has that PID.
- The sweep skips what is not a directory of the user's own (`stat` does not
  follow a link, so a link another user planted in `/tmp` is left alone, and a
  failing removal only prints a line). The tests cover a link of the user's own
  and a directory that cannot be removed; a link or directory owned by another
  user needs a second account, which the sandbox of the checks does not have, so
  that case has no test.
- A stop that arrives before the server exists is recorded by the handler that
  the wrapper installs first, and passed on right after the server starts. The
  tests show that the handler comes first (the order of a `bash -x` trace) and
  that a stop during a long sweep reaches the server afterwards. The last case,
  a signal between the fork and the assignment of `$!`, has a window of
  nanoseconds and no test.
- Only two variables are unset to keep the browser's sandbox on
  (`PUPPETEER_DANGEROUS_NO_SANDBOX` and `CHROME_DEVEL_SANDBOX`): they are the
  only ones that the code of server 1.12.0 and the bundled Puppeteer read for
  it. A later version may read more. `--chrome-arg=--no-sandbox` on the command
  line of the server would still work: the wrapper passes its arguments on, and
  the entry that ravnix declares has none.
- uBlock Origin being off is checked in the profile's `Preferences` while the
  server runs (VM test). The server forbids `chrome:` URLs and lists only the
  extensions it installed itself, so nothing can ask the running browser
  whether the extension is loaded.
- The race the wrapper exists for could not be reproduced on a local page on a
  fast machine (six launches with a plain profile all navigated), so no test
  shows the failure without the wrapper. It was measured on Fedora against real
  pages on 2026-11-07.
- The wrapper package is built without import-from-derivation (the script is
  read with `builtins.readFile` and its two placeholders replaced in the
  string). No check enforces it; `nix eval --option allow-import-from-derivation
  false .#packages.x86_64-linux.chrome-devtools-mcp-helium.outPath` shows it.
