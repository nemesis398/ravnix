#!/usr/bin/env bash
# The checks of tests/workbench/server.nix that a container can show, through
# docker exec, in the container of a running muninn. It is the script that
# tests/workbench/oci.md records. The Docker host needs nothing but Docker and
# bash, so the script is piped to it:
#
#   ssh HOST 'bash -s -- CONTAINER ODIN HOST_PORT [podman]' < docker-checks.sh
#
# CONTAINER  the container's name (docker ps)
# ODIN       the store path of the odin the tools are built with, which
#            `nix eval --raw .#packages.x86_64-linux.odin` or lib/odin.nix
#            names; the test compares what a pane resolves to
# HOST_PORT  the host port that sshd is published on
# podman     also run containers with rootless Podman inside: the default
#            network, a published port and a network of their own (the image
#            localhost/hello:latest, with hello and busybox in /bin, must be
#            on stdin of `docker exec -i CONTAINER su - USER -c 'podman load'`
#            first; this script loads nothing)
#
# Every check prints PASS or FAIL, and the last line counts them. The exit
# status is the number of failures, capped at 100; 2 when it refused to run.
# The user is alice, the template's.
#
# It adds a key to the keys sshd takes for the user and one to the user's
# ~/.ssh/authorized_keys, and makes a pane, a workspace and a unit run, so it
# refuses to run in a container that is not the one of a throwaway Compose
# project named ravnix-muninn-test, whatever else is asked. The keys and the
# files it made are removed at the end.
set -u

container=${1:?usage: docker-checks.sh CONTAINER ODIN HOST_PORT [podman]}
odin=${2:?}
port=${3:?}
mode=${4:-}
user=alice
project=ravnix-muninn-test
passed=0
failed=0
sysbin=/run/current-system/sw/bin
# The bound of each probe that waits on a peer over the network (seconds): a
# peer that takes the connection and never answers fails the check and does
# not stop the run. The name probe gets three times this, for its container.
probe=${RAVNIX_PROBE_TIMEOUT:-10}

# Refuse to run anywhere but in the throwaway project's container.
label=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$container" 2>/dev/null)
if [ "$label" != "$project" ]; then
	echo "docker-checks.sh: $container is not a container of the Compose project $project (its label says '$label'); it adds keys and files, and runs only in the throwaway one" >&2
	exit 2
fi

ok() {
	echo "PASS: $*"
	passed=$((passed + 1))
}
bad() {
	echo "FAIL: $*"
	failed=$((failed + 1))
}
# A command as root in the container.
r() { docker exec "$container" "$@"; }
# A command as the user, in a login shell with a runtime directory, the way
# the VM test's as_user does it.
u() { docker exec "$container" su - "$user" -c "export TERM=xterm-256color XDG_RUNTIME_DIR=/run/user/1000; $1"; }
# Waits up to $1 times 5 seconds for the command in $2 to succeed.
wait_for() {
	local i
	for ((i = 0; i < $1; i++)); do
		if eval "$2" >/dev/null 2>&1; then return 0; fi
		sleep 5
	done
	return 1
}

# A container that was just made runs the entrypoint and stage 2 first: until
# the system is activated, nothing is on the PATH of docker exec, and until
# systemd has moved itself into /init.scope, PID 1 is in the namespace's root.
# So the checks wait for the system, as long as a slow first boot takes.
echo "== the system is up"
state=""
for _ in $(seq 1 40); do
	state=$(r $sysbin/systemctl is-system-running 2>/dev/null)
	case "$state" in running | degraded) break ;; esac
	sleep 5
done
echo "info: systemctl is-system-running: $state"

echo "== PID 1 and cgroups"
exe=$(r readlink /proc/1/exe)
case "$exe" in
/nix/store/*-systemd-*/lib/systemd/systemd) ok "PID 1 is $exe" ;;
*) bad "PID 1 is $exe" ;;
esac
cg=$(r cat /proc/1/cgroup)
if [ "$cg" = "0::/init.scope" ]; then ok "PID 1 is in $cg, in the container's own cgroup namespace"; else bad "PID 1 is in $cg"; fi
opts=$(r $sysbin/findmnt -no OPTIONS /sys/fs/cgroup)
echo "info: /sys/fs/cgroup mount options: $opts"
case ",$opts," in
*,rw,*) ok "/sys/fs/cgroup is writable inside the container" ;;
*) bad "/sys/fs/cgroup is not writable: $opts" ;;
esac
failed_units=$(r $sysbin/systemctl --failed --no-legend --no-pager | sed 's/^[^a-z]*//' | awk '{print $1}' | tr '\n' ' ')
echo "info: failed units: ${failed_units:-none}"
if [ "$state" = running ]; then ok "the system is running, with no failed unit"; else bad "the system is $state (failed: $failed_units)"; fi

