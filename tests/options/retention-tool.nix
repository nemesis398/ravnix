# The retention file is read twice: by modules/options/backup.nix when a host
# is built, and by ravnix-retention when a prune job runs on the NAS. The two
# must agree, or a file the build accepts fails the prune, or one it refuses
# would have pruned. For every fixture of ./fixtures/retention and the
# template's backups.toml: the tool accepts what the module accepts, and a
# file the module refuses the tool refuses too, with one of the module's own
# messages (the tool names the first problem, and its line). The flags of an
# accepted file are the ones its numbers say.
{
  self,
  pkgs,
  lib,
  system,
  ...
}:
let
  eval = import ./helpers/eval.nix { inherit lib self; };
  template = ../../templates/default/me.nix;
  tool = lib.getExe self.packages.${system}.ravnix-retention;
  fixtures = ./fixtures/retention;

  files =
    lib.mapAttrs' (name: _: lib.nameValuePair (lib.removeSuffix ".toml" name) (fixtures + "/${name}")) (
      lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".toml" name) (
        builtins.readDir fixtures
      )
    )
    // {
      template = ../../templates/default/backups.toml;
    };

  prefix = "ravnix.backup.retentionFile: ";
  verdict =
    file:
    map (m: lib.removeSuffix "." (lib.removePrefix prefix m)) (
      lib.filter (lib.hasPrefix prefix)
        (eval [
          template
          { ravnix.backup.retentionFile = lib.mkForce file; }
        ]).failed
    );

  # What the tool must print for the accepted files, nas and internxt, for
  # muninn, the host the fixtures override.
  flags = {
    template = {
      nas = "--host muninn --group-by host --keep-daily 7 --keep-weekly 4 --keep-monthly 6";
      internxt = "--host muninn --group-by host --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 2";
    };
    host-override = {
      nas = "--host muninn --group-by host --keep-daily 14 --keep-weekly 4 --keep-monthly 6";
      internxt = "--host muninn --group-by host --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 2";
    };
  };
  unexpected = lib.filter (name: verdict files.${name} == [ ] && !(flags ? ${name})) (
    lib.attrNames files
  );

  caseFor =
    name: file:
    let
      messages = verdict file;
    in
    if messages == [ ] then
      lib.concatStrings (
        lib.mapAttrsToList (target: want: ''
          got=$(${tool} flags --target ${target} --host muninn --file ${file}) || fail "${name}: the module accepts it, the tool refuses it"
          [ "$got" = ${lib.escapeShellArg want} ] || fail "${name}, ${target}: the tool prints '$got', not '${want}'"
        '') flags.${name}
      )
    else
      ''
        if printed=$(${tool} flags --target nas --host muninn --file ${file} 2>err); then
          fail "${name}: the module refuses it (${lib.concatStringsSep "; " messages}), the tool prints '$printed'"
        fi
        said=$(sed -e 's|^ravnix-retention: ${file}: ||' -e 's|^line [0-9]*: ||' err)
        case "$said" in
          ${lib.concatMapStringsSep "|" lib.escapeShellArg messages}) ;;
          *) fail "${name}: the tool says '$said', which is none of the module's: ${lib.escapeShellArg (lib.concatStringsSep " / " messages)}" ;;
        esac
      '';
in
pkgs.runCommand "options-retention-tool" { } ''
  failed=0
  fail() { echo "FAIL: $*" >&2; failed=1; }
  ${lib.optionalString (
    unexpected != [ ]
  ) ''fail "accepted fixtures without expected flags here: ${toString unexpected}"''}
  ${lib.concatStrings (lib.mapAttrsToList caseFor files)}
  [ "$failed" = 0 ] || exit 1
  touch $out
''
