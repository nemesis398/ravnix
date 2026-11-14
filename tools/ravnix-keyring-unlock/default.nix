# ravnix-keyring-unlock: unlocks the login keyring of the running
# gnome-keyring daemon with the password of a systemd credential, after a
# login that gave PAM no password (README.md). It speaks D-Bus itself, over
# the session bus's socket, and needs nothing at run time but glibc.
{ buildOdinTool, ... }:
buildOdinTool {
  name = "ravnix-keyring-unlock";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  # The bench is the run of every login that has no credential set up: the
  # tool looks for the file, finds none, says so and exits 0, without a bus.
  # A run that unlocks needs a bus and a daemon, which the bench has not;
  # tests/desktop/keyring-autounlock.nix runs that one against the real
  # dbus-daemon and gnome-keyring-daemon.
  benchArgs = [
    "--credential"
    "no-credential-here"
    "--bus"
    "unix:path=/nonexistent/bus"
  ];
}
