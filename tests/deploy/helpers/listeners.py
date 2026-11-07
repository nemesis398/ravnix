# Three loopback ports for tests/deploy/nix-builder-start.nix, printed on one
# line: one that accepts a connect, one that refuses it, and one that never
# answers, the way a port behind a dropping firewall rule looks. The last is
# a listener with a backlog of zero whose queue a first connection fills, so
# the kernel drops every further SYN. Runs until it is killed.
import socket
import time


def bound():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    return s


accepting = bound()
accepting.listen(16)
refusing = bound()
silent = bound()
silent.listen(0)
filler = socket.socket()
filler.connect(silent.getsockname())
print(
    accepting.getsockname()[1],
    refusing.getsockname()[1],
    silent.getsockname()[1],
    flush=True,
)
while True:
    time.sleep(3600)
