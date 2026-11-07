# Mail in aerc, on the server. The accounts are ravnix.mail; the password of
# each is an item of the vault that aerc reads through rbw whenever it
# connects (`source-cred-cmd`, `outgoing-cred-cmd`), so no password is in
# accounts.conf, the store or the home directory. rbw must be unlocked
# (`ai-unlock`) for aerc to connect: the agent holds the vault, nothing else.
#
# accounts.conf is a file of the store, so aerc's check for owner-only
# permissions is switched off (unsafe-accounts-conf); that is safe because the
# file holds a command, not a credential.
#
# Style (docs/style.md, rule 9): the Catppuccin port draws aerc in the accent
# with single-line borders, which is the rule for a TUI.
{ config, lib, ... }:
let
  os = config;
  user = os.ravnix.user.username;
  mail = os.ravnix.mail;
in
{
  home-manager.users.${user} =
    { config, ... }:
    {
      programs.aerc = {
        enable = true;
        extraConfig.general.unsafe-accounts-conf = true;
      };
      catppuccin.aerc.enable = true;

      accounts.email.accounts = lib.mapAttrs (
        _: account:
        let
          rbw = lib.getExe' config.programs.rbw.package "rbw";
        in
        {
          primary = account.primary || lib.length (lib.attrNames mail) == 1;
          inherit (account) address;
          realName = os.ravnix.user.name;
          userName = if account.login != null then account.login else account.address;
          passwordCommand = [
            rbw
            "get"
            "--"
            (lib.escapeShellArg account.passwordItem)
          ];
          imap = {
            inherit (account.imap) host port;
            tls.enable = true;
          };
          smtp = {
            inherit (account.smtp) host port;
            tls = {
              enable = true;
              useStartTls = account.smtp.starttls;
            };
          };
          aerc.enable = true;
        }
      ) mail;
    };
}
