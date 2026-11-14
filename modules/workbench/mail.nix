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
# Style (docs/style.md): the styleset is written from the roles. The
# Catppuccin port has no accent, draws the border in Crust, which cannot be
# seen on Base, and marks links and diff hunks in Blue, a state hue. Here the
# selected tab is the strip's one accent fill with Crust text, a link and a
# search result are the accent, the frame is Surface2, the selected message is
# Surface1 and a selected folder, when the list is not the focus, Surface0.
# Errors are Red, warnings Peach, a diff line Green or Red. The border is the
# single light line.
{ config, lib, ... }:
let
  os = config;
  user = os.ravnix.user.username;
  mail = os.ravnix.mail;
  inherit (os.ravnix.theme) palette roles;

  # name=color lines for the styleset, in sections.
  styleset = ''
    *.default=true
    *.normal=true

    default.fg=${roles.text}
    default.bg=${roles.canvas}

    error.fg=${palette.red}
    warning.fg=${palette.peach}
    success.fg=${palette.green}

    tab.fg=${roles.muted}
    tab.bg=${roles.dock}
    tab.selected.fg=${roles.deepest}
    tab.selected.bg=${roles.accent}
    tab.selected.bold=true

    border.fg=${roles.line}
    border.bold=false

    title.fg=${roles.label}
    title.bg=${roles.dock}
    header.fg=${roles.label}

    msglist_unread.bold=true
    msglist_flagged.fg=${palette.yellow}
    msglist_flagged.bold=true
    msglist_result.fg=${roles.accent}
    msglist_result.bold=true
    msglist_*.selected.bold=true
    msglist_*.selected.bg=${roles.selected}

    dirlist_*.selected.bold=true
    dirlist_*.selected.bg=${roles.wash}

    statusline_default.fg=${roles.secondary}
    statusline_default.bg=${roles.dock}
    statusline_error.bold=true
    statusline_success.bold=true

    selector_focused.bg=${roles.selected}
    selector_chooser.bold=true

    completion_default.selected.bg=${roles.selected}

    [viewer]
    url.fg=${roles.accent}
    url.underline=true
    header.bold=true
    signature.dim=true
    diff_meta.bold=true
    diff_chunk.fg=${roles.secondary}
    diff_chunk_func.fg=${roles.secondary}
    diff_chunk_func.bold=true
    diff_add.fg=${palette.green}
    diff_del.fg=${palette.red}
    quote_*.fg=${roles.muted}
    quote_1.fg=${roles.secondary}
  '';
in
{
  home-manager.users.${user} =
    { config, ... }:
    {
      programs.aerc = {
        enable = true;
        extraConfig = {
          general.unsafe-accounts-conf = true;
          ui = {
            styleset-name = "ravnix";
            # The single light line, as the port had set it.
            border-char-vertical = "│";
            border-char-horizontal = "─";
          };
        };
        stylesets.ravnix = styleset;
      };

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
