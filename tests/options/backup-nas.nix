# The values of ravnix.backup.nas that its types refuse, and the unusual
# ones that are right. A login in the repository URL would be in the store;
# a `!` in exclude is keep's job (modules/common/backup-excludes.nix); a
# host name with a dash in front would be an option on restic's command
# line; a path with a trailing slash, `//`, `.` or `..` is not one path.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  eval = import ./helpers/eval.nix { inherit lib self; };
  template = ../../templates/default/me.nix;
  base = {
    repository = "rest:http://192.0.2.30:8000/huginn/";
    host = "huginn";
    passwordItem = "Restic - huginn repository";
    loginItem = "Restic - huginn login";
  };
  accepted =
    attrs:
    let
      e = eval [
        template
        { ravnix.backup.nas = lib.mkForce (base // attrs); }
      ];
    in
    e.values.success && e.failed == [ ];

  refused = {
    "a login in the repository URL" = {
      repository = "rest:http://huginn:secret@192.0.2.30:8000/huginn/";
    };
    "a repository that is not rest" = {
      repository = "sftp:nas:/restic/huginn";
    };
    "a repository without a scheme" = {
      repository = "rest:192.0.2.30:8000/huginn/";
    };
    "a repository with a space" = {
      repository = "rest:http://192.0.2.30:8000/hu ginn/";
    };
    "a host with a leading dash" = {
      host = "-huginn";
    };
    "a host with a dot" = {
      host = "huginn.lan";
    };
    "an empty host" = {
      host = "";
    };
    "a host of 64 characters" = {
      host = lib.concatStrings (lib.replicate 64 "a");
    };
    "an item with a second line" = {
      passwordItem = "Restic\nother";
    };
    "an empty login item" = {
      loginItem = "";
    };
    "no paths" = {
      paths = [ ];
    };
    "a relative path" = {
      paths = [ "Documents" ];
    };
    "a path with a trailing slash" = {
      paths = [ "~/Documents/" ];
    };
    "a path with .." = {
      paths = [ "~/../other" ];
    };
    "a path with //" = {
      paths = [ "~//Documents" ];
    };
    "the root" = {
      paths = [ "/" ];
    };
    "an exclude that takes something back" = {
      exclude = [ "!~/Nextcloud/notes" ];
    };
    "an exclude with a newline" = {
      exclude = [ "~/a\nb" ];
    };
    "a kept path with a trailing slash" = {
      exclude = [ "~/Nextcloud" ];
      keep = [ "~/Nextcloud/notes/" ];
    };
    "an empty calendar" = {
      onCalendar = "";
    };
  };

  allowed = {
    "the defaults" = { };
    "https and no port" = {
      repository = "rest:https://nas.example.org/huginn";
    };
    "an IPv6 address" = {
      repository = "rest:http://[2001:db8::30]:8000/huginn/";
    };
    "a host with a dash and an underscore" = {
      host = "Box_2-a";
    };
    "absolute paths, umlauts and spaces" = {
      paths = [
        "/srv/data"
        "~/Für Später"
      ];
    };
    "wildcards and a pattern for any depth" = {
      exclude = [
        "*.iso"
        "node_modules"
        "~/Videos/[a-z]*"
      ];
    };
    "a kept path" = {
      exclude = [ "~/Nextcloud" ];
      keep = [ "~/Nextcloud/notes" ];
    };
    "a calendar expression" = {
      onCalendar = "*-*-* 02:00";
    };
  };

  failures =
    lib.mapAttrsToList (what: _: "accepted ${what}") (lib.filterAttrs (_: accepted) refused)
    ++ lib.mapAttrsToList (what: _: "refused ${what}") (lib.filterAttrs (_: a: !(accepted a)) allowed);
in
pkgs.runCommand "options-backup-nas" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
