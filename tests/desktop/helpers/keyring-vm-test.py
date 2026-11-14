# The VM half of desktop-keyring-autounlock. tests/desktop/keyring-autounlock.nix
# puts USER, KEYRING_PASSWORD, SECRET, ITEM, NEW_PASSWORD and LOGIN_PASSWORD
# in front of this file.
#
# greetd's initial_session logs the user in without any authentication, so
# PAM's auth stack never sees a password: pam_gnome_keyring starts the
# daemon for the session with the keyring locked, as after a YubiKey tap.
# Each login is one start of greetd (it runs initial_session once per start).
import shlex

UID = 1000
RUN = f"/run/user/{UID}"
LOGIN = "/org/freedesktop/secrets/collection/login"


def as_user(command, check=True):
    """Run a command as the user, in the environment of the session."""
    env = f"XDG_RUNTIME_DIR={RUN} DBUS_SESSION_BUS_ADDRESS=unix:path={RUN}/bus"
    full = f"su - {USER} -c {shlex.quote(env + ' ' + command)}"
    return machine.succeed(full) if check else machine.execute(full)


def diagnose(what):
    print(f"--- {what}: the processes ---")
    print(machine.execute("ps -eo pid,user,args --width 220 | grep -v ' \\[' | head -90")[1])
    print(f"--- {what}: the journal ---")
    print(machine.execute("journalctl -b --no-pager -o cat | tail -150")[1])


def wait_for(description, condition, timeout=120):
    try:
        with machine.nested(f"waiting for {description}"):
            retry(lambda _: condition(), timeout)
    except Exception:
        diagnose(description)
        raise


def locked():
    return as_user(
        f"busctl --user get-property org.freedesktop.secrets {LOGIN} org.freedesktop.Secret.Collection Locked"
    ).strip()


def cursor():
    out = machine.succeed("journalctl -n0 --show-cursor --no-pager")
    return out.strip().split("cursor: ", 1)[1]


# What the service manager itself says, in the unit's cgroup before the
# tool runs, when the credential is not in the credstore. It is systemd's
# line, not the tool's, and it comes only with a missing credential.
SYSTEMD_NO_CREDENTIAL = "ravnix-keyring-unlock.service: Couldn't read inherited credential 'ravnix-keyring-login', skipping: No such file or directory"


def tool_lines(since, missing=False):
    """What the tool printed since the cursor: the lines from the unit's
    cgroup, without systemd's note about a missing credential, which must be
    there exactly when missing is set."""
    out = machine.succeed(
        f"journalctl --after-cursor={shlex.quote(since)} --no-pager -o cat "
        f"_SYSTEMD_USER_UNIT=ravnix-keyring-unlock.service _UID={UID} || true"
    )
    lines = [l for l in out.splitlines() if l.strip()]
    notes = [l for l in lines if l == SYSTEMD_NO_CREDENTIAL]
    assert len(notes) == (1 if missing else 0), f"systemd's credential note: {lines}"
    return [l for l in lines if l != SYSTEMD_NO_CREDENTIAL]


def setup(password):
    """The setup command of the option's description, as the user types it
    in a terminal: script(1) gives systemd-ask-password a terminal, whose
    input is the password and a return."""
    command = (
        "mkdir -p -m 0700 ~/.config/credstore.encrypted && "
        "systemd-ask-password -n 'Login keyring password:' | "
        "systemd-creds --user encrypt --name=ravnix-keyring-login - "
        "~/.config/credstore.encrypted/ravnix-keyring-login"
    )
    machine.succeed(
        f"printf '%s\\n' {shlex.quote(password)} | su - {USER} -c {shlex.quote('script -qec ' + shlex.quote(command) + ' /dev/null')}"
    )


def login():
    """Log in through greetd's initial session, without a password, and
    wait until the session's keyring step has run and Helium is up."""
    machine.succeed("rm -f /run/greetd.run")
    machine.systemctl("restart greetd")
    wait_for("Sway", lambda: machine.execute(f"pgrep -u {USER} -x sway")[0] == 0)
    wait_for(
        "ravnix-keyring.target",
        lambda: as_user("systemctl --user is-active ravnix-keyring.target", check=False)[0] == 0,
    )
    wait_for("Helium", lambda: machine.execute(f"pgrep -u {USER} -f '/share/helium/helium'")[0] == 0)


