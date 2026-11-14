# A security key's tap instead of the password (modules/desktop/u2f.nix): with
# ravnix.security.u2f.enable, every PAM service the user authenticates with on
# the laptop asks pam_u2f first, as `sufficient`, so a tap is enough and an
# absent or untouched key falls through to the password.
#
# What this reads is the evaluated PAM file of each service, the text of
# /etc/pam.d/NAME, on the laptop shape as the private flake builds it:
#
#   - swaylock, sudo, su, polkit-1 and login carry exactly one pam_u2f line in
#     auth, `sufficient`, before every pam_unix line (the early one that hands
#     the password to the keyring included), with `cue` and the origin and
#     appid of the option (pam://ravnix by default, another when the user sets
#     one), and none of the arguments that would change what a tap means: no
#     PIN (pinverification), no userpresence (the key's default, a touch), no
#     nouserok or alwaysok (which would make a missing key a success), no
#     authfile (pam_u2f's own per-user ~/.config/Yubico/u2f_keys);
#   - greetd has no rules of its own and goes to `login` first in auth, so
#     tuigreet gets login's u2f line before anything else; login's session
#     still starts the keyring (pam_gnome_keyring), which opens a passwordless
#     login keyring after a tap;
#   - pamu2fcfg, for the enrollment, is on the system's PATH, and polkit's
#     helper may read the home and the key's hidraw device;
#   - sshd's stack has no pam_u2f: a login from elsewhere must not wait for,
#     or take, a touch on the key at the laptop (sshd asks PAM for no password
#     today, but a later KbdInteractiveAuthentication would);
#   - nor does cups's: its web interface asks PAM from an HTTP request, where
#     no one at the laptop sees what a blink is for;
#   - sudo alone asks ravnix-tap-ask first: the line right before its pam_u2f
#     is pam_exec of the tool, `[success=ignore default=1]`, quiet and as root
#     (seteuid), so only the tool's exit 0 (Allow in the popup on the laptop's
#     screen) reaches pam_u2f, and any other result skips that one line; no
#     other service has the line;
#   - polkit refuses, before any authentication, a subject outside a local
#     active session (an ssh login, the laptop-access link), root excepted:
#     the rule is in /etc/polkit-1/rules.d/10-nixos.rules with the option on
#     and not with it off;
#   - the option changes nothing but these lines: every PAM file with the
#     option on, without its pam_u2f and ravnix-tap-ask lines, is the file
#     with the option off, line for line, and no service is added or lost;
#   - with the option off, no PAM file names pam_u2f and pamu2fcfg is not
#     installed; the server shape stays the same with the option on;
#   - an origin that would break the PAM line (white space, a bracket, a `#`,
#     which starts a comment, or empty) is refused by the option's type.
#
# tools/ravnix-tap-ask's own tests check what the tool decides: Deny, no
# answer, a locked screen and no session skip pam_u2f, and the origin it names.
#
# A VM cannot touch a key, so the tap itself is tested by hand on the laptop.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  me = ../../templates/default/me.nix;
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  eval = import ../options/helpers/eval.nix { inherit lib self; };

  build =
    modules:
    (inputs.nixpkgs.lib.nixosSystem {
      modules = [
        me
        {
          nixpkgs.hostPlatform = system;
          system.stateVersion = "26.05";
          warnings = lib.mkForce [ ];
        }
      ]
      ++ modules;
    }).config;
  laptop =
    modules:
    build (
      [
        self.nixosModules.laptop
        self.nixosModules.hardware-ideapad-pro-5-16ahp9
      ]
      ++ modules
    );
  on = {
    ravnix.security.u2f.enable = lib.mkForce true;
  };

  laptopOn = laptop [ on ];
  laptopOff = laptop [ ];
  serverOn = build [
    self.nixosModules.server
    on
  ];
  # Another origin, on the desktop alone (cheaper than a third laptop).
  otherOrigin =
    (inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [
        self.nixosModules.desktop
        on
        { ravnix.security.u2f.origin = lib.mkForce "pam://example"; }
      ];
    }).config;

  # Each line without the comment NixOS appends (`# NAME (order N)`).
  linesOf =
    c: service:
    map (l: lib.head (lib.splitString " #" l)) (
      lib.splitString "\n" (c.security.pam.services.${service}.text or "")
    );
  authOf = c: service: lib.filter (lib.hasPrefix "auth ") (linesOf c service);
  isU2f = lib.hasInfix "/pam_u2f.so";
  isGate = l: lib.hasInfix "/bin/ravnix-tap-ask" l;
  gateLine = "auth \\[success=ignore default=1] [^ ]+/lib/security/pam_exec\\.so quiet quiet_log seteuid [^ ]+/bin/ravnix-tap-ask *";
  isUnix = l: builtins.match ".*/pam_unix\\.so( .*)?" l != null;
  indexOf =
    pred: list:
    let
      hits = lib.filter (i: pred (lib.elemAt list i)) (lib.range 0 (lib.length list - 1));
    in
    if hits == [ ] then null else lib.head hits;
  # The words after the module path: the arguments of the line.
  argsOf =
    line:
    let
      words = lib.filter (w: w != "") (lib.splitString " " line);
      at = indexOf isU2f words;
    in
    lib.drop (at + 1) words;

  check = cond: msg: lib.optional (!cond) msg;

  services = [
    "swaylock"
    "sudo"
    "su"
    "polkit-1"
    "login"
  ];
  forbidden = [
    "pinverification"
    "userpresence"
    "userverification"
    "nouserok"
    "alwaysok"
    "authfile"
    "nodetect"
    "debug"
    "manual"
  ];

  carries =
    name: c: origin: service:
    let
      auth = authOf c service;
      u2f = lib.filter isU2f auth;
      line = lib.head u2f;
      args = argsOf line;
      u2fAt = indexOf isU2f auth;
      unixAt = indexOf isUnix auth;
    in
    if !(c.security.pam.services ? ${service}) then
      [ "${name}: there is no PAM service ${service}" ]
    else if u2f == [ ] then
      [ "${name}: ${service} has no pam_u2f line in auth" ]
    else
      check (lib.length u2f == 1) "${name}: ${service} has ${toString (lib.length u2f)} pam_u2f lines"
      ++ check (lib.hasInfix " sufficient " line) "${name}: ${service}'s pam_u2f is not sufficient: ${line}"
      ++ check (unixAt != null) "${name}: ${service} has no pam_unix in auth, so no password"
      ++ check (
        unixAt == null || u2fAt < unixAt
      ) "${name}: ${service}'s pam_u2f does not come before pam_unix"
      ++ check (lib.elem "cue" args) "${name}: ${service}'s pam_u2f has no cue: ${line}"
      ++ check (lib.elem "origin=${origin}" args) "${name}: ${service}'s pam_u2f has no origin=${origin}: ${line}"
      ++ check (lib.elem "appid=${origin}" args) "${name}: ${service}'s pam_u2f has no appid=${origin}: ${line}"
      ++ lib.concatMap (
        f:
        check (
          !lib.any (a: a == f || lib.hasPrefix "${f}=" a) args
        ) "${name}: ${service}'s pam_u2f has ${f}: ${line}"
      ) forbidden;

  greetdFirst =
    name: c:
    let
      auth = authOf c "greetd";
    in
    check (
      auth != [ ] && builtins.match "auth +(substack|include) +login *" (lib.head auth) != null
    ) "${name}: greetd's auth does not start with the login stack: ${lib.concatStringsSep " | " auth}"
    ++ check (!lib.any isU2f (linesOf c "greetd")) "${name}: greetd has a pam_u2f line of its own";

  keyring =
    name: c:
    check (lib.any (l: lib.hasPrefix "session " l && lib.hasInfix "pam_gnome_keyring.so" l) (
      linesOf c "login"
    )) "${name}: login's session does not start the keyring";

  # sudo's gate: one line, right before pam_u2f, exactly as above.
  gate =
    name: c:
    let
      auth = authOf c "sudo";
      gates = lib.filter isGate auth;
      u2fAt = indexOf isU2f auth;
    in
    if gates == [ ] then
      [ "${name}: sudo has no ravnix-tap-ask line" ]
    else
      check (lib.length gates == 1) "${name}: sudo has ${toString (lib.length gates)} ravnix-tap-ask lines"
      ++ check (builtins.match gateLine (lib.head gates) != null) "${name}: sudo's ravnix-tap-ask line is not ${gateLine}: ${lib.head gates}"
      ++ check (
        u2fAt != null && u2fAt > 0 && isGate (lib.elemAt auth (u2fAt - 1))
      ) "${name}: sudo's ravnix-tap-ask line is not right before pam_u2f: ${lib.concatStringsSep " | " auth}"
      ++ lib.concatMap (
        s: check (!lib.any isGate (linesOf c s)) "${name}: ${s} has a ravnix-tap-ask line"
      ) (lib.filter (s: s != "sudo") (lib.attrNames c.security.pam.services));

  # polkit's rule against subjects outside a local, active session.
  polkitRules = c: c.environment.etc."polkit-1/rules.d/10-nixos.rules".text or "";
  remoteRule = [
    "polkit.addRule(function (action, subject) {"
    ''if (subject.user != "root" && (!subject.local || !subject.active)) {''
    "return polkit.Result.NO;"
  ];
  polkitRule =
    name: c:
    check c.security.polkit.enable "${name}: polkit is off"
    ++ lib.concatMap (
      l: check (lib.hasInfix l (polkitRules c)) "${name}: polkit's rules lack ${l}"
    ) remoteRule;
  noPolkitRule =
    name: c:
    check (!lib.hasInfix "subject.local" (polkitRules c)) "${name}: polkit's rules refuse remote subjects";

  # The option on, without its own lines, is the option off.
  onlyTheseLines =
    lib.concatMap (
      s:
      check (
        lib.filter (l: !isU2f l && !isGate l) (linesOf laptopOn s) == linesOf laptopOff s
      ) "laptop: the option changes ${s} beyond its pam_u2f and ravnix-tap-ask lines"
    ) (lib.attrNames laptopOff.security.pam.services)
    ++ check (
      lib.attrNames laptopOn.security.pam.services == lib.attrNames laptopOff.security.pam.services
    ) "laptop: the option adds or removes a PAM service";

  pamU2fIn = c: lib.filter (p: lib.getName p == "pam_u2f") c.environment.systemPackages;

  anyU2f =
    name: c:
    lib.concatMap (
      s:
      check (
        !lib.hasInfix "pam_u2f" (c.security.pam.services.${s}.text or "")
      ) "${name}: ${s} names pam_u2f"
    ) (lib.attrNames c.security.pam.services)
    ++ check (!c.security.pam.u2f.enable) "${name}: security.pam.u2f is on"
    ++ check (pamU2fIn c == [ ]) "${name}: pam_u2f is installed";

  evalOrigin =
    origin:
    eval [
      me
      {
        ravnix.security.u2f = lib.mapAttrs (_: lib.mkForce) {
          enable = true;
          inherit origin;
        };
      }
    ];
  refused =
    origin:
    check (!(evalOrigin origin).values.success) "the origin ${builtins.toJSON origin} is accepted";
  accepted =
    origin: check (evalOrigin origin).values.success "the origin ${builtins.toJSON origin} is refused";

  failures =
    lib.concatMap (carries "laptop" laptopOn "pam://ravnix") services
    ++ greetdFirst "laptop" laptopOn
    ++ keyring "laptop" laptopOn
    ++ check (pamU2fIn laptopOn != [ ]) "laptop: pamu2fcfg (pam_u2f) is not on the PATH"
    ++ check (
      (laptopOn.systemd.services."polkit-agent-helper@".serviceConfig.ProtectHome or null) == "read-only"
    ) "laptop: polkit's helper cannot read the home"
    ++ check laptopOn.services.openssh.enable "laptop: no sshd, so the sshd case reads nothing"
    ++ check (!lib.any isU2f (linesOf laptopOn "sshd")) "laptop: sshd's stack has pam_u2f"
    ++ check (laptopOn.security.pam.services ? cups) "laptop: no cups, so the cups case reads nothing"
    ++ check (!lib.any isU2f (linesOf laptopOn "cups")) "laptop: cups's stack has pam_u2f"
    ++ gate "laptop" laptopOn
    ++ polkitRule "laptop" laptopOn
    ++ noPolkitRule "laptop with the option off" laptopOff
    ++ gate "another origin" otherOrigin
    ++ onlyTheseLines
    ++ lib.concatMap (carries "another origin" otherOrigin "pam://example") services
    ++ anyU2f "laptop with the option off" laptopOff
    ++ greetdFirst "laptop with the option off" laptopOff
    ++ keyring "laptop with the option off" laptopOff
    ++ anyU2f "server with the option on" serverOn
    ++ lib.concatMap refused [
      ""
      "pam://a b"
      "pam://a]b"
      "pam://a\nb"
      "pam://a#b"
    ]
    ++ lib.concatMap accepted [
      "pam://ravnix"
      "pam://example"
      "https://example.org"
    ];
in
pkgs.runCommand "desktop-u2f" { } ''
  ${
    if failures == [ ] then
      "echo 'a tap or the password at greetd, swaylock, sudo (after Allow), su, polkit and login' > $out"
    else
      ''
        cat >&2 <<'EOT'
        ${lib.concatStringsSep "\n" failures}
        EOT
        exit 1
      ''
  }
''
