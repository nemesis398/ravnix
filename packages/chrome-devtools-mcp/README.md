# chrome-devtools-mcp

The Chrome DevTools MCP server 1.12.0, built from the upstream tag
`chrome-devtools-mcp-v1.12.0` of
[ChromeDevTools/chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp).
nixpkgs has no package for it (checked at the revision `flake.lock` pins, Task
3.9). Nothing runs `npx` at runtime: Claude Code starts the wrapper
`chrome-devtools-mcp-helium` (the next package), which runs this one from the
store.

## What the build does

Upstream publishes one bundle, and `npm run bundle` makes it: `tsc` compiles the
server together with the TypeScript of devtools-frontend, and rollup folds
every dependency in, which is why the npm package has no dependencies and the
lock file lists only development dependencies. The package here runs that same
script with `buildNpmPackage`, offline:

- the dependencies come from `package-lock.json` (`npmDepsHash`);
- devtools-frontend is a git submodule of the tag (`third_party/devtools-frontend`,
  pinned to the commit the tag names), and a GitHub archive of the tag does not
  hold it, so it is a second fixed-output fetch that `postPatch` copies in;
- `PUPPETEER_SKIP_DOWNLOAD=1`, because puppeteer's install script would fetch a
  Chrome the server never uses (it is pointed at a browser by `--executablePath`);
- `NODE_ENV=production` for the build only, as upstream's release build has it.
  As an attribute it would make `npm ci` leave out the development
  dependencies, which are all of them;
- upstream's `prepare` script runs once in `preBuild`. It checks the submodule
  and removes a global declaration of `@paulirish/trace_engine` that `tsc`
  would otherwise report twice. `npm ci --ignore-scripts` skips it.

The result is what `npm pack` would ship (`build/src`, `skills`, `LICENSE`),
15 MB, with `bin/chrome-devtools-mcp` and `bin/chrome-devtools`.

## Updating

1. Find the release: <https://github.com/ChromeDevTools/chrome-devtools-mcp/releases>.
2. Set `version` in `default.nix`.
3. `nix store prefetch-file --json --unpack https://github.com/ChromeDevTools/chrome-devtools-mcp/archive/refs/tags/chrome-devtools-mcp-vVERSION.tar.gz`,
   and put the `hash` into `src`.
4. The submodule's commit:
   `curl -s https://api.github.com/repos/ChromeDevTools/chrome-devtools-mcp/git/trees/chrome-devtools-mcp-vVERSION | jq '.tree[] | select(.mode == "160000")'`.
   Put its `sha` into `devtoolsFrontend.rev`, and prefetch
   `https://github.com/ChromeDevTools/devtools-frontend/archive/SHA.tar.gz` the
   same way for its `hash`.
5. `prefetch-npm-deps package-lock.json` on the new tag's lock file gives
   `npmDepsHash` (or build once with `lib.fakeHash`).
6. Check what `prepare.ts` and `post-build.ts` do still holds (they changed
   between releases before), then
   `nix build .#checks.x86_64-linux.common-chrome-devtools-mcp-helium` and
   `nix build .#checks.x86_64-linux.desktop-chrome-devtools-mcp`.
7. The wrapper passes flags by name (`--executablePath`, `--userDataDir`,
   `--headless`, `--no-usage-statistics`, `--no-performance-crux`). `--help` of
   the new version must still list each.

## Findings that are not fixed

- Rollup records the commit of devtools-frontend in
  `build/src/third_party/bundled-packages.json` by running `git rev-parse` in the
  submodule. The build has no git, so that entry is missing (the build log says
  `git: not found` twice). The file is metadata for the licence notices and
  nothing reads it at runtime.
- The wrapper (`bin/chrome-devtools-mcp`) is `nodejs` (the full package, with npm)
  started on the bundle, so the closure holds npm and corepack. `nodejs-slim`
  would be smaller, but `buildNpmPackage` needs npm to build, and a second node
  for the runtime only is not worth 100 MB on a host that has Node anyway.
- Since 1.12.0 the page-scoped tools take a required `pageId`
  (`--no-page-id-routing` turns that off). A client calls `list_pages` first.
  The VM test's client does, and so does Claude Code.
- The server prints a usage-statistics notice and a CrUX notice on stderr unless
  `--no-usage-statistics` and `--no-performance-crux` are given; the wrapper
  gives both, and the VM test checks that the notices are gone.
