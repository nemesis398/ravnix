# muninn-seccomp: the seccomp profile that deploy/compose/muninn gives the
# container for rootless Podman inside it. It is Docker's default profile and
# one rule more: pivot_root, which Docker's profile allows to nobody,
# SYS_ADMIN or not. pasta, Podman's network for a rootless container,
# sandboxes itself with pivot_root and stops without it ("Failed to
# pivot_root() into empty tmpfs"), and crun needs it to give a container its
# own root instead of a chroot it can leave. Everything else in Docker's
# profile stays, keyctl's block among them.
#
# Docker's profile is the one of moby/profiles seccomp v0.2.3, which Docker
# 29.6.2 builds in (its go.mod), pinned by revision and hash. Docker reads a
# seccomp=FILE on the client, so the file is what counts, not the host's
# Docker version; a newer Docker's profile may allow newer system calls,
# which this one refuses with EPERM until it is moved to that release.
#
# deploy/compose/muninn/seccomp.json is a copy of this output, because a
# compose file names a file next to it; workbench-oci fails when the two
# differ, or when the copy is anything but Docker's profile with exactly the
# rule for pivot_root added. After a change here:
#
#   nix build .#muninn-seccomp && install -m 644 result deploy/compose/muninn/seccomp.json
{
  runCommand,
  fetchurl,
  jq,
}:
let
  # moby/profiles, tag seccomp/v0.2.3
  docker = fetchurl {
    url = "https://raw.githubusercontent.com/moby/profiles/836ae4d37ef2ec995c77c99fc55f5b5f3af3a897/seccomp/default.json";
    hash = "sha256-U2UptmXdCXLDe/tWn11KyKU1kuewB1K8Of8GPKmGTHQ=";
  };
in
runCommand "muninn-seccomp.json"
  {
    nativeBuildInputs = [ jq ];
    passthru = { inherit docker; };
  }
  ''
    # Docker's profile allows no pivot_root, so this is the one rule for it.
    jq -e '[.syscalls[] | select(.names | index("pivot_root"))] | length == 0' ${docker} >/dev/null
    jq '.syscalls += [{ "names": [ "pivot_root" ], "action": "SCMP_ACT_ALLOW" }]' ${docker} >$out
  ''