def logout():
    """End the session and everything of the user, so that the next login
    starts a new user manager and a new gnome-keyring daemon."""
    machine.succeed(f"loginctl terminate-user {USER}")
    wait_for("the session to end", lambda: machine.execute(f"pgrep -u {USER} -x sway")[0] != 0)
    wait_for(
        "the user manager to stop",
        lambda: machine.execute(f"systemctl is-active user@{UID}.service")[0] != 0,
        60,
    )


start_all()
machine.wait_for_unit("multi-user.target")

# ── the setup, before the first login ─────────────────────────────────────────
# The keyring as PAM makes it at a password login: login.keyring, encrypted
# with KEYRING_PASSWORD, holding Helium's cookie key. Made in a private bus,
# with a runtime directory of its own, before any session exists.
machine.succeed(
    f"su - {USER} -c "
    + shlex.quote(
        "export XDG_RUNTIME_DIR=$(mktemp -d); "
        "dbus-run-session -- sh -ec '"
        'printf %s "$0" | gnome-keyring-daemon --unlock --foreground --components=secrets >/dev/null 2>&1 & '
        "d=$!; for i in $(seq 100); do busctl --user status org.freedesktop.secrets >/dev/null 2>&1 && break; sleep 0.1; done; "
        'printf %s "$1" | secret-tool store --collection=login --label="Chromium Safe Storage" application chromium; '
        "kill $d; wait $d || true"
        f"' {shlex.quote(KEYRING_PASSWORD)} {shlex.quote(SECRET)}"
    )
)
machine.succeed(f"head -c 16 /home/{USER}/.local/share/keyrings/login.keyring | grep -qa '^GnomeKeyring'")

print(machine.execute("systemd-analyze has-tpm2")[1])
machine.succeed("systemd-analyze has-tpm2")
setup(KEYRING_PASSWORD)
cred = f"/home/{USER}/.config/credstore.encrypted/ravnix-keyring-login"
machine.succeed(f"test -s {cred}")
machine.fail(f"grep -qF {shlex.quote(KEYRING_PASSWORD)} {cred}")
machine.succeed(f"test $(stat -c %U {cred}) = {USER}")
# Bound to the TPM2: the same password encrypted for the user with the host
# key alone is a few hundred bytes smaller than the setup's credential, which
# also holds the TPM2's sealed key.
machine.succeed(
    f"printf %s {shlex.quote(KEYRING_PASSWORD)} | systemd-creds encrypt --uid={USER} --with-key=host "
    "--name=ravnix-keyring-login - /tmp/host-only"
)
size = lambda f: int(machine.succeed(f"base64 -d < {f} | wc -c").strip())
ours, host_only = size(cred), size("/tmp/host-only")
print(f"credential: {ours} bytes; with the host key alone: {host_only} bytes")
assert ours > host_only + 200, f"the credential holds no TPM2 key ({ours} vs {host_only} bytes)"

# ── a login without a password unlocks the keyring ────────────────────────────
since = cursor()
login()
wait_for("the keyring to report unlocked", lambda: locked() == "b false", 30)
lines = tool_lines(since)
assert lines == ["ravnix-keyring-unlock: unlocked the login keyring"], f"the tool said: {lines}"

# Helium's cookie key comes back without a prompt.
got = as_user("timeout 10 secret-tool lookup application chromium </dev/null").strip()
assert got == SECRET, "the cookie key did not come back"
machine.fail("pgrep -f gcr-prompter")

# The Secret Service is the daemon PAM started for the session, not a second one.
pid = as_user(
    "busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus "
    "GetConnectionUnixProcessID s org.freedesktop.secrets"
).split()[1]
cmdline = machine.succeed(f"tr '\\0' ' ' < /proc/{pid}/cmdline")
assert "--login" in cmdline, f"the Secret Service is {cmdline}"

# The unlock ran before the login layout started Helium: Helium's oldest
# process started after the target became active (both on the monotonic
# clock since boot; /proc counts in ticks of 10 ms).
active_us = int(as_user("systemctl --user show -P ActiveEnterTimestampMonotonic ravnix-keyring.target").strip())
helium = machine.succeed(f"pgrep -o -u {USER} -f '/share/helium/helium'").strip()
start_ticks = int(machine.succeed(f"cut -d' ' -f22 /proc/{helium}/stat").strip())
ticks = 100  # USER_HZ, which /proc/PID/stat counts in, is 100 on x86-64
start_us = start_ticks * 1_000_000 // ticks
assert start_us + 1_000_000 // ticks >= active_us, f"Helium started at {start_us} us, the target at {active_us} us"

