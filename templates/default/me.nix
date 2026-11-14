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
    # The restic REST server the hosts back up to (deploy/compose/restic,
    # ravnix.backup.nas below) is the service restic-server, on its
    # RESTIC_PORT:
    #   restic-server = { enable = true; host = "nas"; port = 8000; };
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

    # The server.
    server = {
      # user@host or an ssh alias: the calendar that a click on Waybar's
      # clock opens on the server (khal over ssh), and an ssh of your own.
      sshTarget = "alice@192.0.2.20";
      # The server's address in your NetBird network. The main terminal key
      # opens herdr there, and the main connection goes there.
      netbirdAddress = "198.51.100.20";
      # The git repository Claude Code's Remote Control works from on the
      # server: every session you start from the phone gets a worktree of
      # it. An absolute path in a string, or null to leave Remote Control off.
      remoteControlDir = "/home/alice/src/project";
      # The public keys that may deploy to the server as root, one line of
      # a .pub file each. Root's own, never one the account or an agent on
      # the server holds: a security key's, made with its PIN (ssh-keygen
      # -t ed25519-sk -O verify-required; without the flag the server
      # refuses it), or one that stays on the laptop. Empty, root takes no
      # key at all.
      deployKeys = [ ];
      # The addresses a deploy may come from, as the server sees them: the
      # laptop's in your NetBird network. Bare addresses, no names.
      deployFrom = [ "198.51.100.10" ];
      # The way the server's tools are meant to reach a Proxmox node: a
      # dedicated key, an SSH key item of your vault, which the server
      # offers to that node alone; the node runs one command for it
      # (command="...",restrict in its authorized_keys, which you set up
      # there). Not the only way: the server's agent serves every SSH key of
      # the vault, a node's root key too, so an agent there can log in to a
      # node as root while the vault is unlocked, wherever the network lets
      # it (an accepted gap; see the workbench README). For example:
      #   proxmoxUpdate = {
      #     alias = "proxmox-update";   # ssh proxmox-update
      #     hostName = "192.0.2.40";
      #     user = "root";
      #     publicKey = "ssh-ed25519 AAAA... update@server";
      #   };
      proxmoxUpdate = null;
    };

    # How the server reaches the laptop over NetBird to run a command there
    # (`ravnix-laptop COMMAND`), with a key of its own. Make it on the
    # server with `ssh-keygen -t ed25519 -N "" -f <identityFile>`; neither
    # the YubiKey nor rbw's agent, which serves the vault's SSH keys, is
    # used. Each value can be null, which leaves that part out.
    laptopAccess = {
      # The private key, a file on the server only you can read. An absolute
      # path in a string.
      identityFile = "/home/alice/.ssh/ravnix-laptop";
      # Its public half, the line of the .pub file. The laptop accepts it
      # only from the server's NetBird address. Not a real key.
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey ravnix-laptop@example.org";
      # The laptop's host key (/etc/ssh/ssh_host_ed25519_key.pub on the
      # laptop). Null trusts the first key the laptop shows and remembers it.
      hostKey = null;
    };

    # How the laptop reaches the server over NetBird, for the main terminal
    # and the main connection, with a key of its own. Make it on the laptop
    # with `ssh-keygen -t ed25519 -N "" -f <identityFile>`; neither the
    # YubiKey nor rbw's agent, which serves the vault's SSH keys, is used.
    # Each value can be null, which leaves that part out. The laptop's
    # ~/.ssh/config is then home-manager's: move the host blocks of an
    # existing one, the git hosts' above all, into programs.ssh.matchBlocks
    # of your laptop's home-manager configuration before the first switch
    # (docs/install-from-another-distro.md in ravnix says how).
    serverAccess = {
      # The private key, a file on the laptop only you can read. An absolute
      # path in a string.
      identityFile = "/home/alice/.ssh/ravnix-server";
      # Its public half, the line of the .pub file, which the server accepts
      # for your account. Not a real key.
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey ravnix-server@example.org";
      # The server's host key (/etc/ssh/ssh_host_ed25519_key.pub on the
      # server). Null: the laptop never takes the first key the server
      # shows, since the main connection hands it your security key's agent.
      # It connects only once ~/.ssh/known_hosts has the key under the name
      # ravnix-server, which you add once by hand after comparing the
      # fingerprint (the option's description has the commands), and it
      # warns at every build until you copy the key in here.
      hostKey = null;
    };

    # The link between the hosts: the Obsidian vault, an absolute path in a
    # string, the same on both hosts when the file sync puts it in the same
    # place. On the server it is the git repository, where `vault-commit`
    # commits through the link's queue, once the Obsidian operations before
    # it have run on the laptop; on the laptop it is the copy without .git,
    # whose files a commit asked for there names, so the server waits until
    # the sync brings them.
    # null refuses vault-commit.
    link.vault = "/home/alice/notes";

    # The security key for git. The laptop runs an agent of its own that
    # holds the key handles below and nothing else, and the main connection
    # forwards it to the server, so that git there signs in with a touch on
    # the key at the laptop, and never with rbw's agent, which serves the
    # vault's SSH keys, for the hosts below. Empty lists leave both hosts as
    # they are.
    skAgent = {
      # Each handle, the file `ssh-keygen -t ed25519-sk` wrote (the one
      # without .pub, made without a passphrase), as an absolute path on the
      # laptop in a string, and the line of its .pub file. Not a real key.
      keys = [
        {
          handle = "/home/alice/.ssh/keys/github-sk";
          publicKey = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tExampleOnlyNotARealKey alice@example.org";
        }
      ];
      # The git hosts that ssh on the server reaches with them, as your git
      # remotes name them.
      hosts = [
        "github.com"
        "git.example.org"
      ];
    };

    # A tap on your security key (a YubiKey) instead of the password on the
    # laptop: at the login screen, the lock screen, sudo (after Allow in a
    # popup that names the command), su and polkit. The password keeps
    # working. The key needs a mapping, made once as yourself on any machine
    # with this origin, or copied from one (until then the password is asked
    # for as before):
    #   mkdir -p ~/.config/Yubico
    #   pamu2fcfg -o pam://ravnix -i pam://ravnix > ~/.config/Yubico/u2f_keys
    #   chmod 600 ~/.config/Yubico/u2f_keys
    security.u2f = {
      enable = false;
      # What the key's credential is bound to, the -o and -i above. The
      # same value on every machine keeps one enrollment working on all.
      origin = "pam://ravnix";
    };

    # The laptop.
    laptop = {
      # The git hosts and, for each, the security key's handle files
      # (ssh-keygen -t ed25519-sk) that log in there. ssh on the laptop uses
      # them alone for these hosts and asks no agent, so a push over ssh
      # takes a touch, which then holds for ten minutes; the vault's agent
      # keeps every other host. An HTTPS remote of GitHub takes gh's token
      # instead and no key. Host names in lowercase.
      gitKeys = {
        "github.com" = [ "/home/alice/.ssh/keys/github-sk" ];
        # GitHub's ssh on port 443, the same service under another name.
        "ssh.github.com" = [ "/home/alice/.ssh/keys/github-sk" ];
        "git.example.org" = [ "/home/alice/.ssh/keys/forge-sk" ];
      };
      # The one disk the installer may write, by model and serial as
      # `lsblk -o NAME,MODEL,SERIAL` prints them. Never by device name: an
      # nvme0n1 can be another disk after the next boot. huginn hides every
      # other internal disk from udisks by the serial.
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

    # Printing. Each printer is a CUPS queue that is created once the
    # printer can be reached: when a network comes up with it on, so a laptop
    # away from home neither fails nor retries. Name the queue as you like
    # (letters, digits, `.`, `_` and `-`); `uri` is what `lpinfo -v` shows for
    # the printer on your network, and `model` defaults to "everywhere", the
    # driverless protocol every recent printer answers.
    printing = {
      printers.office = {
        uri = "ipp://printer.example.org/ipp/print";
      };
      # One of the names above, or null for CUPS's own choice.
      defaultPrinter = "office";
    };

    # The VPNs. Secrets stay in Bitwarden: only item names or ids go here,
    # and rbw reads the value at the moment a command needs it.
    vpn = {
      # The NetBird management server your client enrolls with. For NetBird's
      # cloud that is "https://api.netbird.io:443".
      netbird.managementUrl = "https://netbird.example.org";
      # Your NordVPN account, for the `nord` command; null leaves it out.
      nord = {
        # Nord's id for the country the servers come from; 81 is Germany.
        countryId = 81;
        # The item with the access token `nord setup` uses once, and the name
        # of the item that gets a copy of the WireGuard key.
        tokenItem = "NordVPN - access token";
        keyItem = "NordVPN - NordLynx private key";
      };
      # The VPN gateway at home, for the `vpn-home` command; null leaves it out.
      home = {
        apiUrl = "http://gateway.example.org:8080";
        tokenItem = "VPN gateway - switch token";
      };
    };

    # The graphical applications of the laptop.
    apps = {
      # Cisco Packet Tracer. Its download needs a Networking Academy login, so
      # a host that asks for it does not build until you add the file to the
      # Nix store by hand (modules/desktop/apps.nix has the one command).
      packetTracer = false;

      # Helium's Widevine library, for sites with DRM: Apple Music plays full
      # tracks only with it. Unfree, so it is off unless you say so.
      widevine = false;

      # The web address of your own Catppuccin userstyles repository, the
      # styles for sites the official collection does not cover. Helium gets a
      # bookmark to it; Stylus takes the styles by a step modules/desktop/apps.nix
      # describes. Null when you have none.
      userstylesUrl = "https://git.example.org/alice/catppuccin-userstyles";

      # bitwarden-menu (`bwm`), a keyboard menu to your vault in fuzzel, beside
      # Bitwarden desktop. Off unless you turn it on; then it needs the three
      # values (a build without one stops and names it). server: your
      # Bitwarden or Vaultwarden address; email: your vault account's;
      # twoFactor: 0 for an authenticator app, 1 for a code by mail, 3 for a
      # YubiKey.
      bitwardenMenu = {
        enable = false;
        server = "https://vault.example.org";
        email = "alice@example.org";
        twoFactor = 0;
      };

      # Your self-hosted services as web apps, a Helium window each, found by
      # the launcher as webapp-NAME. Claude and Apple Music are web apps too,
      # and need no address. Null installs no launcher for that service.
      webapps = {
        mealie.url = "https://recipes.example.org/";
        nextcloud.url = "https://cloud.example.org/";
        openwebui.url = "https://ai.example.org/";
      };
    };

    # The desktop.
    desktop = {
      # Which output each workspace (1 to 10) prefers: the first connected
      # one in `outputs` wins. Use a description as `swaymsg -t get_outputs`
      # prints it (make, model, serial), which survives a change of port or
      # a USB-C dock; a connector name such as eDP-1 can change. Put the
      # built-in panel last, so that undocked it takes every workspace.
      # Empty means Sway decides. kanshiProfiles above use the same names.
      workspaceOutputs = [
        {
          number = 1;
          outputs = [ "eDP-1" ];
        }
        {
          number = 2;
          outputs = [
            "Example Corp Monitor 0x00000000"
            "eDP-1"
          ];
        }
      ];

      # The quick AI popup on Super+Shift+A: a question typed into fuzzel goes
      # to a model of your Open WebUI, and the answer comes back with a
      # prompt for the follow-up. Set it to null to leave the popup out.
      ask = {
        # The address of your Open WebUI, without a path.
        url = "https://chat.example.org";
        # The id of the model it asks, as Open WebUI lists it.
        model = "quick";
        # The Bitwarden item whose password is the API key; the popup reads
        # it through rbw at the moment you ask.
        rbwItem = "Open WebUI - API key";
      };

      # Unlock the login keyring after a login that gives PAM no password,
      # such as a YubiKey tap at the greeter, with the keyring's password
      # kept as a systemd credential of your user. It needs a one-time setup
      # on the laptop; the option's description has the command, and the
      # advice to give the keyring a password of its own first. Until then
      # it does nothing.
      keyring.autoUnlock.enable = false;
    };

    # Where rbw finds your secrets at runtime. Only the server and the
    # account; no secret goes into this flake.
    secrets = {
      # Your Bitwarden or Vaultwarden server.
      rbwBaseUrl = "https://vault.example.org";
      # The account rbw logs in as. Both hosts log in to it and see the
      # whole vault: on the server, every agent can read every item once
      # you have run ai-unlock there (modules/common/rbw.nix).
      rbwEmail = "alice@example.org";
      # HTTPS tokens for git, each for exactly one remote: git gets the
      # forge's user and the item's password for that URL and no other.
      # Per host, so set it in the host's own module, not here, if only one
      # host should push. For example:
      #   gitTokens = [ {
      #     url = "https://git.example.org/alice/private.git";
      #     username = "alice";
      #     item = "Forge - API token (private, write)";
      #   } ];
      gitTokens = [ ];
    };

    # The server's terminal programs. Each is unset (null, or no account), and
    # its program is then installed without an account, until you set it. Where a password is
    # needed, the option names the Bitwarden item that holds it: rbw reads
    # it when it is needed, and the password is in no flake.
    #
    # Your Nextcloud: muninn keeps a copy of the folders you name, synced
    # every few minutes without a window.
    nextcloud = {
      # The base address, without /remote.php or /dav.
      url = "https://cloud.example.org";
      # The account's login name, and the item with an app password for it
      # (Settings, Security, Create new app password).
      user = "alice";
      passwordItem = "Nextcloud - app password (server)";
      # Paths in the account; "/" is all of it. Each lands at the same path
      # under localRoot (null: Nextcloud in your home directory).
      folders = [
        "/Documents"
        "/Notes"
      ];
      localRoot = null;
    };

    # Your mail accounts in aerc, each by a name of your choice: IMAP with TLS
    # from the start, SMTP with TLS from the start (465) or STARTTLS (587,
    # with starttls = true). With several accounts, exactly one has
    # primary = true. Leave it empty for aerc without an account.
    mail.main = {
      address = "alice@example.org";
      primary = true;
      # The login of the servers, if it is not the address.
      login = null;
      imap = {
        host = "imap.example.org";
        port = 993;
      };
      smtp = {
        host = "smtp.example.org";
        port = 465;
        starttls = false;
      };
      passwordItem = "Mail - alice@example.org";
    };

    # Your calendar and contacts, copied by vdirsyncer and read in khal. For
    # Nextcloud both URLs are <url>/remote.php/dav/. carddavUrl is null to
    # keep no contacts.
    calendar = {
      caldavUrl = "https://cloud.example.org/remote.php/dav/";
      carddavUrl = "https://cloud.example.org/remote.php/dav/";
      user = "alice";
      passwordItem = "Nextcloud - app password (server)";
      # The calendar khal puts a new event in, by its name on the server.
      defaultCalendar = "personal";
      # Calendars published as a file, which you only read: a name of your
      # choice and the address of the feed.
      feeds.class = {
        url = "https://calendar.example.org/class.ics";
        color = "light magenta";
      };
    };

    # Notifications that must reach you with the lid closed: one Matrix room
    # and one bot per topic (sessions, updates, backups, builds, services; no
    # other). The bots' tokens come from rbw, from the Bitwarden item called
    # "Matrix - access token (ravnix-TOPIC)" unless a topic sets tokenItem.
    matrix = {
      # Your homeserver's client API.
      homeserver = "https://matrix.example.org";
      # Your own account there, which iamb logs in as (null: iamb has no
      # profile). Not one of the bots below.
      userId = "@alice:example.org";
      # roomId is null until the room exists, then its id ("!..."). A topic
      # without one is warned about at build time, and ravnix-notify exits
      # with status 78 for it. botUser is only for the record.
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

    # This host's backup to the rest-server, services.restic-server above,
    # or null for none. Per host, so set it in each host's own module (as
    # `ravnix.backup.nas = { ... };`, beside this null), never here: two
    # hosts with one host name would prune each other's snapshots. The null
    # below is a default (a lib.mkDefault, written out because this file is
    # plain data), so a host module's plain value replaces it; `host` must
    # be that machine's networking.hostName. For the laptop, for example:
    #   backup.nas = {
    #     # The host's one name at the NAS: the name its snapshots carry,
    #     # its repository's path and its login's user. The retention
    #     # file's [targets.<target>.hosts.<host>] knows it, and no other
    #     # machine backing up to the estate's Internxt repository may use
    #     # it, nor may a name of `hosts` that is not a ravnix host.
    #     host = "huginn";
    #     # Bitwarden items: the repository password, and the password of
    #     # the login at the rest-server.
    #     passwordItem = "Restic - huginn repository";
    #     loginItem = "Restic - huginn rest-server login";
    #     # The home, minus ~/.cache and CACHEDIR.TAG directories (always,
    #     # and keep cannot take them back), minus what another copy
    #     # holds, plus a folder taken back.
    #     paths = [ "~" ];
    #     exclude = [ "~/Nextcloud" "~/Git" ];
    #     keep = [ "~/Nextcloud/notes" ];
    #     onCalendar = "daily";
    #     # Where the two secrets come from: "rbw" (the vault, only while
    #     # it is unlocked), or "file", a root-only file written once from
    #     # the vault, for a server that backs up unattended; secretsFile
    #     # says how to write it.
    #     secrets = "rbw";
    #   };
    backup.nas = {
      _type = "override";
      priority = 1000;
      content = null;
    };

    # Your dictionary, as an absolute path to it in your checkout of this
    # flake: the tools add words to it at runtime, and every tool with a word
    # list gets them without a rebuild. Leave it out on a host that should
    # have no dictionary: it gets no sync of one.
    dictionary.file = "/home/alice/src/ravnix-private/dictionary.txt";

    # A user service syncs the dictionary with the tools' word lists (Handy,
    # LanguageTool, the prose skill) whenever one of them changes. false
    # leaves it to `ravnix-dict sync`, run by hand.
    dictionary.watch = true;

    # Your LanguageTool Premium account, whose word list the laptop keeps in
    # step with the dictionary: the name of your Bitwarden item whose
    # password is the API key, and the account you log in with. Both are
    # placeholders, and warn until you replace them.
    dictionary.languagetool = {
      rbwItem = "languagetool.example.org";
      username = "alice@example.org";
    };

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
    # Ravnix declares one server itself on both hosts, chrome-devtools (a
    # headless Helium for Claude Code's browser tools); a server of that name
    # here replaces it.
    claude.mcpServers = { };

    # The desktop's wallpaper and lock image. image is your own picture: a
    # path in your flake (./wallpaper.jpg) or an absolute path as a string;
    # null keeps ravnix's own wallpaper, Base with the ravnix mark in the
    # middle. tools is a list of SVG logos of your tools, for example
    # [ ./backdrop-logos/odin.svg ./backdrop-logos/rust.svg ], drawn on the
    # wallpaper in two Surface grays; empty draws none. Mind each logo's
    # license: ravnix ships no logo of a tool.
    desktop.backdrop = {
      image = null;
      tools = [ ];
    };

    # The radial menu behind the four-finger pinch on the trackpad. menu is
    # your own menu as a TOML file: a path in your flake, for example
    # ./radial/menu.toml (a rebuild picks up a change; `git add` a new file
    # first, since a flake sees only what git tracks), or a store path that
    # comes from a derivation. A string naming a file elsewhere, a store path
    # typed out (as text or as an unquoted path), a path outside the store and
    # a path to a missing or untracked file are refused. ravnix's own menu
    # (packages/sway-radial/menu.toml) is the model to copy. Null keeps
    # ravnix's own menu, which holds nothing that belongs to one machine: a
    # sink name, a display profile or an app of yours is what a menu of your
    # own is for.
    desktop.radial.menu = null;

    # What the small scripts (packages/NAME) need of you, besides what they
    # read from claude.skillValues above (web.searxngUrl for searx, vault.root
    # for vault-check, agent-doctor and the Anki deck builders, nextcloud.root
    # for claude-telemetry). None of them has a default that could pass for a
    # real value; a script whose value is not set says which one it wants.
    scripts = {
      # What vault-check accepts on purpose and the reference it compares
      # against, one entry per line: `unresolved NOTE NAME` accepts a link
      # that no note answers, `notes N` is the reference count of notes.
      # Empty writes no file, and vault-check warns that it is missing.
      # It lands in the Nix store: note names only, never a secret.
      vaultCheck.baseline = "";
      # The note that machine-facts --write, --check and --diff work on: an
      # absolute path, to a note with the two marker lines
      # `<!-- machine-facts:begin -->` and `<!-- machine-facts:end -->`.
      # For example "/home/alice/Notes/Laptop.md".
      machineFacts.note = null;
      # The document with your machine-wide working norms, which agent-doctor
      # takes as the home of the rules stated there. An absolute path.
      # For example "/home/alice/src/config/docs/working-norms.md".
      agentDoctor.normsFile = null;
      claudeTelemetry = {
        # Whether this host writes the weekly report (Monday 07:00). The
        # daily rows run on every host that has a telemetry folder
        # (nextcloud.root in claude.skillValues); the report merges all
        # hosts' rows and has one writer, so turn it on for one host only.
        # The value is a default (a lib.mkDefault, written out because this
        # file is plain data), so in the module of that one host a plain
        # `ravnix.scripts.claudeTelemetry.report = true;` is enough.
        report = {
          _type = "override";
          priority = 1000;
          content = false;
        };
        # The folders the report scans for Nextcloud conflict files, absolute
        # paths without a colon. Empty scans the vault (vault.root).
        conflictRoots = [ ];
        # Names (no slash) of the folders your Claude Code memory store is in
        # or was in, so that writes to notes there are counted.
        memoryDirs = [ ];
      };
      # The CCNA deck builder: where your card notes and their diagrams are,
      # as paths below the vault, and the name of the deck in Anki. Null
      # leaves ccna-deck unable to build and it says what to set.
      # For example "Notes/Cards", "attachments/cards" and "My CCNA".
      ccnaDeck = {
        notesDir = null;
        mediaDir = null;
        deckName = null;
      };
      # The SAP deck builder: the folder of the transaction notes, the note
      # with the shortcut tables (null leaves out those cards), the base that
      # lists the transactions (only named in a warning) and the deck file it
      # writes, as paths below the vault.
      # For example "Notes/Transactions", "Notes/Transactions/Shortcuts.md",
      # "Notes/Transactions/Transactions.base" and "Decks/transactions.apkg".
      sapDeck = {
        notesDir = null;
        shortcutsNote = null;
        transactionsBase = null;
        out = null;
      };
    };

    # The one accent of the desktop: focus and place, never a state. One of
    # "mauve", "lavender", "pink", "flamingo", "rosewater", "teal", "sky" or
    # "sapphire". NixOS and home-manager both take it from here.
    theme.accent = "mauve";
  };
}
