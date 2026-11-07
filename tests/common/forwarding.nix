# nixosModules.common on a NixOS configuration: the user's account, and the
# values of ravnix.* that reach the user's home-manager configuration from the
# one me.nix the host gets. No VM: the configuration is evaluated and read.
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
  user = (import me).ravnix.user;

  host =
    modules:
    (inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.common
        me
        {
          system.stateVersion = "26.05";
          # The template's values are placeholders and warn about it (the
          # options tests check that they do); here each warning would be
          # printed again by every evaluation.
          warnings = lib.mkForce [ ];
          # A host sets these; they are not what the test is about.
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
        }
      ]
      ++ modules;
    }).config;

  plain = host [ ];
  forwarded = host [
    {
      # The template says mauve; a host module that disagrees must force it.
      ravnix.theme.accent = lib.mkForce "teal";
      ravnix.shell = {
        autoAttach = "echo FROM-THE-HOST";
        secretEnv.A_TOKEN = "An item";
      };
      ravnix.services.atuin = {
        enable = true;
        host = "nas";
        port = 8888;
      };
    }
  ];
  overridden = host [
    { ravnix.shell.autoAttach = "echo FROM-THE-HOST"; }
    { home-manager.users.${user.username}.ravnix.shell.autoAttach = "echo FROM-THE-USER"; }
  ];

  # A ravnix.* option that only NixOS declares, set by a module of the host.
  # home-manager has no such option, and the host must still evaluate.
  probe =
    { lib, ... }:
    {
      options.ravnix.probe = lib.mkOption {
        type = lib.types.str;
        default = "unset";
      };
      config.ravnix.probe = "set by a host module";
    };
  nixosOnly = host [ probe ];

  # The module imported a second time, by a host shape and by the private
  # flake, say. It must change nothing.
  once = host [ { ravnix.shell.autoAttach = "echo ONCE"; } ];
  twice = host [
    { ravnix.shell.autoAttach = "echo ONCE"; }
    self.nixosModules.common
    self.nixosModules.options
    self.nixosModules.theme
  ];
  # And the home-manager module listed by the user's own configuration too.
  userImports = host [
    { home-manager.users.${user.username}.imports = [ self.homeModules.common ]; }
    { ravnix.shell.autoAttach = "echo ONCE"; }
  ];

  # ravnix.editor.languages is a types.uniq option: a second definition at the
  # same priority is an error, not a union. me.nix defines it once, a host may
  # force another list, and in home-manager the forwarded value is a mkDefault.
  allLanguages = (import me).ravnix.editor.languages;
  narrowed = host [
    {
      ravnix.editor.languages = lib.mkForce [
        "lua"
        "nix"
      ];
    }
  ];
  userSets = host [
    { home-manager.users.${user.username}.ravnix.editor.languages = [ "bash" ]; }
  ];
  userForces = host [
    {
      home-manager.users.${user.username}.ravnix.editor.languages = lib.mkForce [ "python" ];
    }
  ];
  userDefaults = host [
    {
      home-manager.users.${user.username}.ravnix.editor.languages = lib.mkDefault [ "bash" ];
    }
  ];

  homeOf = c: c.home-manager.users.${user.username};
  hm = homeOf forwarded;

  # The forwarded definitions, as the modules home-manager gets.
  sharedAttrs = lib.filter builtins.isAttrs forwarded.home-manager.sharedModules;
  forwardedFiles = map (m: m._file) (lib.filter (m: m ? _file) sharedAttrs);
  count = x: xs: lib.length (lib.filter (y: y == x) xs);

  failures = lib.flatten [
    # The account.
    (lib.optional (!plain.users.users.${user.username}.isNormalUser) "the account is not a normal user")
    (lib.optional (
      plain.users.users.${user.username}.description != user.name
    ) "the account's full name is not ravnix.user.name")
    (lib.optional (
      plain.users.users.${user.username}.shell != pkgs.bashInteractive
    ) "the account's shell is not bash")
    (lib.optional (
      !lib.elem "wheel" plain.users.users.${user.username}.extraGroups
    ) "the account is not in wheel")
    # What me.nix sets reaches home-manager.
    (lib.optional (
      (homeOf plain).ravnix.user.email != user.email
    ) "ravnix.user.email did not reach home-manager")
    (lib.optional (
      (homeOf plain).ravnix.user.signingKey != user.signingKey
    ) "ravnix.user.signingKey did not reach home-manager")
    (lib.optional (
      (homeOf plain).ravnix.secrets.rbwEmail != plain.ravnix.secrets.rbwEmail
    ) "ravnix.secrets did not reach home-manager")
    (lib.optional ((homeOf plain).home.stateVersion != "26.05") "home.stateVersion is not the system's")
    (lib.optional ((homeOf plain).home.username != user.username) "home.username is not the account's")
    # What a host module sets reaches it too, whichever option it is.
    (lib.optional (hm.ravnix.theme.accent != "teal") "the accent did not reach home-manager")
    (lib.optional (
      hm.ravnix.shell.autoAttach != "echo FROM-THE-HOST"
    ) "ravnix.shell.autoAttach did not reach home-manager")
    (lib.optional (
      hm.ravnix.shell.secretEnv != { A_TOKEN = "An item"; }
    ) "ravnix.shell.secretEnv did not reach home-manager")
    (lib.optional (
      hm.ravnix.services.atuin.url != forwarded.ravnix.services.atuin.url
    ) "a service's url differs between NixOS and home-manager")
    (lib.optional (
      hm.programs.atuin.settings.sync_address != "http://192.0.2.30:8888"
    ) "atuin does not sync with the service the host placed")
    # The roles are computed on both sides, from the accent.
    (lib.optional (
      hm.ravnix.theme.roles.accent != hm.ravnix.theme.palette.teal
    ) "the roles in home-manager do not follow the accent")
    # A value the user sets in their own home-manager configuration wins.
    (lib.optional (
      (homeOf overridden).ravnix.shell.autoAttach != "echo FROM-THE-USER"
    ) "the user's own home-manager value does not win over the host's")
    # The default is not forwarded as a definition: what nobody set stays default.
    (lib.optional (
      (homeOf plain).ravnix.theme.accent != "mauve"
    ) "the default accent changed on the way")
    (lib.optional ((homeOf plain).ravnix.shell.secretEnv != { }) "a secret appeared from nowhere")
    # An option that only NixOS declares is no concern of home-manager: the
    # host evaluates, and the option is not forwarded.
    (lib.optional (
      !(builtins.tryEval (builtins.deepSeq (homeOf nixosOnly).home.username true)).success
    ) "a NixOS-only ravnix.* option breaks the home-manager evaluation")
    (lib.optional (nixosOnly.ravnix.probe != "set by a host module") "the NixOS-only option is not set")
    (lib.optional (
      (homeOf nixosOnly).ravnix.user.email != user.email
    ) "a NixOS-only option stops the other values from reaching home-manager")
    # A forwarded value keeps the file it was written in, so an error names me.nix.
    (lib.optional (
      !lib.elem (toString me) forwardedFiles
    ) "no forwarded value names me.nix as its file: ${toString forwardedFiles}")
    (lib.optional (lib.any (
      m: !(m ? _file) && !(m ? key)
    ) sharedAttrs) "a forwarded module has neither a file nor a key")
    # ravnix.editor.languages, a types.uniq option, arrives once and without
    # a collision, whoever else defines it.
    (lib.optional (
      (homeOf plain).ravnix.editor.languages != allLanguages
    ) "ravnix.editor.languages of me.nix did not reach home-manager as it is")
    (lib.optional (
      (homeOf narrowed).ravnix.editor.languages != [
        "lua"
        "nix"
      ]
    ) "a host's lib.mkForce of ravnix.editor.languages did not reach home-manager")
    (lib.optional ((homeOf userSets).ravnix.editor.languages != [ "bash" ])
      "the user's own home-manager value of ravnix.editor.languages does not win over the forwarded one"
    )
    (lib.optional (
      (homeOf userForces).ravnix.editor.languages != [ "python" ]
    ) "the user's lib.mkForce in home-manager does not win over the forwarded one")
    # The one thing that does collide, loudly: the user's own lib.mkDefault in
    # home-manager has the priority of the forwarded value, and uniq refuses
    # two definitions. nixos.nix says so and says what to do instead.
    (lib.optional ((builtins.tryEval (builtins.deepSeq (homeOf userDefaults).ravnix.editor.languages true)).success) "a lib.mkDefault of a uniq option in home-manager no longer collides with the forwarded value; update the note in nixos.nix")
    # Imported twice, the module adds nothing the second time.
    (lib.optional (
      (homeOf twice).ravnix.shell.autoAttach != "echo ONCE"
    ) "a second import doubles a forwarded value: ${(homeOf twice).ravnix.shell.autoAttach}")
    (lib.optional (
      (homeOf userImports).ravnix.shell.autoAttach != "echo ONCE"
    ) "homeModules.common listed by the user doubles a forwarded value")
    (lib.optional (
      lib.length twice.home-manager.sharedModules != lib.length once.home-manager.sharedModules
    ) "a second import lengthens home-manager.sharedModules")
    (lib.optional (
      count "wheel" twice.users.users.${user.username}.extraGroups != 1
    ) "a second import lists wheel twice")
    (lib.optional (
      count "$HOME/.local/bin" (homeOf twice).home.sessionPath != 1
    ) "a second import lists ~/.local/bin twice")
    (lib.optional (
      count "$HOME/.local/bin" (homeOf userImports).home.sessionPath != 1
    ) "homeModules.common imported twice lists ~/.local/bin twice")
  ];
in
pkgs.runCommand "common-forwarding" { } ''
  ${lib.concatMapStrings (m: "echo ${lib.escapeShellArg m} >&2\n") failures}
  ${lib.optionalString (failures != [ ]) "exit 1"}
  touch $out
''