# The service is not active any more, so the decrypted password has gone
# with its credentials directory; nothing under the runtime dir holds it.
assert as_user("systemctl --user is-active ravnix-keyring-unlock.service", check=False)[1].strip() == "inactive"
machine.fail(f"grep -rsqF -- {shlex.quote(KEYRING_PASSWORD)} {RUN}")
# The session's units start in an order systemd can keep.
cycles = machine.execute("journalctl -b --no-pager | grep -i 'ordering cycle'")[1]
assert cycles == "", f"an ordering cycle: {cycles}"
machine.fail(f"journalctl -b --no-pager | grep -qF -- {shlex.quote(KEYRING_PASSWORD)}")
logout()

# ── no credential: the keyring stays locked, one line ─────────────────────────
machine.succeed(f"mv {cred} {cred}.kept")
since = cursor()
login()
lines = tool_lines(since, missing=True)
assert len(lines) == 1 and "no credential ravnix-keyring-login" in lines[0], f"the tool said: {lines}"
assert locked() == "b true", "without a credential the keyring did not stay locked"
logout()

# ── a wrong password: the keyring stays locked, one line ──────────────────────
setup("not the keyring's password")
since = cursor()
login()
lines = tool_lines(since)
assert len(lines) == 1 and "does not unlock the login keyring" in lines[0], f"the tool said: {lines}"
assert locked() == "b true", "with a wrong password the keyring did not stay locked"
failed = as_user("systemctl --user --failed --no-legend", check=False)[1]
assert "ravnix-keyring" not in failed, f"a unit failed: {failed}"
machine.fail(f"journalctl -b --no-pager | grep -qF -- {shlex.quote(KEYRING_PASSWORD)}")

# ── the one command: ravnix-keyring-unlock setup ──────────────────────────────
# In the session that is still open, with the keyring locked and a wrong
# credential in place: the setup from the user's PATH, which knows the item
# of rbwItem (ITEM), reads its password from a stand-in for rbw, which
# prints /run/fake-rbw/item, checks it against the login password with the
# real unix_chkpwd, asks for the keyring's current one (KEYRING_PASSWORD)
# with the real systemd-ask-password in a terminal of script(1), and stores
# the credential with the real systemd-creds.
FAKE_RBW = f"""#!/bin/sh
case "$1" in
unlocked) exit 0 ;;
get) [ "$2" = -- ] && [ "$3" = {shlex.quote(ITEM)} ] || exit 1; cat /run/fake-rbw/item; echo ;;
*) exit 2 ;;
esac
"""
machine.succeed(
    f"mkdir -p /run/fake-rbw && printf %s {shlex.quote(FAKE_RBW)} > /run/fake-rbw/rbw && chmod 755 /run/fake-rbw/rbw"
)


def run_setup(typed):
    """The setup as typed in a terminal of the session; typed is what is
    typed at the prompt, once it is there, or None for nothing at all. The
    tool's lines go to a file: the terminal itself is not looked at."""
    env = f"XDG_RUNTIME_DIR={RUN} DBUS_SESSION_BUS_ADDRESS=unix:path={RUN}/bus PATH=/run/fake-rbw:$PATH"
    inner = f"{env} ravnix-keyring-unlock setup >/tmp/setup.out 2>&1"
    command = f"su - {USER} -c {shlex.quote('script -qec ' + shlex.quote(inner) + ' /dev/null')}"
    if typed is None:
        status, _ = machine.execute(f"{command} </dev/null")
    else:
        # The input waits for the prompt, so that it does not reach the
        # terminal before systemd-ask-password has turned the echo off.
        feed = (
            "for i in $(seq 300); do pgrep -u "
            + USER
            + " -f 'systemd-ask-password -n' >/dev/null && break; sleep 0.2; done; sleep 1; "
            + f"printf '%s\\n' {shlex.quote(typed)}"
        )
        status, _ = machine.execute(f"({feed}) | {command}")
    out = machine.succeed("cat /tmp/setup.out")
    print(f"setup said: {out}")
    for password in (KEYRING_PASSWORD, NEW_PASSWORD, LOGIN_PASSWORD):
        assert password not in out, "the setup printed a password"
    return status, out


def decrypted():
    return as_user(
        f"systemd-creds --user decrypt --name=ravnix-keyring-login {shlex.quote(cred)} -"
    )


