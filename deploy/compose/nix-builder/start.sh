#!/usr/bin/env bash
# Start script of the nix-builder container (see docker-compose.yaml next to
# this file). It runs as root at every start of the container, from the store
# on the /nix volume, and does five things:
#
#   1. checks the variables from .env (`start.sh --check-env` stops here,
#      and without it the script refuses to go on outside a container);
#   2. adds the accounts the image lacks: nix-builder (the SSH user), sshd
#      (its privilege separation user), harmonia, and a kvm group that holds
#      the build users;
#   3. writes nix.conf, then installs openssh and harmonia into the profile
#      /nix/var/nix/profiles/ravnix if they are not there yet;
#   4. makes the SSH host key and the cache's signing key on the first start,
#      in /state, and prints both public halves;
#   5. starts nix-daemon, harmonia and sshd, and exits as soon as one of them
#      does, so that Docker's restart policy brings all three back.
#
# Nothing here prints a secret. The image links /etc/passwd, /etc/nix/nix.conf
# and other files into /nix/store, which is writable in this container, so a
# file is always removed before it is written: writing through such a link
# would change a store path.
set -euo pipefail
shopt -s inherit_errexit

state=/state
tools=/nix/var/nix/profiles/ravnix
nix_bin=/nix/var/nix/profiles/default/bin
export PATH="$tools/bin:$nix_bin"

say() { echo "start.sh: $*"; }
die() {
  echo "start.sh: $*" >&2
  exit 1
}

# Replaces a file, or a link to one, with what arrives on stdin.
put() {
  local file=$1 mode=$2
  rm -f -- "$file"
  cat >"$file"
  chmod "$mode" -- "$file"
}

# Exits 0 when FILE has an entry named NAME (the first colon-separated field).
# The image has no awk, so this and the rest use grep, cut and bash.
has_entry() {
  cut -d: -f1 -- "$1" | grep -qxF -- "$2"
}

# Prints field N of the entry named NAME in FILE.
field_of() {
  grep -F -- "$2:" "$1" | while IFS= read -r line; do
    [ "${line%%:*}" = "$2" ] && cut -d: -f"$3" <<<"$line"
  done
}

# --- 1. The variables ---------------------------------------------------------

key=${NIX_BUILDER_AUTHORIZED_KEY:-}
key_name=${NIX_CACHE_KEY_NAME:-}
[ -n "$key" ] || die "NIX_BUILDER_AUTHORIZED_KEY is empty; set it in .env"
case $key in
  *$'\n'* | *$'\r'*) die "NIX_BUILDER_AUTHORIZED_KEY holds more than one line" ;;
esac
[[ $key =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+)\ [A-Za-z0-9+/]+=*(\ .*)?$ ]] ||
  die "NIX_BUILDER_AUTHORIZED_KEY is not one public key line (type, base64, comment)"
[[ $key_name =~ ^[A-Za-z0-9._-]+$ ]] ||
  die "NIX_CACHE_KEY_NAME must be letters, digits, '.', '_' and '-' only"
for var in NIX_MIN_FREE NIX_MAX_FREE; do
  value=${!var:-}
  [ -z "$value" ] || [[ $value =~ ^[0-9]+[KMGT]?$ ]] ||
    die "$var must be a size like 500G, not '$value'"
done

# `start.sh --check-env` stops here; tests/deploy/nix-builder-start.nix runs it.
if [ "${1:-}" = --check-env ]; then
  say "the variables are fine"
  exit 0
fi
# Everything below rewrites /etc, which is only safe in the container.
[ -e /.dockerenv ] || [ -e /run/.containerenv ] ||
  die "start.sh is the entrypoint of the nix-builder container and rewrites /etc; it does not run outside a container"

# --- 2. Accounts ----------------------------------------------------------------

for f in passwd group shadow; do
  if [ -L "/etc/$f" ]; then
    cp --remove-destination -- "$(readlink -f "/etc/$f")" "/etc/$f"
  fi
