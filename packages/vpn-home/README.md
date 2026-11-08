# vpn-home

The switch of the VPN gateway at home: `vpn-home [on|off|status]` calls the
gateway's small HTTP API with a bearer token from Bitwarden and prints the
answer through `jq`. It is the script of the Fedora laptop, `vpn-home.bash`,
packaged with `writeShellApplication`, so shellcheck ran over it at build time.

## What differs from the Fedora script

- **The gateway and the token item are baked in.** They come from
  `ravnix.vpn.home` (`apiUrl`, `tokenItem`) through the package arguments of
  the same names; `VPN_HOME_API` and `VPN_HOME_TOKEN_ITEM` in the environment
  win. Built with neither, the command works from the environment alone, and
  says which option to set when both are missing. The check happens after the
  arguments are read, so a typo in the command still gets its usage text.
- The comment that named the network, the ticket and the repository of the
  gateway is worded in general terms.

## Tests

`tests/desktop/helpers/wrappers.test.bash` (the check `desktop-printing`)
runs it against stand-ins for rbw and curl: `on`, `off` and `status` with the
method, path and baked gateway; the token on curl's standard input and on no
command line, and not printed; the default command; an unknown command before
the token is read; a locked vault; a dead gateway; a gateway that answers
something that is not JSON; the environment in place of baked values; nothing
set at all.

## Findings that are not fixed

- `rbw get` has no timeout of its own. If the vault wants a master password
  and no pinentry can show, the command waits for it.
- `curl -f` hides the body of an HTTP error, so the gateway's reason for a
  refusal (a wrong token, a call from the wrong network) is not shown, only
  curl's status line.
- A reply that is valid JSON of an unexpected shape is printed as it is.
