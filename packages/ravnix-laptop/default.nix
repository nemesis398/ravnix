# ravnix-laptop: run a command on huginn, the laptop, from muninn, the server,
# over NetBird (`ravnix-laptop COMMAND [ARGUMENT...]`). Thin Bash glue over
# ssh, packaged with writeShellApplication, so shellcheck runs over it at
# build time. The laptop's NetBird address, the account, the private key and
# the laptop's host key are personal values: modules/glue/laptop-access.nix
# builds the command with ravnix.hosts.huginn.address, ravnix.user.username
# and ravnix.laptopAccess. Built with none of them it says which to set, and
# exits 78.
#
# sshCommand is the ssh to run, for the tests' stand-in. hostKey is one line of
# a .pub file; it is written into a known_hosts file of the store as `huginn
# KEY`, where the command finds it, and must not hold a newline (the option
# that feeds it refuses one).
{
  lib,
  writeShellApplication,
  writeText,
  openssh,
  coreutils,
  address ? null,
  user ? null,
  identityFile ? null,
  hostKey ? null,
  sshCommand ? lib.getExe' openssh "ssh",
}:
let
  knownHosts = writeText "ravnix-laptop-known-hosts" "huginn ${hostKey}\n";
  word = value: lib.escapeShellArg (toString value);
in
writeShellApplication {
  name = "ravnix-laptop";
  runtimeInputs = [ coreutils ];
  text =
    lib.replaceStrings
      [ "@address@" "@user@" "@identityFile@" "@knownHosts@" "@sshCommand@" ]
      [
        (word address)
        (word user)
        (word identityFile)
        (if hostKey == null then "''" else word knownHosts)
        (word sshCommand)
      ]
      (builtins.readFile ./ravnix-laptop.bash);
  meta = {
    description = "Run a command on the laptop from the server over NetBird";
    mainProgram = "ravnix-laptop";
  };
}
