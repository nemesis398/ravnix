# The Beszel agent on huginn as the private flake builds it, the laptop shape
# and the IdeaPad module with the template's values: the IdeaPad names its
# GPU collector, amd_sysfs, so the agent never runs nvidia-smi, whose poll
# every 4 s keeps the RTX 4050 awake (measured on Fedora, 2026-10-26); the
# hardware's value reaches home-manager's unit, a host can still choose
# another, and the collector alone starts no agent.
{
  self,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  me = ../../templates/default/me.nix;
  user = (import me).ravnix.user.username;
  build =
    modules:
    (inputs.nixpkgs.lib.nixosSystem {
      modules = [
        me
        {
          system.stateVersion = "26.05";
          warnings = lib.mkForce [ ];
        }
        self.nixosModules.laptop
        self.nixosModules.hardware-ideapad-pro-5-16ahp9
      ]
      ++ modules;
    }).config;
  beszel = {
    hubUrl = "https://hub.example";
    hubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMadeUpForTheTestMadeUpForTheTestMadeUpXy";
    tokenItem = "Beszel - token (test)";
    systemName = "huginn";
  };
  agentOf = c: c.home-manager.users.${user}.systemd.user.services.beszel-agent or null;
  envOf = c: (agentOf c).Service.Environment or [ ];
  gpuOf = c: lib.filter (lib.hasPrefix "GPU_COLLECTOR=") (envOf c);

  huginn = build [ { ravnix.monitoring.beszel = beszel; } ];
  chosen = build [
    {
      ravnix.monitoring.beszel = beszel;
      ravnix.monitoring.gpuCollector = "nvml";
    }
  ];
  without = build [ ];

  failures =
    lib.optional (
      agentOf huginn == null
    ) "huginn with ravnix.monitoring.beszel has no beszel-agent unit"
    ++ lib.optional (
      gpuOf huginn != [ "GPU_COLLECTOR=amd_sysfs" ]
    ) "huginn's agent does not read the iGPU alone: ${builtins.toJSON (gpuOf huginn)}"
    ++ lib.optional (
      gpuOf chosen != [ "GPU_COLLECTOR=nvml" ]
    ) "a host's own collector does not win over the hardware's: ${builtins.toJSON (gpuOf chosen)}"
    ++ lib.optional (
      without.ravnix.monitoring.gpuCollector != "amd_sysfs"
    ) "the IdeaPad module does not name its collector"
    ++ lib.optional (agentOf without != null) "the hardware's collector alone brings an agent";
in
pkgs.runCommand "laptop-monitoring" { } (
  if failures != [ ] then
    ''
      printf 'FAIL: %s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
  else
    "touch $out"
)