echo "== the Nix database of the image"
# With an empty database every store path counts as invalid, and a garbage
# collection through the daemon deletes invalid paths.
result=$(r $sysbin/systemctl show -p Result --value register-nix-paths.service)
if [ "$result" = success ]; then ok "register-nix-paths.service ran: Result=$result"; else bad "register-nix-paths.service: Result=$result"; fi
if r $sysbin/nix-store -q --hash /run/current-system >/dev/null 2>&1; then ok "the Nix database knows /run/current-system"; else bad "the Nix database does not know /run/current-system"; fi

echo "== the user's manager and herdr's server"
if wait_for 30 "[ \"\$(docker exec $container $sysbin/systemctl is-active user@1000.service)\" = active ]"; then
	ok "user@1000.service (lingering, nobody logged in) is active"
else
	bad "user@1000.service is not active"
fi
wait_for 30 "docker exec $container su - $user -c 'XDG_RUNTIME_DIR=/run/user/1000 herdr status server'"
status=$(u 'herdr status server --json' 2>&1)
echo "info: herdr status server --json: $status"
case "$status" in
*'"running":true'*'"compatible":true'*) ok "herdr's server runs and answers (running, compatible)" ;;
*) bad "herdr status: $status" ;;
esac
if u 'herdr config check' >/dev/null 2>&1; then ok "herdr config check accepts the module's configuration"; else bad "herdr config check failed"; fi
if [ "$(u 'systemctl --user is-active herdr-server.service')" = active ]; then ok "herdr-server.service is an active user unit"; else bad "herdr-server.service is not active"; fi

echo "== Claude Code's Remote Control is enabled, and waits for a login"
# The check of server.nix: the unit is enabled, and with no login and no
# repository yet it is skipped (inactive, ConditionResult=no) and not
# restarted every half minute behind an "active" that is not.
if [ "$(u 'systemctl --user is-enabled claude-remote-control.service')" = enabled ]; then ok "claude-remote-control.service is enabled"; else bad "claude-remote-control.service is not enabled"; fi
u 'systemctl --user start claude-remote-control.service' >/dev/null 2>&1
if [ "$(u 'systemctl --user is-active claude-remote-control.service')" = inactive ]; then ok "claude-remote-control.service is inactive with no login"; else bad "claude-remote-control.service is $(u 'systemctl --user is-active claude-remote-control.service')"; fi
if [ "$(u 'systemctl --user show -p ConditionResult --value claude-remote-control.service')" = no ]; then ok "claude-remote-control.service was skipped by its condition (ConditionResult=no)"; else bad "claude-remote-control.service's condition did not skip it"; fi
if [ "$(u 'systemctl --user show -p MainPID --value claude-remote-control.service')" = 0 ]; then ok "no Claude Code process was started for Remote Control"; else bad "claude-remote-control.service has a main process"; fi

