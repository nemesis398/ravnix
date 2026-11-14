# The VM half of desktop-keyring-autounlock. tests/desktop/keyring-autounlock.nix
# puts USER, KEYRING_PASSWORD and SECRET in front of this file.
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
