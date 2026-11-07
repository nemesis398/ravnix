# Ravnix

Ravnix is a NixOS flake that makes a laptop and a server one system. The
laptop shape, `huginn`, runs the graphical applications. The server shape,
`muninn`, runs the terminal applications, so a session keeps running when the
lid closes or the connection drops. Both are built from the same modules, and
the shell, the tools and the look are the same on each.

The flake holds no personal values. You keep yours in a private flake of your
own that imports this one, starting from the template in `templates/default/`.

## Status

A skeleton, nothing to install yet. The public-boundary check, the typed
options and the private-flake template come first, then the shared modules
and the two hosts.

## Read on

- [Style](docs/style.md): how ravnix looks, and the checklist for styling
  anything new.
- [AGENTS.md](AGENTS.md): the rules for AI agents working in this repository.

## License

[AGPL-3.0-or-later](LICENSE). The authors are listed in [AUTHORS](AUTHORS).
