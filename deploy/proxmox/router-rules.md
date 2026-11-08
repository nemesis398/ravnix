# What the server needs from the network

A ravnix server in a segment of its own, a lab VLAN behind a router that
filters between segments, reaches the internet and little else. This is
every connection it needs, by role, with the port and the reason; turn each
one into a rule of your router, of your reverse proxy where a site is open
to named sources only, and of your mesh VPN. Write the rules with your
addresses in your private flake, beside the record of the VM, and check each
one from the server afterwards (the last column).

The server is the source unless the row says otherwise.

| To | Port | Why | Check from the server |
| --- | --- | --- | --- |
| The house resolvers | udp/53, tcp/53 | names, the internal ones included | `resolvectl query NAME` |
| Time servers (NixOS's pool, or the house's own) | udp/123 | the clock, through systemd-timesyncd | `timedatectl timesync-status` |
| The forge (behind the reverse proxy) | tcp/443, and the forge's ssh port | clone, fetch and push; Remote Control's repository; the private flake's lock push over HTTPS | `curl -sI https://FORGE`, `ssh -p PORT git@FORGE` |
| Nextcloud (behind the reverse proxy) | tcp/443 | the copy of the vault and the documents; CalDAV and CardDAV | `curl -sI https://CLOUD/status.php` |
| The NAS's administration login, in the management segment | its ssh port | the NAS's administration from the server: backups, Docker on the NAS | `ssh -p PORT ADMIN@NAS true` |
| Each Proxmox node's API, in the management segment | tcp/8006 | the estate's tools and the Datacenter Manager's view | `curl -skI https://NODE:8006` |
| The Nix builder | its ssh port (ssh-ng) | builds that are too big for the server, as the laptop sends them (`nixBuilder`) | `nix store info --store ssh-ng://…` |
| The Nix binary cache | its http port | substitutes the builder already made (`nixCache`) | `curl -s http://CACHE:PORT/nix-cache-info` |
| The Matrix homeserver | tcp/443 | iamb, and the rooms that notifications go to | `curl -s https://MATRIX/_matrix/client/versions` |
| NetBird: management, signal, relay | tcp/443 | the server as a peer of the mesh, so the laptop reaches it from anywhere | `netbird status` |
| NetBird's STUN server | udp/3478 | the server's own address as the internet sees it, for direct tunnels | `netbird status -d` |
| NetBird peers | udp/51820 | direct WireGuard tunnels, both ways | `netbird status -d` |
| The internet | tcp/443, tcp/22 | Claude Code, the password vault, GitHub, cache.nixos.org, package registries | `curl -sI https://cache.nixos.org` |

And to the server:

| From | Port | Why |
| --- | --- | --- |
| The laptop, through the mesh's route into the house or as a peer | tcp/22 | the main terminal (herdr), Claude Code from the laptop, and the deploy as root (from an address of `ravnix.server.deployFrom` only) |
| The laptop's segments, if the laptop can sit in the house without the mesh | udp/51820 | NetBird's direct tunnel to the server |

A reverse proxy that answers only named sources (a 403 for the rest) needs
the server named for each site it uses: the forge and Nextcloud above, and
any other the server's tools open, such as a search engine or a sync server.

Not on the list, because the server does not need it: ssh from the server to
a hypervisor node. Root on a node is root on every guest it runs, the server
included (through the guest agent), so a rule like that, with a key an agent
on the server can use, undoes the deploy login. Decide it on its own, and
prefer a key on the node that is limited to one command.
