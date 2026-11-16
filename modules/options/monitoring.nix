# The host's place in the estate's monitoring (modules/common/monitoring.nix):
# its metrics to a Beszel hub, its heartbeat to an Uptime Kuma push monitor,
# and the age of its last backup on the NAS to another one. Each is null,
# and adds nothing, until the host sets it. They are per host (each host has
# its own system name and its own push monitors), so set them in the host's
# module, never in me.nix, which every host reads.
#
# The secrets are names of Bitwarden items, read by rbw at each start or
# run: the hub's registration token and the two push URLs, whose last part
# is the monitor's token. The hub's address and its public key are no
# secrets, and are in the store.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };

  item = types.strMatching "[^\n]+";

  # The collectors the agent knows (agent/gpu.go upstream, as nixpkgs'
  # services.beszel.agent lists them), but the macOS ones.
  gpuCollector = types.enum [
    "amd_sysfs"
    "intel_sysfs"
    "intel_gpu_top"
    "nvidia-smi"
    "nvml"
    "nvtop"
    "rocm-smi"
  ];

  beszel = types.submodule {
    options = {
      hubUrl = mkOption {
        type = ravnix.url;
        example = "https://metrics.example.org";
        description = ''
          The hub's address, which the agent dials out to (HUB_URL): it opens
          one WebSocket there and keeps it, so the hub needs no way in to the
          host.
        '';
      };
      hubKey = mkOption {
        type = ravnix.sshPublicKey;
        example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey";
        description = ''
          The hub's public key (KEY), which the agent checks the hub it
          reached against: the line the hub shows under Add system, or
          `ssh-keygen -y -f` of its id_ed25519. Not a secret; it goes into
          the store as the agent's KEY_FILE.
        '';
      };
      tokenItem = mkOption {
        type = item;
        example = "Beszel - universal token";
        description = ''
          The Bitwarden item whose password is the hub's token (TOKEN), with
          which an agent registers itself the first time it connects. rbw
          reads it at each start of the agent, which gets it through a pipe
          (TOKEN_FILE=/dev/stdin): it is in no file, no unit and no
          environment. A hub whose universal token is closed keeps every
          agent it knows and takes no new one: open it for the first start.
        '';
      };
      systemName = mkOption {
        type = types.strMatching "[A-Za-z0-9._-]+" // {
          description = "system name: letters, digits, `.`, `_` and `-`";
        };
        example = "huginn";
        description = ''
          The name the hub shows the host by (SYSTEM_NAME), once, when the
          agent registers. Afterwards the hub knows the agent by the
          fingerprint in its state directory, ~/.local/state/beszel-agent.
        '';
      };
    };
  };

  kuma = types.submodule {
    options = {
      pushUrlItem = mkOption {
        type = item;
        example = "Uptime Kuma - push URL (huginn)";
        description = ''
          The Bitwarden item whose password is the push monitor's whole URL,
          `https://<kuma>/api/push/<token>`. rbw reads it at each beat, and
          curl gets it on standard input, not on its command line.
        '';
      };
      units = mkOption {
        type = types.listOf (
          types.strMatching "[A-Za-z0-9@:._\\-]+"
          // {
            description = "systemd unit name";
          }
        );
        default = [ ];
        example = [ "ravnix-connection.service" ];
        description = ''
          User units the heartbeat answers for: while one of them is not
          active, the beat says `down` and names it. Empty: the beat says
          only that the host is up.
        '';
      };
    };
  };

  backupAge = types.submodule {
    options = {
      pushUrlItem = mkOption {
        type = item;
        example = "Uptime Kuma - push URL (huginn backup)";
        description = ''
          The Bitwarden item whose password is the backup monitor's push URL,
          read as the heartbeat's is.
        '';
      };
      maxAgeDays = mkOption {
        type = types.ints.positive;
        default = 3;
        description = ''
          How old, in whole days, the host's newest snapshot on the NAS may
          get before the check says `down`.
        '';
      };
    };
  };
in
{
  options.ravnix.monitoring = {
    gpuCollector = mkOption {
      type = types.nullOr gpuCollector;
      default = null;
      description = ''
        The Beszel agent's GPU collector (GPU_COLLECTOR), a fact of the
        machine that its hardware module sets. null leaves it to the agent,
        which picks nvidia-smi wherever that is on its PATH and runs it every
        few seconds, which keeps a hybrid laptop's dGPU awake for as long as
        the agent runs.
      '';
    };

    beszel = mkOption {
      type = types.nullOr beszel;
      default = null;
      description = ''
        The Beszel agent, as a user unit that dials out to the hub while the
        user's manager runs. null: no agent.
      '';
    };

    kuma = mkOption {
      type = types.nullOr kuma;
      default = null;
      description = ''
        The heartbeat to an Uptime Kuma push monitor, every 15 minutes while
        the user's manager runs, and never made up after a suspend: a host
        that was away sends nothing for that time. null: no heartbeat.
      '';
    };

    backupAge = mkOption {
      type = types.nullOr backupAge;
      default = null;
      description = ''
        The dead man's switch of the host's backup (ravnix.backup.nas, with
        secrets = "rbw"): once a day, after the start and after each
        successful backup, it asks the NAS for the host's newest snapshot,
        pushes `up` to its monitor when it is younger than maxAgeDays and
        `down` when it is older or there is none. When it cannot tell (the
        vault locked, the NAS out of reach) it pushes nothing, and the
        monitor's own interval turns the silence into an alarm. null: no
        check.
      '';
    };
  };
}
