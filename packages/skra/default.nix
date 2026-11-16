# skrá, a small web interface for CUPS: printers with their ink levels, the
# queue, the CUPS log, and (on a branch that is not pushed yet) scanning. It
# listens on 127.0.0.1 only and is started by a socket unit on the first
# request (modules/desktop/skra.nix). Source: https://github.com/nemesis398/skra,
# AGPL-3.0-or-later.
#
# What the upstream build does, and this does the same (Makefile: `go build -o
# skra ./cmd/skra`): no ldflags, no tags and no version string. The page
# templates and static files are embedded with go:embed (web/embed.go), so the
# binary needs nothing beside itself. SQLite is modernc.org/sqlite, pure Go, so
# there is no cgo and no C library.
#
# The pinned revision is the newest one on GitHub (origin/main of the author's
# checkout). The author's local main has more commits that are not pushed
# (scanning, cmd/fakescanner), and a bump takes them once they are.
#
# skra has no --help and no --version: it starts serving whatever its
# arguments are, so tests/desktop/skra.nix runs the program with a config
# instead.
#
# The tests: `go test ./...` runs the unit tests. The ones that need the
# podman harness (a CUPS in a container and a virtual printer) carry the build
# tag `integration`, which is not set here, so they are not compiled. The
# others that depend on the machine skip themselves (a local name that must
# resolve, an ippeveprinter on 8631, a real CUPS socket).
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule {
  pname = "skra";
  version = "0-unstable-2026-11-15";

  src = fetchFromGitHub {
    owner = "nemesis398";
    repo = "skra";
    rev = "487524a06bf81ed60e4d4beefac49b7bf939c050";
    hash = "sha256-eTOSVn71Xj8JHBsDmBP5hArz6oA/eavFJDjKamNhc6Q=";
  };

  vendorHash = "sha256-VmhKOkE1pcpkFkZ2VH43DOsZ7MBUFcacG5Kanzf8+eE=";

  # subPackages would also narrow the tests to cmd/skra, which has none; with
  # everything built, the tests of internal/ run. cmd/fakescanner (a stand-in
  # eSCL scanner for `make dev`, on the unpushed branch) is not shipped.
  excludedPackages = [ "cmd/fakescanner" ];

  env.CGO_ENABLED = "0";

  # The build sandbox's host name is "localhost". That test takes the host name
  # for a name that only the dial can tell is local, but "localhost" is
  # recognised by its spelling before any dial, so the test's guard is never
  # asked and it fails ("the guard was never asked"). On a machine with a host
  # name of its own it passes; the program is not at fault.
  checkFlags = [ "-skip=^TestQueryRefusesANameThatOnlyTheDialSeesIsLocal$" ];

  meta = {
    description = "Web interface for CUPS: printers, ink levels, queue and log";
    homepage = "https://github.com/nemesis398/skra";
    license = lib.licenses.agpl3Plus;
    mainProgram = "skra";
    platforms = lib.platforms.linux;
  };
}
