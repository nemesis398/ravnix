# vpn-home: the switch of the VPN gateway at home (`vpn-home on|off|status`),
# carried over from the Fedora laptop (vpn-home.bash). The gateway's address
# and the Bitwarden item with its token are personal values: modules/desktop/
# vpn.nix builds the command with ravnix.vpn.home, and without them it reads
# VPN_HOME_API and VPN_HOME_TOKEN_ITEM from the environment.
{
  lib,
  writeShellApplication,
  rbw,
  curl,
  jq,
  apiUrl ? null,
  tokenItem ? null,
}:
writeShellApplication {
  name = "vpn-home";
  runtimeInputs = [
    rbw
    curl
    jq
  ];
  text =
    lib.replaceStrings
      [ "@apiUrl@" "@tokenItem@" ]
      [
        (lib.escapeShellArg (toString apiUrl))
        (lib.escapeShellArg (toString tokenItem))
      ]
      (builtins.readFile ./vpn-home.bash);
  meta = {
    description = "Switch the VPN gateway at home on and off";
    mainProgram = "vpn-home";
  };
}
