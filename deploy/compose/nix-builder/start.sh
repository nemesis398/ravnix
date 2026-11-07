#!/usr/bin/env bash
# Start script of the nix-builder container (see docker-compose.yaml next to
# this file). It runs as root at every start of the container, from the store
# on the /nix volume, and does five things:
#
#   1. checks the variables from .env (`start.sh --check-env` stops here);
#   2. refuses unless it runs as root in the container the compose file
#      starts (NIX_BUILDER_CONTAINER=1), because everything after this
#      rewrites /etc; then adds the accounts the image lacks: nix-builder (the
#      SSH user), sshd (its privilege separation user), harmonia, and a kvm
#      group that holds the build users;
#   3. writes nix.conf, then installs nix, openssh and harmonia from the
#      nixpkgs revision NIX_BUILDER_NIXPKGS names into the profile
#      /nix/var/nix/profiles/ravnix, whenever that revision is not the one
#      installed: changing it is how the builder is updated. The image's Nix
#      installs only the first time; after that the installed Nix installs
#      its successor. A failed update keeps the old tools and says so;
#   4. makes the SSH host key and the cache's signing key on the first start,
#      in /state, and prints both public halves;
#   5. starts harmonia, then waits until the egress rule holds (below), then
#      starts nix-daemon and sshd, all from that profile. It exits as soon as
#      one of them does, or once the rule has failed
#      NIX_BUILDER_PROBE_FAILURES probes in a row, so that Docker's restart
#      policy brings the container back, and it waits for the rule again.
#
# The egress rule (nix-firewall, firewall.sh) keeps builds off the LAN, and
# it is kept by another container, so the builder checks it from inside:
# every target in NIX_BUILDER_PROBES, an address and port that answers when
# the rule is missing, must give no answer within NIX_BUILDER_PROBE_TIMEOUT
# seconds, because the rule drops the connect. A connect that succeeds or is
# refused means the rule does not hold, and no build may run.
# `start.sh --probe` runs only that check; the health check calls it every
# minute, and the running script every NIX_BUILDER_PROBE_INTERVAL seconds.
#
# Nothing here prints a secret. The image links /etc/passwd, /etc/nix/nix.conf
# and other files into /nix/store, which is writable in this container, so a
# file is always removed before it is written: writing through such a link
# would change a store path.
#
# tests/deploy/nix-builder-start.nix sources this file to test its steps one
# by one in a scratch tree; the variables below say where that tree is.
set -euo pipefail
shopt -s inherit_errexit

etc=${NIX_BUILDER_ETC:-/etc}
var=${NIX_BUILDER_VAR:-/var}
run=${NIX_BUILDER_RUN:-/run}
state=${NIX_BUILDER_STATE:-/state}
kvm_device=${NIX_BUILDER_KVM_DEVICE:-/dev/kvm}
profiles=${NIX_BUILDER_PROFILES:-/nix/var/nix/profiles}
tools=$profiles/ravnix
bootstrap=$profiles/default/bin
need=(nix nix-daemon sshd ssh-keygen harmonia-cache)
probes=${NIX_BUILDER_PROBES:-}
probe_timeout=${NIX_BUILDER_PROBE_TIMEOUT:-2}
probe_interval=${NIX_BUILDER_PROBE_INTERVAL:-10}
probe_failures=${NIX_BUILDER_PROBE_FAILURES:-3}
pids=()
sleeper=

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

check_env() {
  local key=${NIX_BUILDER_AUTHORIZED_KEY:-} name=${NIX_CACHE_KEY_NAME:-}
  local pin=${NIX_BUILDER_NIXPKGS:-} var value
  local flake_ref='^[A-Za-z0-9+.-]+:[A-Za-z0-9/._?=&+-]+$'
  [ -n "$key" ] || die "NIX_BUILDER_AUTHORIZED_KEY is empty; set it in .env"
  case $key in
    *$'\n'* | *$'\r'*) die "NIX_BUILDER_AUTHORIZED_KEY holds more than one line" ;;
  esac
  [[ $key =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+)\ [A-Za-z0-9+/]+=*(\ .*)?$ ]] ||
    die "NIX_BUILDER_AUTHORIZED_KEY is not one public key line (type, base64, comment)"
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "NIX_CACHE_KEY_NAME must be letters, digits, '.', '_' and '-' only"
  # A flake reference without a fragment: the script adds #nix and the rest.
  [[ $pin =~ $flake_ref ]] ||
    die "NIX_BUILDER_NIXPKGS must be a flake reference such as github:NixOS/nixpkgs/<revision>, not '$pin'"
  for var in NIX_MIN_FREE NIX_MAX_FREE; do
    value=${!var:-}
    [ -z "$value" ] || [[ $value =~ ^[0-9]+[KMGT]?$ ]] ||
      die "$var must be a size like 500G, not '$value'"
  done
  check_probe_env
}

