# Run inside the interpreter of bwm, after the path set-up of its entry script
# (tests/desktop/bitwarden-menu-prompts.nix prepends it). Prints what it found and
# exits 1 on a problem. argv[1] is a scratch directory.
import os
import sys

scratch = sys.argv[1]
problems = []


def check(ok, what):
    if not ok:
        problems.append(what)


def conf(text):
    path = os.path.join(scratch, "config.ini")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    import bwm

    bwm.reload_config(path)
    return bwm


FUZZEL = "[dmenu]\ndmenu_command = fuzzel --dmenu\n"
bwm = conf(FUZZEL)
from bwm.menu import dmenu_cmd  # noqa: E402

# The secret prompts: hidden, and with their question.
for prompt in ("Password", "Verify password", "Enter Password", "client_secret"):
    cmd = dmenu_cmd(1, prompt)
    check("--password" in cmd, "%s: input is not hidden: %r" % (prompt, cmd))
    check("--prompt=%s " % prompt in cmd, "%s: no question: %r" % (prompt, cmd))
    check(cmd[:2] == ["fuzzel", "--dmenu"], "%s: the command was changed: %r" % (prompt, cmd))

# A caller that says so, whatever the text: bwm passes obscure=True for the
# 2FA code and the master password.
cmd = dmenu_cmd(0, "Enter 2FA Code", obscure=True)
check("--password" in cmd, "obscure=True is not hidden: %r" % (cmd,))
check("--lines=0" in cmd, "no line count for 0: %r" % (cmd,))

# The menus that only look like it: "Password Options" and "Password Length?"
# have to stay readable, and keep their question.
for prompt in ("Password Options", "Password Length?", "Entries", "Select Two Factor Auth type.", "Passwords"):
    cmd = dmenu_cmd(7, prompt)
    check("--password" not in cmd, "%s: input is hidden in a menu: %r" % (prompt, cmd))
    check("--prompt=%s " % prompt in cmd, "%s: no question: %r" % (prompt, cmd))
    check("--lines=7" in cmd, "%s: no line count: %r" % (prompt, cmd))
check(
    "--password" not in dmenu_cmd(1, "Password", obscure=False),
    "obscure=False still hides",
)

# A question is one argument, whatever it holds, and cannot be read as a flag.
for prompt in ("-evil", "two words", "--password", "a=b"):
    cmd = dmenu_cmd(1, prompt, obscure=False)
    check("--prompt=%s " % prompt in cmd, "question %r is not one argument: %r" % (prompt, cmd))
    check("--password" not in cmd, "question %r made a flag: %r" % (prompt, cmd))

# The line count is the caller's.
check("--lines=24" in dmenu_cmd(24, "Entries"), "no --lines=24")

# [dmenu_passphrase] obscure = False turns hiding off for fuzzel too.
conf(FUZZEL + "[dmenu_passphrase]\nobscure = False\n")
check("--password" not in dmenu_cmd(1, "Password"), "obscure = False in config.ini is ignored")

# What the command is for the real fuzzel check.
conf(FUZZEL)
with open(os.path.join(scratch, "password.argv"), "w", encoding="utf-8") as f:
    f.write("\n".join(dmenu_cmd(1, "Password")) + "\n")

# The menus bwm knew keep upstream's commands.
for name, want in {
    "dmenu": ["dmenu", "-p", "Entries", "-l", "3"],
    "bemenu": ["bemenu", "-p", "Entries", "-l", "3"],
    "rofi": ["rofi", "-dmenu", "-p", "Entries", "-l", "3"],
    "wofi": ["wofi", "--dmenu", "-p", "Entries", "-L", "4"],
}.items():
    conf("[dmenu]\ndmenu_command = %s\n" % name)
    got = dmenu_cmd(3, "Entries")
    check(got == want, "%s changed: %r, want %r" % (name, got, want))
conf("[dmenu]\ndmenu_command = rofi\n")
check(dmenu_cmd(1, "Password")[-1] == "-password", "rofi no longer hides a password")
conf("[dmenu]\ndmenu_command = something-else\n")
check(dmenu_cmd(3, "Entries") == ["something-else"], "an unknown menu got flags")

for p in problems:
    print("  " + p)
print("bwm prompts: %d problems" % len(problems))
sys.exit(1 if problems else 0)