echo "== a pane of the server"
made=$(u "herdr workspace create --cwd /home/$user" 2>&1)
pane=$(printf '%s' "$made" | grep -o '"pane_id":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "info: pane $pane"
u 'rm -f ~/pane.out'
u "herdr pane run $pane '{ echo shell=\$(readlink -f /proc/\$\$/exe); type -P lazygit rg claude odin; } > /home/$user/pane.out'" >/dev/null 2>&1
wait_for 24 "docker exec $container su - $user -c 'test -s ~/pane.out && grep -q odin ~/pane.out'"
out=$(u 'cat ~/pane.out' 2>&1)
while IFS= read -r line; do echo "info:   $line"; done <<<"$out"
if echo "$out" | grep -Eq '^shell=/nix/store/[a-z0-9]+-bash-interactive-[^/]+/bin/bash$'; then ok "a pane is bash from the store"; else bad "pane shell: $out"; fi
for tool in lazygit rg claude odin; do
	if echo "$out" | grep -q "/bin/$tool"; then ok "$tool is on a pane's PATH"; else bad "$tool is not on a pane's PATH"; fi
done

echo "== the terminal programs on the PATH"
for command in "aerc -v" "iamb --version" "khal --version" "vdirsyncer --version" "podman --version" "uv --version" "node --version" "cargo --version" "rustc --version" "cc --version" "odin version" "lazygit --version" "herdr --version"; do
	line=$(u "$command" 2>&1 | head -1)
	if [ -n "$line" ]; then ok "$command: $line"; else bad "$command printed nothing"; fi
done
# The command substitution is the container's to expand.
# shellcheck disable=SC2016
resolved=$(u 'readlink -f $(command -v odin)')
case "$resolved" in
"$odin"/*) ok "there is one Odin, the one the tools are built with ($resolved)" ;;
*) bad "odin is $resolved, not under $odin" ;;
esac

echo "== sshd"
if [ "$(r $sysbin/systemctl is-active sshd.service)" = active ]; then ok "sshd.service is active"; else bad "sshd.service is not active"; fi
effective=$(r $sysbin/sshd -T | tr '[:upper:]' '[:lower:]')
for want in "passwordauthentication no" "kbdinteractiveauthentication no" "permitrootlogin no" "hostkey /home/.muninn-ssh/ssh_host_ed25519_key"; do
	if echo "$effective" | grep -qx "$want"; then ok "sshd -T: $want"; else bad "sshd -T lacks: $want"; fi
done
echo "info: $(r ls -la /home/.muninn-ssh | tr '\n' ';')"
echo "info: host key: $(r $sysbin/ssh-keygen -lf /home/.muninn-ssh/ssh_host_ed25519_key.pub 2>&1)"
# sshd takes keys from the configuration alone (hosts/server/deploy.nix): it
# reads the file the system writes from users.users.USER.openssh.authorizedKeys
# at every boot, and never ~/.ssh/authorized_keys. The private half of a key
# of the configuration is nobody's here, so the test logs in with a key of its
# own that it puts, as root, into that file; but only into the file the
# system made, root's and mode 444 with the configuration's key in it, so
# that the login also shows that the configuration's keys reach sshd in the
# container. (tee -a would make the file if it were missing.) The line is the
# template's ravnix.serverAccess.publicKey as modules/glue/terminal.nix gives
# it; workbench-oci holds it to the image's configuration. A key in the home
# must be refused, and that counts only when the key is in the home. Both
# keys end in the comment the cleanup looks for.
keys=/etc/ssh/authorized_keys.d/$user
configured='restrict,port-forwarding,pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey ravnix-server@example.org'
u 'rm -f ~/.ssh/id_test ~/.ssh/id_test.pub ~/.ssh/id_home ~/.ssh/id_home.pub; mkdir -p ~/.ssh; chmod 700 ~/.ssh; ssh-keygen -q -t ed25519 -N "" -C ravnix-docker-checks -f ~/.ssh/id_test; ssh-keygen -q -t ed25519 -N "" -C ravnix-docker-checks -f ~/.ssh/id_home; cat ~/.ssh/id_home.pub >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys' >/dev/null 2>&1
meta=$(r $sysbin/stat -c '%F %U %a' "$keys" 2>&1)
times=$(r $sysbin/cat "$keys" 2>/dev/null | grep -cxF "$configured")
if [ "$meta" = "regular file root 444" ] && [ "$times" -ge 1 ]; then
	ok "$keys is root's, mode 444, and holds the configuration's key"
	u 'cat ~/.ssh/id_test.pub' | docker exec -i "$container" $sysbin/tee -a "$keys" >/dev/null
	login=$(u "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o IdentitiesOnly=yes -i ~/.ssh/id_test $user@127.0.0.1 'echo login-ok:\$(id -un)'" 2>&1)
	if echo "$login" | grep -q "login-ok:$user"; then ok "ssh with a key of $keys logs in as the user"; else bad "ssh login with a key of $keys: $login"; fi
else
	bad "$keys is not the configuration's ($meta; the configuration's key in it $times times): no key put into it, no login tried"
fi
homekey=$(u 'cut -d" " -f2 ~/.ssh/id_home.pub' 2>/dev/null)
if [ -n "$homekey" ] && u 'cat ~/.ssh/authorized_keys' 2>/dev/null | grep -qF " $homekey " && u 'test -s ~/.ssh/id_home'; then
	home=$(u "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o IdentitiesOnly=yes -i ~/.ssh/id_home $user@127.0.0.1 'echo login-ok:\$(id -un)'" 2>&1)
	if echo "$home" | grep -q 'Permission denied (publickey)'; then ok "a key in ~/.ssh/authorized_keys is refused: sshd takes the configuration's keys only"; else bad "ssh with a key in ~/.ssh/authorized_keys: $home"; fi
else
	bad "the key for ~/.ssh/authorized_keys was not made or not added; its refusal shows nothing"
fi
nokey=$(u "ssh -o BatchMode=yes -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new $user@127.0.0.1 true" 2>&1)
if echo "$nokey" | grep -q 'Permission denied'; then ok "ssh without a key is refused: $(echo "$nokey" | tail -1)"; else bad "ssh without a key: $nokey"; fi
# One line, the banner: head ends after it and writes it on the way out (a
# head that the bound ends would lose what it had buffered).
banner=$(timeout "$probe" bash -c "exec 3<>/dev/tcp/127.0.0.1/$port && head -n 1 <&3" 2>&1 | head -1)
if echo "$banner" | grep -q '^SSH-2.0-OpenSSH'; then ok "the published port answers from the host: $banner"; else bad "the published port gives: $banner"; fi

echo "== the sync units, with the vault locked"
for unit in nextcloud-sync vdirsyncer; do
	u "systemctl --user start $unit.service" >/dev/null 2>&1
	code=$(u "systemctl --user show -p ExecMainStatus --value $unit.service")
	result=$(u "systemctl --user show -p Result --value $unit.service")
	if [ "$code" = 75 ]; then ok "$unit.service exited with status 75 ($result), the locked vault"; else bad "$unit.service: status $code, result $result"; fi
done

echo "== no program of the laptop"
# The laptop's programs of workbench-oci, and Helium: the server carries one,
# but only as the browser of the DevTools MCP wrapper, by its store path.
laptop=$(r ls $sysbin | grep -E '^(sway|swaylock|swayidle|waybar|fuzzel|dunst|kanshi|greetd|tuigreet|obsidian|ghostty|onlyoffice-desktopeditors|steam|helium)$' | tr '\n' ' ')
if [ -z "$laptop" ]; then ok "none of the laptop's programs is in the system path"; else bad "laptop programs on the PATH: $laptop"; fi

echo "== rootless Podman"
rootless=$(u "podman info --format '{{.Host.Security.Rootless}}'" 2>&1 | tail -1)
if [ "$rootless" = true ]; then ok "podman info: Rootless true"; else bad "podman info: Rootless $rootless"; fi
if [ "$mode" = podman ]; then
	hello=$(u 'podman run --rm localhost/hello:latest' 2>&1 | tail -3)
	if echo "$hello" | grep -q 'Hello, world!'; then ok "a rootless container ran: Hello, world!"; else bad "podman run: $hello"; fi
	if [ "$(u 'stat -c %U ~/.local/share/containers/storage')" = "$user" ]; then ok "Podman's storage belongs to the user"; else bad "Podman's storage is not the user's"; fi
	# What a dev container needs: a published port (-p), and a network of its
	# own on which containers find each other by name, as a compose stack
	# makes it. The server is busybox's httpd in the hello image.
	u 'podman rm -f -i ravnix-checks-web ravnix-checks-srv; podman network rm -f ravnix-checks-net' >/dev/null 2>&1
	serve='/bin/busybox sh -c "mkdir -p /w && echo ravnix-checks-ok >/w/index.html && exec /bin/busybox httpd -f -p 8080 -h /w"'
	started=$(u "podman run -d --name ravnix-checks-web -p 127.0.0.1:18080:8080 localhost/hello:latest $serve" 2>&1 | tail -2)
	published=""
	for _ in $(seq 1 12); do
		published=$(u "timeout $probe bash -c 'exec 3<>/dev/tcp/127.0.0.1/18080 && printf \"GET / HTTP/1.0\\r\\n\\r\\n\" >&3 && cat <&3'" 2>&1)
		case "$published" in *ravnix-checks-ok*) break ;; esac
		sleep 5
	done
	if echo "$published" | grep -q ravnix-checks-ok; then ok "a published port of a rootless container (-p 127.0.0.1:18080:8080) answers in muninn"; else bad "podman run -p: $started $(echo "$published" | tail -1)"; fi
	u 'podman network create ravnix-checks-net' >/dev/null 2>&1
	started=$(u "podman run -d --name ravnix-checks-srv --network ravnix-checks-net localhost/hello:latest $serve" 2>&1 | tail -2)
	byname=""
	for _ in $(seq 1 12); do
		byname=$(u "timeout $((probe * 3)) podman run --rm --network ravnix-checks-net localhost/hello:latest /bin/busybox wget -T $probe -q -O - http://ravnix-checks-srv:8080/" 2>&1)
		case "$byname" in *ravnix-checks-ok*) break ;; esac
		sleep 5
	done
	if echo "$byname" | grep -q ravnix-checks-ok; then ok "on a network of its own (podman network), a container reaches another by name"; else bad "podman network: $started $(echo "$byname" | tail -2 | tr '\n' ' ')"; fi
	u 'podman rm -f -i ravnix-checks-web ravnix-checks-srv; podman network rm -f ravnix-checks-net' >/dev/null 2>&1
else
	hello=$(u 'podman run --rm --network host localhost/hello:latest' 2>&1 | tail -2)
	echo "info: podman run without the Podman override: $hello"
fi

# What the checks added: the keys and the files of the ssh check.
r $sysbin/sed -i '/ ravnix-docker-checks$/d' "$keys" >/dev/null 2>&1
u 'rm -f ~/.ssh/id_test ~/.ssh/id_test.pub ~/.ssh/id_home ~/.ssh/id_home.pub ~/pane.out; sed -i "/ ravnix-docker-checks\$/d" ~/.ssh/authorized_keys' >/dev/null 2>&1

echo "SUMMARY: $passed passed, $failed failed"
exit $((failed > 100 ? 100 : failed))
