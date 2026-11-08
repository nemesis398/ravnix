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

## What the flake refuses

Each of these is an evaluation error that names the path, never a silent skip:

- a directory without `default.nix`;
- a `.nix` file or a symlink directly in `packages/` (a file that is no `.nix`
  file, like this one, is ignored);
- a package named like a tool (`tools/NAME`), or `claude-code`, which is the
  flake's own `packages.claude-code`; and a tool named `claude-code`.

A missing `packages/` directory gives no packages.

## Findings that are not fixed

- While `packages/` is empty, the tests of the real wiring
  (`tests/flake/packages.nix`) compare names and derivations over no packages,
  and the tool part is the only one that checks anything; the first package
  makes the rest meaningful. The discovery, its refusals, the overlay and the
  lookup of a sibling through `ravnix` run on fixtures, through the same
  `lib/ravnix-packages.nix` the flake calls. The same holds for
  `modules/desktop/default.nix` and `modules/glue/default.nix` while those
  directories hold no module (`tests/flake/desktop-imports.nix`): each is
  compared with its own directory, so `[ ] == [ ]`, and a wrong label string in
  one of them shows only in the message about a symlink.
- A hidden regular `.x.nix` file in `modules/desktop/` or `modules/glue/` (an
  editor backup, say) is imported like any other `.nix` file. A flake source
  holds only tracked files, so it needs a committed one; a symlink of that
  kind is the symlink error.
- Tools reach `pkgs.ravnix` built with the package set of the host, not the
  flake's. A host whose nixpkgs differs from the flake's, or an overlay of its
  own that touches the compiler, gets a different binary than the one the
  tool's checks ran.
