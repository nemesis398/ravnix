# deploy/compose/nix-builder/firewall.sh against a fake iptables
# (helpers/fake-iptables.sh) that starts out as a NAS's filter table does:
# UGOS's own rules in INPUT and DOCKER-USER.
#
# - A first run puts the two chains in place, with two jumps to each first
#   in DOCKER-USER and INPUT, one for the bridge and one for the subnet, and
#   UGOS's rules after them in their order. A rerun changes nothing. --check
#   reports without changing.
# - It repairs what a NAS does to the chains: a rule put ahead of a jump, a
#   second copy of one, the two swapped, a chain whose rules were changed, a
#   chain that is gone. The keeper loop does so on its own, logs what it repaired, and
#   stops on TERM; restarted on a table that has the rule, it changes nothing.
# - Two runs at once leave the table right after the next pass.
# - --remove gives back the table as it was, and is harmless twice.
# - It refuses, before any iptables call, a subnet that is no IPv4 network
#   (host bits, a leading zero, an octet or prefix out of range, IPv6, extra
#   words), a bridge that is no interface name, and an interval that is no
#   number of seconds; a missing
#   DOCKER-USER, a missing iptables and a failing one stop it with an error,
#   which the service's restart policy retries.
#
# That the real iptables prints the rules the way the script compares them
# is in tests/services/nix-builder.md, from the NAS.
{ pkgs, ... }:
pkgs.runCommand "deploy-nix-builder-firewall"
  {
    script = ../../deploy/compose/nix-builder/firewall.sh;
    fake = ./helpers/fake-iptables.sh;
    nativeBuildInputs = [
      pkgs.shellcheck
      pkgs.util-linux
    ];
  }
  ''
    shellcheck -s bash "$script" "$fake"

    bash=$(command -v bash)
    # The sandbox has no /usr/bin/env for the fake's first line.
    printf '#!%s\nexec %s %s "$@"\n' "$bash" "$bash" "$fake" >"$TMPDIR/iptables"
    chmod +x "$TMPDIR/iptables"
    fake=$TMPDIR/iptables
    failed=0
    fail() {
      printf 'FAIL: %s\n' "$*"
      failed=1
    }

    # table: a fresh filter table as the NAS has it, in a new directory.
    table() {
      local d c
      d=$(mktemp -d "$TMPDIR/table.XXXXXX")
      mkdir "$d/chains"
      : >"$d/log"
      for c in INPUT FORWARD OUTPUT UG_INPUT UG_FORWARD DOCKER-USER DOCKER-FORWARD; do
        : >"$d/chains/$c"
      done
      echo "-j UG_INPUT" >"$d/chains/INPUT"
      printf '%s\n' "-j DOCKER-USER" "-j DOCKER-FORWARD" >"$d/chains/FORWARD"
      printf '%s\n' "-j UG_FORWARD" "! -i docker0 ! -o docker0 -j ACCEPT" >"$d/chains/DOCKER-USER"
      echo "$d"
    }
    # fw TABLE ARGS...: firewall.sh against TABLE, with only the variables
    # subnet and bridge (unset: good ones), interval and broken (empty: none)
    # give, and
    # under the command in the array limit.
    limit=()
    fw() {
      local d=$1
      local -a vars=(PATH="$PATH" FAKE_IPT="$d" IPTABLES="$fake" NIX_BUILDER_SUBNET="''${subnet-10.0.200.0/24}"
        NIX_BUILDER_BRIDGE="''${bridge-br-nix-builder}")
      shift
      [ -z "''${interval-}" ] || vars+=(NIX_FIREWALL_INTERVAL="$interval")
      [ -z "''${broken-}" ] || vars+=(FAKE_IPT_FAIL="$broken")
      "''${limit[@]}" env -i "''${vars[@]}" "$bash" "$script" "$@"
    }
    snapshot() { (cd "$1/chains" && for c in *; do echo "== $c" && cat -- "$c"; done); }
    changes() { grep -cE '^-(N|F|X|A|I|D) ' "$1/log" || true; }

    # The table once the rule is in place, as snapshot prints it.
    applied=$(printf '%s\n' \
      "== DOCKER-FORWARD" \
      "== DOCKER-USER" \
      "-i br-nix-builder -j RAVNIX-NIX-BUILDER-OUT" \
      "-s 10.0.200.0/24 -j RAVNIX-NIX-BUILDER-OUT" \
      "-j UG_FORWARD" \
      "! -i docker0 ! -o docker0 -j ACCEPT" \
      "== FORWARD" \
      "-j DOCKER-USER" \
      "-j DOCKER-FORWARD" \
      "== INPUT" \
      "-i br-nix-builder -j RAVNIX-NIX-BUILDER-IN" \
      "-s 10.0.200.0/24 -j RAVNIX-NIX-BUILDER-IN" \
      "-j UG_INPUT" \
      "== OUTPUT" \
      "== RAVNIX-NIX-BUILDER-IN" \
      "-m conntrack --ctstate RELATED,ESTABLISHED -j RETURN" \
      "-j DROP" \
      "== RAVNIX-NIX-BUILDER-OUT" \
      "-m conntrack --ctstate RELATED,ESTABLISHED -j RETURN" \
      "-d 10.0.0.0/8 -j DROP" \
      "-d 172.16.0.0/12 -j DROP" \
      "-d 192.168.0.0/16 -j DROP" \
      "-d 100.64.0.0/10 -j DROP" \
      "== UG_FORWARD" \
      "== UG_INPUT")
    # is TABLE WHAT: the table holds the applied rule, else a failure naming WHAT.
    is_applied() {
      local got
      got=$(snapshot "$1")
      [ "$got" = "$applied" ] || fail "$2: the table is not as applied: $(diff <(echo "$applied") <(echo "$got") || true)"
    }

    # A first run, a rerun, --check.
    t=$(table)
    initial=$(snapshot "$t")
    fw "$t" --check >/dev/null 2>&1 && fail "--check passed on a table without the rule"
    [ "$(changes "$t")" = 0 ] || fail "--check changed the table: $(cat "$t/log")"
    got=$(fw "$t" --once) || fail "a first run failed: $got"
    [[ $got == *"put the rule for br-nix-builder and 10.0.200.0/24 in place"* ]] || fail "a first run said: $got"
    is_applied "$t" "a first run"
    : >"$t/log"
    got=$(fw "$t" --once) || fail "a rerun failed: $got"
    [[ $got == *"the rule for br-nix-builder and 10.0.200.0/24 is in place"* ]] || fail "a rerun said: $got"
    [ "$(changes "$t")" = 0 ] || fail "a rerun changed the table: $(cat "$t/log")"
    fw "$t" --check >/dev/null || fail "--check failed on a table with the rule"
    [ "$(changes "$t")" = 0 ] || fail "--check changed the table: $(cat "$t/log")"

    # What a NAS does to the chains.
    repair() { # what code
      local t
      t=$(table)
      fw "$t" --once >/dev/null
      (cd "$t/chains" && eval "$2")
      fw "$t" --check >/dev/null 2>&1 && fail "$1: --check passed"
      fw "$t" --once >/dev/null || fail "$1: the repair failed"
      is_applied "$t" "$1"
    }
    repair "the jump no longer first" 'sed -i "1{h;d};\$G" DOCKER-USER'
    repair "the jump twice" 'echo "-s 10.0.200.0/24 -j RAVNIX-NIX-BUILDER-IN" >>INPUT'
    repair "the interface jump twice" 'echo "-i br-nix-builder -j RAVNIX-NIX-BUILDER-OUT" >>DOCKER-USER'
    repair "the interface jump gone" 'sed -i "/-i br-nix-builder/d" INPUT'
    repair "the subnet jump gone" 'sed -i "/-s 10.0.200.0/d" DOCKER-USER'
    repair "the two jumps swapped" 'sed -i "1{h;d};2G" INPUT'
    repair "the subnet jump no longer second" 'sed -i "2{h;d};\$G" DOCKER-USER'
    repair "the jump twice, both first" 'sed -i "1p" INPUT'
    repair "the jump gone" 'sed -i 1d DOCKER-USER'
    repair "a rule of the chain gone" 'sed -i "/192.168/d" RAVNIX-NIX-BUILDER-OUT'
    repair "a rule added to the chain" 'sed -i "1i -j RETURN" RAVNIX-NIX-BUILDER-IN'
    repair "a rule of the chain changed" 'sed -i "s|10.0.0.0/8|10.0.0.0/9|" RAVNIX-NIX-BUILDER-OUT'
    repair "both chains and jumps gone" 'sed -i 1,2d DOCKER-USER INPUT && rm RAVNIX-NIX-BUILDER-OUT RAVNIX-NIX-BUILDER-IN'

    # The keeper repairs on its own and stops on TERM.
    t=$(table)
    # Started without fw, so that $! is the script itself.
    env -i PATH="$PATH" FAKE_IPT="$t" IPTABLES="$fake" NIX_BUILDER_SUBNET=10.0.200.0/24 NIX_BUILDER_BRIDGE=br-nix-builder \
      NIX_FIREWALL_INTERVAL=1 "$bash" "$script" >"$TMPDIR/keeper.log" 2>&1 &
    keeper=$!
    settled() { # table: --check passes within ten seconds
      local i
      for i in $(seq 50); do
        fw "$1" --check >/dev/null 2>&1 && return 0
        sleep 0.2
      done
      return 1
    }
    settled "$t" || fail "the keeper did not put the rule in place: $(cat "$TMPDIR/keeper.log")"
    sed -i 1d "$t/chains/INPUT"
    settled "$t" || fail "the keeper did not repair the jump: $(cat "$TMPDIR/keeper.log")"
    is_applied "$t" "the keeper"
    # TERM between a repair and its log line would end the keeper before it
    # says so, so wait for the line.
    logged() { # line: the keeper's log has LINE within ten seconds
      local i
      for i in $(seq 50); do
        grep -qxF -- "$1" "$TMPDIR/keeper.log" && return 0
        sleep 0.2
      done
      return 1
    }
    logged "firewall.sh: put the rule for br-nix-builder and 10.0.200.0/24 back in place" ||
      fail "the keeper did not log its repair: $(cat "$TMPDIR/keeper.log")"
    kill -TERM "$keeper"
    rc=0
    timeout 10 tail --pid="$keeper" -f /dev/null || rc=$?
    [ "$rc" = 0 ] || fail "the keeper did not stop on TERM"
    rc=0
    wait "$keeper" || rc=$?
    [ "$rc" = 0 ] || fail "the keeper exited $rc on TERM"
    want=$(printf '%s\n' "firewall.sh: keeping the rule for br-nix-builder and 10.0.200.0/24, checked every 1s" \
      "firewall.sh: put the rule for br-nix-builder and 10.0.200.0/24 in place" \
      "firewall.sh: put the rule for br-nix-builder and 10.0.200.0/24 back in place")
    [ "$(cat "$TMPDIR/keeper.log")" = "$want" ] ||
      fail "the keeper's log: wanted $want, got $(cat "$TMPDIR/keeper.log")"

    # A keeper that starts on a table with the rule (a restart) changes
    # nothing and says so.
    t=$(table)
    fw "$t" --once >/dev/null
    : >"$t/log"
    env -i PATH="$PATH" FAKE_IPT="$t" IPTABLES="$fake" NIX_BUILDER_SUBNET=10.0.200.0/24 NIX_BUILDER_BRIDGE=br-nix-builder \
      NIX_FIREWALL_INTERVAL=1 "$bash" "$script" >"$TMPDIR/keeper.log" 2>&1 &
    keeper=$!
    logged "firewall.sh: the rule for br-nix-builder and 10.0.200.0/24 is in place" ||
      fail "the restarted keeper did not log the rule: $(cat "$TMPDIR/keeper.log")"
    # Two more passes, which change nothing either and log nothing.
    for i in $(seq 50); do
      [ "$(grep -c '^-S DOCKER-USER' "$t/log")" -ge 3 ] && break
      sleep 0.2
    done
    kill -TERM "$keeper"
    wait "$keeper" || fail "the keeper on a table with the rule exited $?"
    [ "$(changes "$t")" = 0 ] || fail "a keeper on a table with the rule changed it: $(cat "$t/log")"
    want=$(printf '%s\n' "firewall.sh: keeping the rule for br-nix-builder and 10.0.200.0/24, checked every 1s" \
      "firewall.sh: the rule for br-nix-builder and 10.0.200.0/24 is in place")
    [ "$(cat "$TMPDIR/keeper.log")" = "$want" ] ||
      fail "the restarted keeper's log: wanted $want, got $(cat "$TMPDIR/keeper.log")"

    # Two runs at once, then one pass.
    t=$(table)
    fw "$t" --once >/dev/null 2>&1 &
    fw "$t" --once >/dev/null 2>&1 &
    wait
    fw "$t" --once >/dev/null || fail "the pass after two runs at once failed"
    is_applied "$t" "two runs at once and one pass"

    # --remove.
    t=$(table)
    fw "$t" --once >/dev/null
    got=$(fw "$t" --remove) || fail "--remove failed: $got"
    [ "$(snapshot "$t")" = "$initial" ] || fail "--remove left: $(diff <(echo "$initial") <(snapshot "$t") || true)"
    fw "$t" --remove >/dev/null || fail "a second --remove failed"
    [ "$(snapshot "$t")" = "$initial" ] || fail "a second --remove changed the table"
    t=$(table)
    fw "$t" --once >/dev/null
    sed -i 1d "$t/chains/INPUT"
    fw "$t" --remove >/dev/null || fail "--remove of a chain without its jump failed"
    [ "$(snapshot "$t")" = "$initial" ] || fail "--remove of a chain without its jump left: $(snapshot "$t")"

    # Refused before any iptables call.
    refuse() { # text, with subnet/interval set by the caller
      local t got rc=0
      t=$(table)
      got=$(fw "$t" --once 2>&1) || rc=$?
      if [ "$rc" != 1 ] || [[ $got != *"$1"* ]]; then
        fail "subnet '$subnet', interval '$interval', bridge '$bridge': wanted exit 1 and \"$1\", got exit $rc: $got"
      fi
      [ ! -s "$t/log" ] || fail "subnet '$subnet', interval '$interval', bridge '$bridge': iptables was called: $(cat "$t/log")"
    }
    for subnet in "" 10.0.200.0 10.0.200/24 10.0.256.0/24 10.0.200.0/33 10.0.200.0/7 10.0.200.0/31 \
      fd00::/64 " 10.0.200.0/24" "10.0.200.0/24 -j ACCEPT" $'10.0.200.0/24\n-j ACCEPT' 10.0.200.0/24/8; do
      refuse "NIX_BUILDER_SUBNET"
    done
    subnet=010.0.200.0/24 refuse "leading zero"
    subnet=10.0.200.0/024 refuse "NIX_BUILDER_SUBNET"
    subnet=10.0.200.5/24 refuse "host bits"
    subnet=10.0.201.0/23 refuse "host bits"
    subnet=10.0.200.0/24
    for interval in 0 abc -1 1.5 " 5" 3601 99999999999999999999; do
      refuse "NIX_FIREWALL_INTERVAL"
    done
    interval=
    for bridge in "" -oops "br nix" br/nix "br-nix-builder;x" br-nix-builder-0 $'br\nnix' .hidden; do
      refuse "NIX_BUILDER_BRIDGE"
    done
    unset bridge

    for subnet in 10.0.0.0/8 192.168.254.0/24 172.20.0.0/16; do
      t=$(table)
      fw "$t" --once >/dev/null || fail "the subnet $subnet was refused"
      grep -qxF -- "-s $subnet -j RAVNIX-NIX-BUILDER-OUT" "$t/chains/DOCKER-USER" || fail "no jump for $subnet"
    done
    unset subnet
    t=$(table)
    bridge=br-nix-builder1 fw "$t" --once >/dev/null || fail "a bridge name of 15 characters was refused"
    grep -qxF -- "-i br-nix-builder1 -j RAVNIX-NIX-BUILDER-IN" "$t/chains/INPUT" || fail "no jump for the bridge br-nix-builder1"

    t=$(table)
    got=$(fw "$t" --bogus 2>&1) && fail "an unknown argument passed"
    [[ $got == *"unknown argument '--bogus'"* ]] || fail "an unknown argument: $got"

    # Stopped with an error.
    t=$(table)
    rm "$t/chains/DOCKER-USER"
    sed -i 1d "$t/chains/FORWARD"
    before=$(snapshot "$t")
    got=$(fw "$t" --once 2>&1) && fail "a table without DOCKER-USER passed"
    [[ $got == *"there is no DOCKER-USER chain"* ]] || fail "no DOCKER-USER: $got"
    [ "$(snapshot "$t")" = "$before" ] || fail "a table without DOCKER-USER was changed"
    got=$(fw "$t" --check 2>&1) && fail "--check passed without DOCKER-USER"

    t=$(table)
    got=$(env -i PATH="$PATH" IPTABLES="$TMPDIR/no-such-iptables" NIX_BUILDER_SUBNET=10.0.200.0/24 NIX_BUILDER_BRIDGE=br-nix-builder \
      "$bash" "$script" --once 2>&1) && fail "a missing iptables passed"
    [[ $got == *"no-such-iptables is not installed"* ]] || fail "a missing iptables: $got"

    for broken in -A -I -N -S; do
      t=$(table)
      rc=0
      got=$(fw "$t" --once 2>&1) || rc=$?
      [ "$rc" != 0 ] || fail "--once passed while iptables $broken fails: $got"
      rc=0
      limit=(timeout 10)
      got=$(interval=1 fw "$t" 2>&1) || rc=$?
      limit=()
      if [ "$rc" = 0 ] || [ "$rc" = 124 ]; then
        fail "the keeper did not stop with an error while iptables $broken fails (exit $rc): $got"
      fi
    done
    unset broken

    [ "$failed" = 0 ]
    touch "$out"
  ''
