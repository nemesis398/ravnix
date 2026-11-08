# nord: NordVPN as a plain NetworkManager WireGuard (NordLynx) profile, with
# no Nord app and no daemon (`nord status|up|down|toggle|refresh|setup`),
# carried over from the Fedora laptop (nord.bash). The country, the Bitwarden
# item with the access token and the one that receives a copy of the key are
# personal values: modules/desktop/vpn.nix builds the command with
# ravnix.vpn.nord, and without them it reads NORD_COUNTRY_ID, NORD_TOKEN_ITEM
# and NORD_KEY_ITEM from the environment. The key and the token are read from
# Bitwarden by rbw at the moment they are used and never enter the store.
#
# The script keeps its own `set -uo pipefail` and no errexit, as it had on
# Fedora: its functions test commands and carry on.
{
  lib,
  writeShellApplication,
  networkmanager,
  curl,
  jq,
  rbw,
  libnotify,
  coreutils,
  gnugrep,
  countryId ? null,
  tokenItem ? null,
  keyItem ? null,
}:
writeShellApplication {
  name = "nord";
  runtimeInputs = [
    networkmanager
    curl
    jq
    rbw
    libnotify
    coreutils
    gnugrep
  ];
  bashOptions = [ ];
  text =
    lib.replaceStrings
      [ "@countryId@" "@tokenItem@" "@keyItem@" ]
      [
        (lib.escapeShellArg (toString countryId))
        (lib.escapeShellArg (toString tokenItem))
        (lib.escapeShellArg (toString keyItem))
      ]
      (builtins.readFile ./nord.bash);
  meta = {
    description = "NordVPN as a NetworkManager WireGuard profile";
    mainProgram = "nord";
  };
}