done
chmod 0644 /etc/passwd /etc/group
chmod 0600 /etc/shadow

shell=$(field_of /etc/passwd root 7)
nologin=$(field_of /etc/passwd nobody 7)
[ -x "$shell" ] || die "the image's root shell $shell is missing"

add_account() { # name uid home shell
  local name=$1 uid=$2 home=$3 login=$4
  has_entry /etc/group "$name" || echo "$name:x:$uid:" >>/etc/group
  has_entry /etc/passwd "$name" || echo "$name:x:$uid:$uid::$home:$login" >>/etc/passwd
  # '*' and not '!': without PAM, sshd refuses an account whose password
  # field marks it as locked, even for a key.
  has_entry /etc/shadow "$name" || echo "$name:*:1::::::" >>/etc/shadow
}
add_account nix-builder 1000 /var/lib/nix-builder "$shell"
add_account sshd 74 /var/empty "$nologin"
add_account harmonia 30100 /var/lib/harmonia "$nologin"
install -d -m 0755 /var/empty
install -d -m 0700 -o nix-builder -g nix-builder /var/lib/nix-builder
install -d -m 0700 -o harmonia -g harmonia /var/lib/harmonia

# Nix gives a build user the supplementary groups /etc/group lists for it, so
# a group with the device's gid that holds every nixbld user lets their
# builds open /dev/kvm without opening it to everyone.
kvm=no
if [ -c /dev/kvm ]; then
  gid=$(stat -c %g /dev/kvm)
  members=$(cut -d: -f1 /etc/passwd | grep -x 'nixbld[0-9]*' | paste -sd,)
  [ -n "$members" ] || die "the image has no nixbld users"
  if ! cut -d: -f3 /etc/group | grep -qxF -- "$gid"; then
    echo "kvm:x:$gid:$members" >>/etc/group
  else
    # A group with that gid exists already: add the build users to it, once.
    while IFS=: read -r g_name g_pw g_id g_members; do
      if [ "$g_id" = "$gid" ] && ! tr , '\n' <<<"$g_members" | grep -qx nixbld1; then
        g_members=${g_members:+$g_members,}$members
      fi
      echo "$g_name:$g_pw:$g_id:$g_members"
    done </etc/group >/etc/group.new
    mv -- /etc/group.new /etc/group
    chmod 0644 /etc/group
  fi
  # Probe as a build user would run: its own uid and the groups above.
  if chroot --userspec=nixbld1:nixbld / "$shell" -c 'exec 3<>/dev/kvm' 2>/dev/null; then
    kvm=yes
  fi
fi
say "kvm usable by the build users: $kvm"

# --- 3. Nix and the tools -------------------------------------------------------

features="big-parallel benchmark"
[ "$kvm" = no ] || features="kvm nixos-test $features"
gc=""
[ -z "${NIX_MIN_FREE:-}" ] || gc+="min-free = $NIX_MIN_FREE"$'\n'
[ -z "${NIX_MAX_FREE:-}" ] || gc+="max-free = $NIX_MAX_FREE"$'\n'

mkdir -p /etc/nix
put /etc/nix/nix.conf 0644 <<EOF
# Written by start.sh at every start of the container.
build-users-group = nixbld
# No sandbox: it needs kernel namespaces that Docker's default capabilities
# withhold (docker-compose.yaml says why they are not granted).
sandbox = false
experimental-features = nix-command flakes
# nix-builder is the SSH user; trusted, because a remote build imports paths
# that no key signed. Nobody else may talk to the daemon, the build users
# included.
trusted-users = root nix-builder
allowed-users = root nix-builder
substituters = https://cache.nixos.org/
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
system-features = $features
max-jobs = 4
cores = 0
${gc}
EOF

need=(sshd ssh-keygen harmonia-cache)
missing=no
for tool in "${need[@]}"; do
  [ -x "$tools/bin/$tool" ] || missing=yes