# The probe's variables, all that `start.sh --probe` needs.
check_probe_env() {
  local target octet part='(0|[1-9][0-9]{0,2})'
  local re="^$part\\.$part\\.$part\\.$part:([1-9][0-9]{0,4})\$"
  local -a targets
  [[ $probes =~ ^[0-9.:\ ]+$ ]] && read -ra targets <<<"$probes" && [ ${#targets[@]} -gt 0 ] ||
    die "NIX_BUILDER_PROBES must be IPv4 address:port pairs, separated by spaces, not '$probes'"
  for target in "${targets[@]}"; do
    [[ $target =~ $re ]] ||
      die "NIX_BUILDER_PROBES must be IPv4 address:port pairs without leading zeros, not '$target'"
    for octet in "${BASH_REMATCH[@]:1:4}"; do
      [ "$octet" -le 255 ] || die "NIX_BUILDER_PROBES must be IPv4 address:port pairs; '$target' has a number over 255"
    done
    [ "${BASH_REMATCH[5]}" -le 65535 ] || die "NIX_BUILDER_PROBES must be IPv4 address:port pairs; '$target' has a port over 65535"
  done
  seconds "$probe_timeout" 30 || die "NIX_BUILDER_PROBE_TIMEOUT must be more than 0 and at most 30 seconds, not '$probe_timeout'"
  seconds "$probe_interval" 3600 || die "NIX_BUILDER_PROBE_INTERVAL must be more than 0 and at most 3600 seconds, not '$probe_interval'"
  [[ $probe_failures =~ ^[1-9][0-9]?$|^100$ ]] ||
    die "NIX_BUILDER_PROBE_FAILURES must be a count from 1 to 100, not '$probe_failures'"
}

# Exits 0 when VALUE is a number of seconds, decimals allowed, above 0 and
# at most MAX.
seconds() { # value max
  [[ $1 =~ ^([0-9]{1,4})(\.[0-9]{1,3})?$ ]] || return 1
  [ "${BASH_REMATCH[1]}" -lt "$2" ] || { [ "${BASH_REMATCH[1]}" = "$2" ] && [[ ${BASH_REMATCH[2]} =~ ^(\.0*)?$ ]]; } || return 1
  [[ $1 =~ [1-9] ]]
}

# --- 2. Accounts ----------------------------------------------------------------

check_container() {
  [ "${NIX_BUILDER_CONTAINER:-}" = 1 ] ||
    die "start.sh is the entrypoint of the nix-builder container and rewrites /etc; it does not run outside that container (NIX_BUILDER_CONTAINER is not 1)"
  [ "$EUID" = 0 ] || die "start.sh must run as root, not as uid $EUID"
}

# The image links /etc/passwd, group and shadow into its store. Copies can be
# appended to. A link into a store path the volume lacks means the image tag
# changed after the store was seeded, and the copy would fail obscurely.
copy_etc_links() {
  local f
  for f in passwd group shadow; do
    [ -L "$etc/$f" ] || continue
    [ -e "$etc/$f" ] ||
      die "$etc/$f links to $(readlink -- "$etc/$f"), which the store on the volume does not hold: the image tag changed after the first start. Set it back to the tag the store was seeded from (docker-compose.yaml says why)."
    cp --remove-destination -- "$(readlink -f -- "$etc/$f")" "$etc/$f"
  done
  chmod 0644 "$etc/passwd" "$etc/group"
  chmod 0600 "$etc/shadow"
}

add_account() { # name uid home shell
  local name=$1 uid=$2 home=$3 login=$4
  has_entry "$etc/group" "$name" || echo "$name:x:$uid:" >>"$etc/group"
  has_entry "$etc/passwd" "$name" || echo "$name:x:$uid:$uid::$home:$login" >>"$etc/passwd"
  # '*' and not '!': without PAM, sshd refuses an account whose password
  # field marks it as locked, even for a key.
  has_entry "$etc/shadow" "$name" || echo "$name:*:1::::::" >>"$etc/shadow"
}

add_accounts() {
  local shell nologin
  shell=$(field_of "$etc/passwd" root 7)
  nologin=$(field_of "$etc/passwd" nobody 7)
  [ -x "$shell" ] || die "the image's root shell $shell is missing"
  add_account nix-builder 1000 "$var/lib/nix-builder" "$shell"
  add_account sshd 74 "$var/empty" "$nologin"
  add_account harmonia 30100 "$var/lib/harmonia" "$nologin"
}

make_homes() {
  install -d -m 0755 "$var/empty"
  install -d -m 0700 -o nix-builder -g nix-builder "$var/lib/nix-builder"
  install -d -m 0700 -o harmonia -g harmonia "$var/lib/harmonia"
}

# Nix gives a build user the supplementary groups /etc/group lists for it, so
# a group with the device's gid that holds every nixbld user lets their
# builds open /dev/kvm without opening it to everyone.
add_build_users_to_group() { # gid
  local gid=$1 members g_name g_pw g_id g_members
  members=$(cut -d: -f1 "$etc/passwd" | grep -x 'nixbld[0-9]*' | paste -sd,) ||
    die "the image has no nixbld users"
  if ! cut -d: -f3 "$etc/group" | grep -qxF -- "$gid"; then
    echo "kvm:x:$gid:$members" >>"$etc/group"
    return
  fi
  # A group with that gid exists already: add the build users to it, once.
  while IFS=: read -r g_name g_pw g_id g_members; do
    if [ "$g_id" = "$gid" ] && ! tr , '\n' <<<"$g_members" | grep -qx nixbld1; then
      g_members=${g_members:+$g_members,}$members
    fi
    echo "$g_name:$g_pw:$g_id:$g_members"
  done <"$etc/group" >"$etc/group.new"
  mv -- "$etc/group.new" "$etc/group"
  chmod 0644 "$etc/group"
}

# Prints yes when a build user can open the KVM device.
kvm_usable() {
  local shell
  shell=$(field_of "$etc/passwd" root 7)
  if [ -c "$kvm_device" ]; then
    add_build_users_to_group "$(stat -c %g "$kvm_device")"
    # Probe as a build user would run: its own uid and the groups above.
    if chroot --userspec=nixbld1:nixbld / "$shell" -c "exec 3<>$kvm_device" 2>/dev/null; then
      echo yes
      return
    fi
  fi
  echo no
}

# --- 3. Nix and the tools -------------------------------------------------------

write_nix_conf() { # kvm(yes|no)
  local features="big-parallel benchmark" gc=""
  [ "$1" = no ] || features="kvm nixos-test $features"
  [ -z "${NIX_MIN_FREE:-}" ] || gc+="min-free = $NIX_MIN_FREE"$'\n'
  [ -z "${NIX_MAX_FREE:-}" ] || gc+="max-free = $NIX_MAX_FREE"$'\n'
  mkdir -p "$etc/nix"
  put "$etc/nix/nix.conf" 0644 <<EOF
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
}

tools_complete() {
  local tool
  for tool in "${need[@]}"; do
    [ -x "$tools/bin/$tool" ] || return 1
  done
}

# Installs the tools from NIX_BUILDER_NIXPKGS when the profile lacks one or
# holds another revision. The new profile is built beside the old one and
# replaces it only once complete. The installed Nix installs its successor,
# so the store is never opened by a Nix older than the one that ran last;
# the image's Nix, frozen with the image tag, installs only the first time.
# A failed install keeps the old tools, and the pin they came from, and the
# next start tries again; only a first install that fails stops the start.
install_tools() {
  local pin=$NIX_BUILDER_NIXPKGS stamp=$state/tools-pin next=$tools-next have nix=$bootstrap/nix
  have=$(cat -- "$stamp" 2>/dev/null || true)
  if tools_complete; then
    [ "$have" != "$pin" ] || return 0
    nix=$tools/bin/nix
  fi
  say "installing nix, openssh and harmonia from $pin with $("$nix" --version)"
  rm -f -- "$next" "$next"-*-link
  if ! "$nix" profile add --profile "$next" "$pin#nix" "$pin#openssh" "$pin#harmonia"; then
    rm -f -- "$next" "$next"-*-link
    tools_complete || die "installing the tools from $pin failed, and there are no tools to fall back to"
    say "installing the tools from $pin failed; keeping the tools of ${have:-an unknown pin} until a start succeeds"
    return 0
  fi
  ln -sfn -- "$(readlink -f -- "$next")" "$tools.new"
  mv -fT -- "$tools.new" "$tools"
  rm -f -- "$tools"-*-link "$next" "$next"-*-link
  tools_complete || die "the profile $tools lacks one of ${need[*]} after the install"
  echo "$pin" >"$stamp"
}

# --- 4. Keys ------------------------------------------------------------------

make_host_key() {
  local host_key=$state/ssh/ssh_host_ed25519_key
  if [ ! -s "$host_key" ]; then
    say "making the SSH host key (first start)"
    rm -f -- "$host_key" "$host_key.pub"
    ssh-keygen -q -t ed25519 -N '' -C nix-builder -f "$host_key"
  fi
  chmod 0600 "$host_key"
  say "SSH host key: $(cat "$host_key.pub")"
  say "SSH host key for nix.buildMachines.*.publicHostKey: $(base64 -w0 "$host_key.pub")"
}

make_sign_key() {
  local sign_key=$state/cache/secret-key
  if [ ! -s "$sign_key" ]; then
    say "making the cache's signing key '$NIX_CACHE_KEY_NAME' (first start)"
    (umask 077 && nix key generate-secret --key-name "$NIX_CACHE_KEY_NAME" >"$sign_key.new")
    mv -- "$sign_key.new" "$sign_key"
  fi
  chmod 0600 "$sign_key"
  check_sign_key_name
  nix key convert-secret-to-public <"$sign_key" >"$state/cache/public-key"
  say "cache public key: $(cat "$state/cache/public-key")"
}

check_sign_key_name() {
  local have
  have=$(cut -d: -f1 "$state/cache/secret-key")
  [ "$have" = "$NIX_CACHE_KEY_NAME" ] ||
    die "the signing key in $state/cache/secret-key is named '$have', not NIX_CACHE_KEY_NAME '$NIX_CACHE_KEY_NAME'"
}

write_service_configs() {
  # harmonia runs as its own user and reads its own copy, on a tmpfs.
  install -d -m 0700 -o harmonia -g harmonia "$run/harmonia"
  install -m 0400 -o harmonia -g harmonia "$state/cache/secret-key" "$run/harmonia/secret-key"
  put "$run/harmonia/config.toml" 0644 <<'EOF'
bind = "0.0.0.0:5000"
workers = 4
max_connection_rate = 256
# Ahead of cache.nixos.org (40): this one is on the LAN.
priority = 30
EOF

  mkdir -p "$etc/ssh/authorized_keys.d"
  put "$etc/ssh/authorized_keys.d/nix-builder" 0644 <<EOF
restrict,command="$tools/bin/nix-daemon --stdio" $NIX_BUILDER_AUTHORIZED_KEY
EOF
  put "$etc/ssh/sshd_config" 0644 <<EOF
# Written by start.sh at every start of the container. One user, one key,
# one command: the key's forced command is the Nix daemon protocol.
Port 22
HostKey $state/ssh/ssh_host_ed25519_key
AllowUsers nix-builder
AuthorizedKeysFile $etc/ssh/authorized_keys.d/%u
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
PidFile $run/sshd.pid
# A remote build can stay silent for a long time.
ClientAliveInterval 60
ClientAliveCountMax 10
EOF
}

# --- 5. Run -------------------------------------------------------------------

# Exits 0 when a connect to TARGET (address:port) gets no answer within the
# probe timeout, as when the egress rule drops it. A connect that succeeds,
# or that is refused or unreachable, got an answer.
silent() { # target
  local rc=0
  # shellcheck disable=SC2016 # $1 and $2 are the inner shell's.
  timeout "$probe_timeout" "$BASH" -c 'exec 3<>"/dev/tcp/$1/$2"' _ "${1%:*}" "${1##*:}" 2>/dev/null || rc=$?
  [ "$rc" = 124 ]
}

# Exits 0 when every probe target is silent. Prints the ones that answered,
# else. They are probed at once, so this takes one timeout.
rule_holds() {
  local target i=0
  local -a targets jobs answered=()
  read -ra targets <<<"$probes"
  for target in "${targets[@]}"; do
    silent "$target" &
    jobs+=($!)
  done
  for target in "${targets[@]}"; do
    wait "${jobs[i]}" || answered+=("$target")
    i=$((i + 1))
  done
  [ ${#answered[@]} = 0 ] && return 0
  echo "${answered[*]}"
  return 1
}

# Exits 0 when process PID runs: exists and is not a zombie.
alive() { # pid
  [ -e "/proc/$1/status" ] && ! grep -q $'^State:\tZ' "/proc/$1/status" 2>/dev/null
}

# Sleeps for the probe interval, in a way a signal interrupts.
pause() {
  sleep "$probe_interval" &
  sleeper=$!
  wait "$sleeper" || true
}

# Waits until the egress rule holds, saying what answered whenever that
# changes. Returns 1 when the process PID, which should run all along,
# exits first.
wait_for_rule() { # pid
  local answered last=""
  until answered=$(rule_holds); do
    if [ "$answered" != "$last" ]; then
      say "waiting for the egress rule (nix-firewall): $answered answered, so builds would reach it"
      last=$answered
    fi
    alive "$1" || return 1
    pause
  done
  say "the egress rule holds: no answer from $probes"
}

# Probes every NIX_BUILDER_PROBE_INTERVAL seconds and returns 1 once
# NIX_BUILDER_PROBE_FAILURES probes in a row found the rule missing.
watchdog() {
  local fails=0 answered
  while :; do
    pause
    if answered=$(rule_holds); then
      fails=0
      continue
    fi
    fails=$((fails + 1))
    say "the egress rule failed a probe ($fails of $probe_failures in a row): $answered answered"
    if [ "$fails" -ge "$probe_failures" ]; then
      say "the egress rule no longer holds; stopping the Nix daemon and sshd"
      return 1
    fi
  done
}

start_harmonia() {
  chroot --userspec=harmonia:harmonia / env HOME="$var/lib/harmonia" \
    CONFIG_FILE="$run/harmonia/config.toml" SIGN_KEY_PATHS="$run/harmonia/secret-key" \
    "$(readlink -f "$tools/bin/harmonia-cache")" &
  pids+=($!)
}

start_builder() {
  "$tools/bin/nix-daemon" &
  pids+=($!)
  # sshd re-executes itself and wants its absolute path.
  "$(readlink -f "$tools/bin/sshd")" -D -e -f "$etc/ssh/sshd_config" &
  pids+=($!)
}

run_services() {
  local status=0
  pids=()
  stop() {
    kill -TERM "${pids[@]}" ${sleeper:+"$sleeper"} 2>/dev/null || true
    wait "${pids[@]}" 2>/dev/null || true
  }
  trap 'stop; exit 0' TERM INT

  # The cache runs no build, so it does not wait for the rule.
  start_harmonia
  if ! wait_for_rule "${pids[0]}"; then
    say "harmonia exited while the builder waited for the egress rule"
    stop
    exit 1
  fi
  start_builder
  watchdog &
  pids+=($!)
  say "running $("$tools/bin/nix" --version), harmonia, sshd"

  wait -n "${pids[@]}" || status=$?
  say "a service or the probe of the egress rule exited with status $status; stopping the others so Docker restarts the container"
  stop
  exit 1
}

main() {
  if [ "${1:-}" = --probe ]; then
    check_probe_env
    local answered
    answered=$(rule_holds) || die "the egress rule does not hold: $answered answered"
    say "the egress rule holds: no answer from $probes"
    exit 0
  fi
  check_env
  if [ "${1:-}" = --check-env ]; then
    say "the variables are fine"
    exit 0
  fi
  check_container
  export PATH="$tools/bin:$bootstrap"

  copy_etc_links
  add_accounts
  make_homes
  local kvm
  kvm=$(kvm_usable)
  say "kvm usable by the build users: $kvm"

  write_nix_conf "$kvm"
  install -d -m 0700 "$state" "$state/ssh" "$state/cache"
  chmod 0700 "$state" "$state/ssh" "$state/cache"
  install_tools

  make_host_key
  make_sign_key
  write_service_configs
  run_services
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
