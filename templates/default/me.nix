# Your personal values, the only place ravnix reads them from. Every option
# ravnix has is listed here with what it is for; replace each example value
# with yours. The examples use addresses and names reserved for
# documentation (RFC 5737, RFC 2606), so nothing here reaches a real machine.
{
  ravnix = {
    # Who you are, as git commits, your account and the forges see you.
    user = {
      # Your full name.
      name = "Alice Example";
      # Your mail address, as your commits show it.
      email = "alice@example.org";
      # Your login name, the same on both hosts.
      username = "alice";
      # Your GitHub account name.
      githubUser = "alice-example";
      # The SSH public key your commits are signed with: one line of its
      # .pub file, without git's `key::` prefix. Not a real key.
      signingKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey alice@example.org";
    };

    # Your checkout of ravnix, if you work on ravnix itself: its git hooks
    # are turned on there and read your deny list. Absolute paths in
    # strings. Leave both null if you only use ravnix.
    dev = {
      # For example "/home/alice/src/ravnix".
      checkout = null;
      # For example "/home/alice/src/ravnix-private/deny-list.txt".
      denyList = null;
    };

    # The machines your hosts and services run on, by a name you choose.
    # address: where the host is reached (an IP address or a DNS name).
    # runtime: "nixos", "docker", "proxmox-ct" or "external".
    # sshTarget: how ssh reaches it (user@host or an ssh alias), or null.
    hosts = {
      # The laptop. Its address in your NetBird network, since it roams.
      huginn = {
        address = "198.51.100.10";
        runtime = "nixos";
        sshTarget = "alice@198.51.100.10";
      };
      # The server, a VM or a container that keeps your sessions running.
      muninn = {
        address = "192.0.2.20";
        runtime = "nixos";
        sshTarget = "alice@192.0.2.20";
      };
      # A NAS that runs containers: services go there as compose files.
      nas = {
        address = "192.0.2.30";
        runtime = "docker";
        sshTarget = "admin@nas.example.org";
      };
    };

    # Where each service runs, by the name its ravnix module reads: `host`
    # names an entry of `hosts`, and clients read the derived, read-only
    # `url`, so moving a service is a change of one line. For example:
    #   paperless = { enable = true; host = "nas"; port = 8000; };
    # The Nix binary cache and builder (deploy/compose/nix-builder) are the
    # services nix-cache and nix-builder:
    #   nix-cache = { enable = true; host = "nas"; port = 8501; };
    #   nix-builder = { enable = true; host = "nas"; port = 2224; };
    services = { };

    # What a host needs to use that cache and builder besides their place.
    # The container prints both keys at its first start. Without the two
    # services above, these values are not read.
    nixCache = {
      # The cache's public key, name:base64. Not a real key.
      publicKey = "cache.example.org-1:rL9Ff7wZpxDq4Wv3mN2hK5sT8yU1oE6aG0jC3bV7nXA=";
    };
    nixBuilder = {
      # The builder's SSH host key, the whole .pub line in base64, as the
      # container prints it. Not a real key.
      hostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUV4YW1wbGVPbmx5Tm90QVJlYWxLZXlFeGFtcGxlT25seU5vdEFSZWFsS2V5IG5peC1idWlsZGVyCg==";
      # The user the hosts log in as, and the private key root logs in with:
      # a root-only file on each host that you write by hand from your
      # password manager (`sudo install -m 600 /dev/stdin <path>`). It is a
      # file and not fetched at runtime, because the Nix daemon builds
      # unattended; the option's description says more.
      sshUser = "nix-builder";
      sshKey = "/etc/nix/nix-builder_ed25519";
      # Whether the builder can run nixosTests: its start log says whether
      # its build users can open /dev/kvm.
      kvm = false;
      # Builds a host runs there at once, and how Nix ranks the builder.
      maxJobs = 4;
      speedFactor = 1;
      systems = [ "x86_64-linux" ];
    };

    # How the laptop's main terminal reaches the server.
    server = {
      # user@host or an ssh alias; the main terminal key opens herdr there.
      sshTarget = "alice@192.0.2.20";
      # The server's address in your NetBird network.
      netbirdAddress = "198.51.100.20";
    };

    # The laptop.
    laptop = {
      # The one disk the installer may write, by model and serial as
      # `lsblk -o NAME,MODEL,SERIAL` prints them. Never by device name: an
      # nvme0n1 can be another disk after the next boot.
      diskModel = "Example SSD 1TB";
      diskSerial = "EXAMPLE0SERIAL";
      # Your monitor layouts, in order; kanshi applies the first whose
      # outputs are exactly the connected ones. criteria is a connector
      # name, a description as `swaymsg -t get_outputs` prints it, or "*".
      # status ("enable" or "disable"), mode, position and scale are
      # optional.
      kanshiProfiles = [
        {
          name = "laptop";
          outputs = [
            {
              criteria = "eDP-1";
              mode = "1920x1200@60Hz";
              position = "0,0";
              scale = 1.0;
            }
          ];
        }
        {
          name = "docked";
          outputs = [
            {
              criteria = "eDP-1";
              position = "2560,0";
              scale = 1.0;
            }
            {
              criteria = "Example Corp Monitor 0x00000000";
              mode = "2560x1440@60Hz";
              position = "0,0";
              scale = 1.0;
            }
          ];
        }
      ];
    };

    # Where rbw finds your secrets at runtime. Only the server and the
    # account; no secret goes into this flake.
    secrets = {
      # Your Bitwarden or Vaultwarden server.
      rbwBaseUrl = "https://vault.example.org";
      # The account rbw logs in as.
      rbwEmail = "alice@example.org";
    };

    # Notifications that must reach you with the lid closed: one Matrix room
    # and one bot per topic. The bots' tokens come from rbw.
    matrix = {
      # Your homeserver's client API.
      homeserver = "https://matrix.example.org";
      # roomId is null until the room exists, then its id ("!...").
      rooms = {
        sessions = {
          roomId = null;
          botUser = "@ravnix-sessions:example.org";
        };
        updates = {
          roomId = null;
          botUser = "@ravnix-updates:example.org";
        };
        backups = {
          roomId = null;
          botUser = "@ravnix-backups:example.org";
        };
        builds = {
          roomId = null;
          botUser = "@ravnix-builds:example.org";
        };
        services = {
          roomId = null;
          botUser = "@ravnix-services:example.org";
        };
      };
    };

    # How many backups each target keeps; see the comments in the file.
    backup.retentionFile = ./backups.toml;

    # Your dictionary, as an absolute path to it in your checkout of this
    # flake: the tools add words to it at runtime, and every tool with a word
    # list gets them without a rebuild.
    dictionary.file = "/home/alice/src/ravnix-private/dictionary.txt";

    # The languages the editor installs language servers, formatters and
    # linters for. All of them; drop the ones you do not edit to keep the
    # editor small (the Odin toolchain behind "odin" is 2.3 GiB). Edit this
    # list: a second definition elsewhere is an error, unless it is a
    # lib.mkForce.
    editor.languages = [
      "bash"
      "json"
      "languagetool"
      "lua"
      "markdown"
      "nix"
      "odin"
      "python"
      "web"
    ];

    # The shell. secretEnv names the environment variables that `claude` gets
    # from your Bitwarden when it starts: the variable's name (capital
    # letters, digits and underscores) and the name or id of the item whose
    # password is its value (an id is the safer one: renaming the item never
    # breaks it). Only item names or ids go into this flake; rbw reads the
    # values at the moment `claude` starts, and no other program sees them.
    # For example:
    #   secretEnv = { SERVICE_API_TOKEN = "Service - API token"; };
    # (ravnix.shell.autoAttach is a seam for ravnix's own modules, not a value
    # to set.)
    shell.secretEnv = { };

    # Values the public Claude Code skills read (destinations, ids, house
    # rules), rendered to JSON. A skill that needs a missing value says
    # which key to set.
    claude.skillValues = { };

    # The MCP servers Claude Code starts with in every project, by name, each
    # the JSON of one server as Claude Code's mcpServers holds it. A header or
    # an environment value must be a reference to a variable of Claude Code's
    # environment (`Bearer ${NAME}` or `${NAME}`), never a value, so that no
    # token enters the Nix store; shell.secretEnv above puts the variable
    # there. For example:
    #   mcpServers.docs = {
    #     type = "http";
    #     url = "https://mcp.example.org/mcp";
    #     headers.Authorization = "Bearer \${DOCS_API_TOKEN}";
    #   };
    # In a Nix string the reference is written \${NAME} (or ''${NAME} inside
    # ''...''): a bare ${NAME} is Nix's own interpolation and fails.
    claude.mcpServers = { };

    # The one accent of the desktop: focus and place, never a state. One of
    # "mauve", "lavender", "pink", "flamingo", "rosewater", "teal", "sky" or
    # "sapphire". NixOS and home-manager both take it from here.
    theme.accent = "mauve";
  };
}
