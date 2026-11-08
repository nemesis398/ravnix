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

Every launch gets a fresh profile whose `Default/Preferences` mark the
extension (`blockjmkbacgjkknlgpkjjiijinjdanf`) as switched off by the user
(`disable_reasons: [1]`). The profile is per launch because a second browser on
a shared profile refuses to start. The wrapper passes `TERM`, `INT` and `HUP`
on to the server, removes its profile when the server ends, and removes the
profiles of wrappers that were killed (their PID is in the directory name).

## Changed from the original

- The server and the browser are store paths (`chrome-devtools-mcp`,
  `helium`), and no `npx` runs. `CHROME_DEVTOOLS_HELIUM` still overrides the
  browser.
- The server is told not to look for a newer version
  (`CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1`). Its check starts a detached
  process that asks the npm registry; Nix decides the version.
- Where the profile goes. The original used `${TMPDIR:-/tmp}` and only said "keep
  TMPDIR short" (Chromium's singleton socket is under TMPDIR, and its path is
  limited to 107 characters; a longer one makes the browser exit at once, which
  the server reports as "Target closed"). The wrapper now takes the first of
  `TMPDIR`, `XDG_RUNTIME_DIR` and `/tmp` that is a writable directory of at most 60
  characters, says on stderr why it passed one over, and hands the server that
  directory as `TMPDIR`. The profile and the socket are never under a path the
  caller made long.
- The test of the original, 12 tests against a stub `npx`, is
  `tests/wrapper.test.sh` on top of `scripts/tests/lib.sh`, against stand-ins for
  the server (`tests/stub-server.sh`) and the browser, 27 tests in all. The
  check `common-chrome-devtools-mcp-helium` builds the wrapper with the
  stand-ins, runs them, and then looks at the real wrapper. Every path the
  wrapper reads is a throwaway tree; no test touches `/tmp` or a home.
  `tests/desktop/chrome-devtools-mcp.nix` runs the real server and the real
  Helium in two VMs, on the desktop and on the server shape.

## Findings that are not fixed

- A profile of a wrapper killed with SIGKILL is removed by the next launch, not
  at once, and only from the directory that launch uses. A TMPDIR that changes
  between launches (short, then long) leaves the first directory's profile
  until a launch uses that directory again.
- A wrapper whose PID was reused by an unrelated process keeps its dead profile
  until that process ends.
- Before the wrapper installs its signal trap, a signal kills it by default and
  the server it just started is orphaned. The window is a few milliseconds.
- uBlock Origin being off is checked in the profile's `Preferences` while the
  server runs (VM test). The server forbids `chrome:` URLs and lists only the
  extensions it installed itself, so nothing can ask the running browser
  whether the extension is loaded.
- The race the wrapper exists for could not be reproduced on a local page on a
  fast machine (six launches with a plain profile all navigated), so no test
  shows the failure without the wrapper. It was measured on Fedora against real
  pages on 2026-11-07.