done
if [ "$missing" = yes ]; then
  say "installing openssh and harmonia into $tools (first start)"
  rm -f -- "$tools" "$tools"-*-link
  nix profile add --profile "$tools" nixpkgs#openssh nixpkgs#harmonia
fi
for tool in "${need[@]}"; do
  [ -x "$tools/bin/$tool" ] || die "$tool is missing from $tools after the install"
done

# --- 4. Keys ------------------------------------------------------------------

install -d -m 0700 "$state" "$state/ssh" "$state/cache"
chmod 0700 "$state" "$state/ssh" "$state/cache"

host_key=$state/ssh/ssh_host_ed25519_key
if [ ! -s "$host_key" ]; then
  say "making the SSH host key (first start)"
  rm -f -- "$host_key" "$host_key.pub"
  ssh-keygen -q -t ed25519 -N '' -C nix-builder -f "$host_key"
fi
chmod 0600 "$host_key"
say "SSH host key: $(cat "$host_key.pub")"
say "SSH host key for nix.buildMachines.*.publicHostKey: $(base64 -w0 "$host_key.pub")"

sign_key=$state/cache/secret-key
if [ ! -s "$sign_key" ]; then
  say "making the cache's signing key '$key_name' (first start)"
  (umask 077 && nix key generate-secret --key-name "$key_name" >"$sign_key.new")
  mv -- "$sign_key.new" "$sign_key"
fi
chmod 0600 "$sign_key"
[ "$(cut -d: -f1 "$sign_key")" = "$key_name" ] ||
  die "the signing key in $sign_key is named '$(cut -d: -f1 "$sign_key")', not NIX_CACHE_KEY_NAME '$key_name'"
nix key convert-secret-to-public <"$sign_key" >"$state/cache/public-key"
say "cache public key: $(cat "$state/cache/public-key")"

# harmonia runs as its own user and reads its own copy, on a tmpfs.
install -d -m 0700 -o harmonia -g harmonia /run/harmonia
install -m 0400 -o harmonia -g harmonia "$sign_key" /run/harmonia/secret-key
put /run/harmonia/config.toml 0644 <<'EOF'
bind = "0.0.0.0:5000"
workers = 4
max_connection_rate = 256
# Ahead of cache.nixos.org (40): this one is on the LAN.
priority = 30
EOF

mkdir -p /etc/ssh/authorized_keys.d
put /etc/ssh/authorized_keys.d/nix-builder 0644 <<EOF
restrict,command="$nix_bin/nix-daemon --stdio" $key
EOF
put /etc/ssh/sshd_config 0644 <<EOF
# Written by start.sh at every start of the container. One user, one key,
# one command: the key's forced command is the Nix daemon protocol.
Port 22
HostKey $host_key
AllowUsers nix-builder
AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
UsePAM no
PermitTTY no
PermitUserEnvironment no
AllowAgentForwarding no
AllowTcpForwarding no
AllowStreamLocalForwarding no
X11Forwarding no
PermitTunnel no
PidFile /run/sshd.pid
# A remote build can stay silent for a long time.
ClientAliveInterval 60
ClientAliveCountMax 10
EOF

# --- 5. Run -------------------------------------------------------------------

pids=()
stop() {
  kill -TERM "${pids[@]}" 2>/dev/null || true
  wait || true
}
trap 'stop; exit 0' TERM INT

"$nix_bin/nix-daemon" &
pids+=($!)
chroot --userspec=harmonia:harmonia / env HOME=/var/lib/harmonia \
  CONFIG_FILE=/run/harmonia/config.toml SIGN_KEY_PATHS=/run/harmonia/secret-key \
  "$(readlink -f "$tools/bin/harmonia-cache")" &
pids+=($!)
# sshd re-executes itself and wants its absolute path.
"$(readlink -f "$tools/bin/sshd")" -D -e -f /etc/ssh/sshd_config &
pids+=($!)
say "running: nix-daemon, harmonia, sshd"

status=0
wait -n "${pids[@]}" || status=$?
say "a service exited with status $status; stopping the others so Docker restarts the container"
stop
exit 1
