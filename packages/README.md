# packages

What nixpkgs lacks, as derivations. Each directory here is one package, and
the flake finds it: adding a package never touches `flake.nix`.

| Path | Holds |
| --- | --- |
| `NAME/default.nix` | the package: a function for `callPackage` that returns a derivation |
| `NAME/...` | anything else the package needs (sources, patches, tests), as it likes |
| `README.md` | this file, which is no package |

Every `packages/NAME/` becomes `packages.x86_64-linux.NAME` and
`pkgs.ravnix.NAME` (`lib/discover-packages.nix`). The second is what a module
reads, so it never needs `self`, which the modules under `modules/desktop/` and
`modules/glue/` do not get: `nixosModules.common` applies `overlays.default`,
which puts the packages under `pkgs.ravnix` for the NixOS modules and, because
home-manager uses the system's `pkgs`, for the user's home-manager modules too.
`nixosModules.desktop` and `nixosModules.glue` bring `nixosModules.common`
along. A host or a private flake that applies the overlay as well changes
nothing, since it sets the one attribute `ravnix` to the same value each time.

```nix
# packages/NAME/default.nix
{ stdenvNoCC, fetchurl, lib }:
stdenvNoCC.mkDerivation {
  pname = "NAME";
  # ...
}
```

A configuration whose `pkgs` is read-only, such as a NixOS VM test node,
takes no overlay from a module, and `nixosModules.common` leaves it alone.
Whoever hands over that `pkgs` applies the overlay to it; without it a module
that reads `pkgs.ravnix.NAME` fails with "attribute ravnix missing". In a
`pkgs.testers.runNixOSTest` that is
`node.pkgs = lib.mkForce (pkgs.extend self.overlays.default);` since
`runNixOSTest` defines `node.pkgs` itself, and a plain definition fails with "A
Nixpkgs pkgs set can not be merged with another pkgs set".

The same pkgs must allow the unfree packages that `nixosModules.desktop`
installs, because the module cannot set `nixpkgs.config` there (it leaves it
alone on a read-only pkgs). `lib/unfree.nix` holds the names, and a pkgs built
by hand takes them as its predicate:

```nix
import inputs.nixpkgs {
  inherit system;
  config.allowUnfreePredicate = (import ./lib/unfree.nix { inherit lib; }).predicate {
    packetTracer = false; # the values of ravnix.apps.packetTracer and .widevine
    widevine = false;
  };
  overlays = [ self.overlays.default ];
}
```

`tests/desktop/vm-node.nix` evaluates such a node and shows what happens
without each part.

A package that needs another takes `ravnix` and reads it from there, as
`{ ravnix, ... }: ... ravnix.OTHER`. `packages.x86_64-linux` is built through
the overlay too, so it is the same package as `pkgs.ravnix.NAME`.

The Odin tools (`tools/NAME`) are under `pkgs.ravnix.NAME` too, built with the
same package set. With a nixpkgs that follows ravnix's, as the template's does,
that is the derivation of `packages.x86_64-linux.NAME`, the one the tool's
checks vouch for (`tests/flake/packages.nix` compares the two). Only
`packages.claude-code` is left out: it is the download the gate verifies against
Anthropic's release manifest for the version in `flake.lock`, and a second route
to it would be one that the verification and the update timer do not control.
`lib/ravnix-packages.nix` has the rest.

A tool is built twice: under the overlay with the host's package set as its
`pkgs`, and for `packages.x86_64-linux.NAME` and its own checks with the flake's
`pkgs`. So a tool must not read `pkgs.ravnix`: it would build under the overlay
and fail its checks with "attribute ravnix missing". Packages have the
`ravnix` argument for that; tools have no sibling route.

## Not here, but with a step by hand: Packet Tracer

Cisco Packet Tracer is in nixpkgs (`cisco-packet-tracer_9`), so there is no
package of ours. Cisco's download needs a login, so no build can fetch the
`.deb`, and nixpkgs asks the Nix store for it by name and hash. That makes it a
step for the person who owns the machine that builds the host, and why
`ravnix.apps.packetTracer` is off unless set:

1. Download "Packet Tracer 9.0.1 for Linux (Ubuntu)" from the Networking
   Academy (https://www.netacad.com/resources/lab-downloads).
2. On the machine that builds the host, add it once:
   `nix-store --add-fixed sha256 CiscoPacketTracer_901_Ubuntu_64bit.deb`. The
   name must be exactly that; the hash is
   `sha256-NoPdh+d5iFNyrpo1wabllNEvST5knnxpdAhynBRZR5s=`.
3. Set `ravnix.apps.packetTracer = true;` in `me.nix`.

Until the file is in the store, a host that asks for it stops at the build with
a message naming both. `tests/desktop/apps.nix` checks the name and hash against
nixpkgs, and `modules/desktop/apps.nix` repeats the step in its header.

## What the flake refuses

Each of these is an evaluation error that names the path, never a silent skip:

- a directory without `default.nix`;
- a `.nix` file or a symlink directly in `packages/` (a file that is no `.nix`
  file, like this one, is ignored);
- a package named like a tool (`tools/NAME`), or `claude-code`, which is the
  flake's own `packages.claude-code`; and a tool named `claude-code`.

A missing `packages/` directory gives no packages.

## Findings that are not fixed

- A hidden regular `.x.nix` file in `modules/desktop/` or `modules/glue/` (an
  editor backup, say) is imported like any other `.nix` file. A flake source
  holds only tracked files, so it needs a committed one; a symlink of that
  kind is the symlink error.
- Tools reach `pkgs.ravnix` built with the package set of the host, not the
  flake's. A host whose nixpkgs differs from the flake's, or an overlay of its
  own that touches the compiler, gets a different binary than the one the
  tool's checks ran.
