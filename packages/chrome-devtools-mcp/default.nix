# The Chrome DevTools MCP server, built from the upstream tag. nixpkgs lacks
# it (checked at the revision flake.lock pins, Task 3.9). See README.md for
# the update steps and what the build does.
#
# Upstream ships one bundle: `npm run bundle` compiles the server with the
# TypeScript of devtools-frontend's front_end (a git submodule, third_party/
# devtools-frontend, which a GitHub archive of the tag does not hold), and
# rollup folds every dependency in, so the npm package has no dependencies of
# its own. The build here does the same from the tag and the submodule's
# pinned commit, and runs nothing from the network: the dependencies come from
# the lock file (npmDepsHash), the submodule from its own fixed-output fetch.
{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
}:
let
  # The commit the tag's submodule entry names:
  #   gh api repos/ChromeDevTools/chrome-devtools-mcp/git/trees/TAG |
  #     jq '.tree[] | select(.mode == "160000")'
  devtoolsFrontend = fetchFromGitHub {
    owner = "ChromeDevTools";
    repo = "devtools-frontend";
    rev = "f22c645573adc85e4553747c577eebb874c3fb43";
    hash = "sha256-Lst8HJczmpxxN/0Q9cG+Pxzhz/C91dGUpxPr8N5XHDQ=";
  };
in
buildNpmPackage (finalAttrs: {
  pname = "chrome-devtools-mcp";
  version = "1.12.0";

  src = fetchFromGitHub {
    owner = "ChromeDevTools";
    repo = "chrome-devtools-mcp";
    tag = "chrome-devtools-mcp-v${finalAttrs.version}";
    hash = "sha256-Y/9jlYVHGbRtD8w8Y93WP0O2nzKspVBKcisewxC1Tew=";
  };

  npmDepsHash = "sha256-CEYtrmCDO+EeKoScH8IO+jsJCrkvzJKqqeoT+yqD1FU=";

  # puppeteer fetches a Chrome in its install script; the server is pointed at
  # a browser by --executablePath, so none is wanted.
  env.PUPPETEER_SKIP_DOWNLOAD = "1";

  postPatch = ''
    rmdir third_party/devtools-frontend
    cp -r --no-preserve=mode ${devtoolsFrontend} third_party/devtools-frontend
  '';

  # `bundle` is upstream's release build: clean, tsc, post-build, rollup.
  npmBuildScript = "bundle";

  preBuild = ''
    # Production, as upstream's release build runs it (no source maps). Set
    # here and not as an attribute: npm would then leave out the development
    # dependencies, which are all of them.
    export NODE_ENV=production
    # What upstream's `prepare` script does besides the submodule: it removes
    # a global declaration that the compiler would otherwise report twice.
    node scripts/prepare.ts
  '';

  meta = {
    description = "Chrome DevTools for coding agents, as an MCP server";
    homepage = "https://github.com/ChromeDevTools/chrome-devtools-mcp";
    changelog = "https://github.com/ChromeDevTools/chrome-devtools-mcp/releases/tag/chrome-devtools-mcp-v${finalAttrs.version}";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
    mainProgram = "chrome-devtools-mcp";
  };
})
