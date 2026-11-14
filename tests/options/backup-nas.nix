# The values of ravnix.backup.nas that its types and assertions refuse, and
# the unusual ones that are right. The repository is derived, from the
# rest-server in ravnix.services and the host name, so it cannot be typed,
# and a host without that service is refused; a host name that is the name
# of another kind of machine in ravnix.hosts (the NAS, whose own backups
# may carry it in the shared Internxt repository) is refused; a `!` in exclude is keep's job (modules/common/backup-excludes.nix); a
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
  # The template's NAS runs the rest-server.
  registered = {
    ravnix.services.restic-server = {
      enable = true;
      host = "nas";
      port = 8000;
    };
  };
  base = {
    host = "huginn";
    passwordItem = "Restic - huginn repository";
    loginItem = "Restic - huginn login";
  };
  acceptedWith =
    modules: attrs:
    let
      e = eval (
        [
          template
          { ravnix.backup.nas = lib.mkForce (base // attrs); }
        ]
        ++ modules
      );
    in
    e.values.success && e.failed == [ ];
  accepted = acceptedWith [ registered ];

  derived =
    (eval [
      template
      registered
      { ravnix.backup.nas = lib.mkForce base; }
    ]).config.ravnix.backup.nas.repository;

  # A host's module sets the value beside the template's null, as the
  # template says to, without lib.mkForce.
  besideNull = eval [
    template
    registered
    { ravnix.backup.nas = base; }
  ];
  # A plain null beside a plain value, as a host module that turns the
  # backup off beside a value left in me.nix: a conflict, not a silent
  # backup under the other value's name.
  nullBesideValue = eval [
    template
    registered
    { ravnix.backup.nas = base; }
    { ravnix.backup.nas = null; }
  ];
  # Two hosts' values in one configuration are still two definitions.
  twoValues = eval [
    template
    registered
    { ravnix.backup.nas = base; }
    { ravnix.backup.nas.host = "muninn"; }
  ];

  refused = {
    "a repository typed by hand" = {
      repository = "rest:http://192.0.2.30:8000/huginn/";
    };
    "a host named like the NAS" = {
      host = "nas";
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
    "the other ravnix host" = {
      host = "muninn";
    };
    "a host that is in no registry" = {
      host = "box-2";
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
    lib.optional (acceptedWith [ ] { }) "accepted a backup without a rest-server in ravnix.services"
    ++ lib.optional (
      derived != "rest:http://192.0.2.30:8000/huginn/"
    ) "the repository is ${derived}, not the registered rest-server's url at /huginn/"
    ++ lib.optional (
      !(besideNull.values.success && besideNull.failed == [ ])
    ) "a host module's value beside the template's null is refused"
    ++ lib.optional twoValues.values.success "two host names in one configuration are accepted"
    ++ lib.optional (
      nullBesideValue.values.success
    ) "a plain null beside a plain value is accepted, so the value wins in silence"
    # The repository is derived from the NAS's address, a placeholder in
    # the template that is reported once, as ravnix.hosts.nas.address.
    ++ lib.optional (lib.any (lib.hasPrefix "ravnix.backup.nas.repository ") besideNull.config.warnings) "the derived repository is reported as a placeholder too"
    ++ lib.mapAttrsToList (what: _: "accepted ${what}") (lib.filterAttrs (_: accepted) refused)
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