def offline_unlock(password):
    """After the logout, a daemon of its own on the keyring file, locked as
    after a tap, and the unlock with a credential that holds password: the
    tool's line."""
    return machine.succeed(
        f"su - {USER} -c "
        + shlex.quote(
            "export XDG_RUNTIME_DIR=$(mktemp -d); "
            "dbus-run-session -- sh -c '"
            "gnome-keyring-daemon --foreground --components=secrets >/dev/null 2>&1 & "
            "d=$!; for i in $(seq 100); do busctl --user status org.freedesktop.secrets >/dev/null 2>&1 && break; sleep 0.1; done; "
            'printf %s "$0" > "$XDG_RUNTIME_DIR/c"; '
            'ravnix-keyring-unlock --credential "$XDG_RUNTIME_DIR/c" 2>&1; '
            "kill $d; wait $d || true"
            f"' {shlex.quote(password)}"
        )
    ).strip()


def item(password):
    machine.succeed(f"printf %s {shlex.quote(password)} > /run/fake-rbw/item")


machine.succeed(f"su - {USER} -c 'command -v ravnix-keyring-unlock'")

# The item holds the login password: refused before anything changes,
# without a question (nothing is typed), the wrong credential left as it is.
item(LOGIN_PASSWORD)
before = machine.succeed(f"sha256sum {cred}")
status, out = run_setup(None)
assert status == 1, f"the setup with the login password did not fail: {out}"
last = out.strip().splitlines()[-1]
assert "holds your login password" in last and "nothing changed" in last, f"the setup said: {out}"
assert machine.succeed(f"sha256sum {cred}") == before, "the credential changed"
assert locked() == "b true", "the refused setup unlocked the keyring"
for password in (KEYRING_PASSWORD, NEW_PASSWORD, LOGIN_PASSWORD):
    machine.fail(f"journalctl -b --no-pager | grep -qF -- {shlex.quote(password)}")

item(NEW_PASSWORD)
status, out = run_setup(KEYRING_PASSWORD)
assert status == 0, f"the setup failed: {out}"
last = out.strip().splitlines()[-1]
assert "is now the one of" in last and ITEM in last, f"the setup said: {out}"
# It opened the keyring for this session, the daemon PAM started.
assert locked() == "b false", "the setup left the keyring locked"
assert decrypted() == NEW_PASSWORD, "the credential does not hold the item's password"
machine.succeed(f"test $(stat -c %a {cred}) = 600")
machine.succeed(f"test $(stat -c %a $(dirname {cred})) = 700")
machine.fail(f"grep -qF {shlex.quote(NEW_PASSWORD)} {cred}")
# The check of the item against the login password is one failed password
# check in the journal, which locks nothing: the login password still works.
print(machine.execute("journalctl -b --no-pager | grep -i 'password check failed'")[1])
machine.succeed(
    f"printf '%s\\0' {shlex.quote(LOGIN_PASSWORD)} | su - {USER} -c '/run/wrappers/bin/unix_chkpwd {USER} nonull'"
)
for password in (KEYRING_PASSWORD, NEW_PASSWORD):
    machine.fail(f"journalctl -b --no-pager | grep -qF -- {shlex.quote(password)}")
logout()

# The keyring opens with the item's password, and no longer with the old one.
line = offline_unlock(KEYRING_PASSWORD)
assert "does not unlock the login keyring" in line, f"the old password: {line}"
line = offline_unlock(NEW_PASSWORD)
assert "unlocked the login keyring" in line, f"the item's password: {line}"

# The next login without a password is unlocked by the service, with the
# credential the setup made.
since = cursor()
login()
wait_for("the keyring to report unlocked after the setup", lambda: locked() == "b false", 30)
lines = tool_lines(since)
assert lines == ["ravnix-keyring-unlock: unlocked the login keyring"], f"the tool said: {lines}"
got = as_user("timeout 10 secret-tool lookup application chromium </dev/null").strip()
assert got == SECRET, "the cookie key did not come back after the setup"

# Run again, the keyring already has the item's password: nothing is asked
# (nothing is typed, so a prompt would fail it), the credential is written
# again.
status, out = run_setup(None)
assert status == 0, f"the setup again failed: {out}"
assert "already has the password" in out.strip().splitlines()[-1], f"the setup again said: {out}"
assert decrypted() == NEW_PASSWORD, "the credential written again does not hold the item's password"
