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
reads, so it never needs `self`: `nixosModules.common` applies
`overlays.default`, which puts the packages under `pkgs.ravnix` for the NixOS
modules and, because home-manager uses the system's `pkgs`, for the user's
home-manager modules too. A host or a private flake that applies the overlay as
well changes nothing, since it sets the one attribute `ravnix` to the same
value each time.

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
Whoever hands over that `pkgs` applies the overlay to it
(`pkgs.extend self.overlays.default`); without it a module that reads
`pkgs.ravnix.NAME` fails with "attribute ravnix missing".

A package that needs another takes `ravnix` and reads it from there, as
`{ ravnix, ... }: ... ravnix.OTHER`. `packages.x86_64-linux` is built through
the overlay too, so it is the same package as `pkgs.ravnix.NAME`.

Only these packages are under `pkgs.ravnix`. The Odin tools (`tools/`) and
`packages.claude-code` are not: they are packages of the flake, and a module
that needs one reads it from `self`.

## What the flake refuses

Each of these is an evaluation error that names the path, never a silent skip:

- a directory without `default.nix`;
- a `.nix` file or a symlink directly in `packages/` (a file that is no `.nix`
  file, like this one, is ignored);
- a package named like a tool (`tools/NAME`), or `claude-code`, which is the
  flake's own `packages.claude-code`.

A missing `packages/` directory gives no packages.

## Findings that are not fixed

- The tests that the flake wires `packages/` in (`tests/flake/packages.nix`)
  compare names and, for each package, the derivation, so they check little
  while `packages/` is empty; the first package makes them meaningful. The
  discovery, its refusals and the lookup of a sibling through `ravnix` run on
  fixtures. The same holds for `modules/desktop/default.nix` and
  `modules/glue/default.nix` while those directories hold no module
  (`tests/flake/desktop-imports.nix`).
