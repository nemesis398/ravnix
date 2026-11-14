# A security key's tap instead of the password on the laptop
# (modules/desktop/u2f.nix): whether pam_u2f asks first wherever the user
# authenticates, and the origin the key's credential is bound to. Nothing here
# is a secret; the mapping of the user to the key's credential is a file in the
# user's home that `pamu2fcfg` writes, never a value of this flake.
{ lib, ... }:
let
  inherit (lib) mkOption types;

  # The origin goes into the PAM line as `origin=VALUE appid=VALUE`: white
  # space would split it into two arguments, a bracket would end the bracketed
  # form NixOS writes for an argument with a space, and Linux-PAM reads a line
  # only up to its first `#`, so none of them may be in it.
  origin = types.strMatching "[^][#[:space:]]+" // {
    description = "pam_u2f origin without white space, brackets or #, such as pam://ravnix";
  };
in
{
  options.ravnix.security.u2f = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether a tap on a FIDO security key (a YubiKey) can stand in for the
        password on the laptop: at the login screen (greetd and tuigreet),
        swaylock, sudo, su, polkit and a console login, never over ssh and
        not in CUPS's web interface. pam_u2f asks first, as `sufficient`, and
        shows "Please touch the FIDO authenticator."; a tap logs in, and
        without the key, or when the key is not touched in time, the password
        prompt follows and the password works as before. sudo first shows a
        popup on the laptop's own screen that names the command, the user and
        where the sudo came from, and waits for the key only after Allow
        (tools/ravnix-tap-ask); polkit refuses a request from outside a local
        session. This is consent against a mistaken touch, not a defense
        against the server's laptop-access link, which runs any command as
        the user (modules/desktop/u2f.nix).
        No PIN is asked: a password typed into a PIN prompt by habit would
        count as a wrong FIDO2 PIN, and eight of those block FIDO2 on the key
        for good.

        The key needs a mapping in ~/.config/Yubico/u2f_keys. One made with
        the same origin works on every machine, so a mapping made elsewhere
        with `-o pam://ravnix -i pam://ravnix` is copied in as it is; only one
        made with pamu2fcfg's default origin (`pam://` and the host name)
        must be made again. To make one, as the user, with the key plugged in,
        touching it when it blinks (a key with a FIDO2 PIN asks for it here,
        once); the option installs pamu2fcfg on the laptop:

            mkdir -p ~/.config/Yubico
            pamu2fcfg -o pam://ravnix -i pam://ravnix > ~/.config/Yubico/u2f_keys
            chmod 600 ~/.config/Yubico/u2f_keys

        The chmod matters: pam_u2f refuses a mapping that someone else owns,
        but only warns about one that others may write, and whoever can write
        it can add a key of their own. With another `origin`, put that value
        after `-o` and `-i`. Until the file exists, pam_u2f fails without a
        prompt and the password is asked for as before. Off on the server,
        which never has the key.
      '';
    };

    origin = mkOption {
      type = origin;
      default = "pam://ravnix";
      example = "pam://ravnix";
      description = ''
        The origin and appid of the key's credential, pam_u2f's `origin=`
        and `appid=` and pamu2fcfg's `-o` and `-i`. A fixed value on purpose:
        pamu2fcfg binds a credential to its origin, and both default to
        `pam://` and the host name, so a mapping made on one machine would
        stop working on a new or renamed one. With a value of its own, the
        same ~/.config/Yubico/u2f_keys keeps working wherever this option has
        the same value. Change it only together with a new enrollment.
      '';
    };
  };
}
