# Loopback ports for tests/deploy/nix-builder-start.nix and
# nix-builder-firewall.nix, printed on one line: one that accepts a
# connect, one that refuses it, one that never answers, the way a port
# behind a dropping firewall rule looks, and one that switches. The silent
# one is a listener with a backlog of zero whose queue a first connection
# fills, so the kernel drops every further SYN. The switching one is silent
# until SIGUSR1 makes it refuse, the way a target that comes back looks, and
# SIGUSR2 makes it silent again. The accepting one takes every connection
# and closes it, so that its queue never fills and it never falls silent
# itself. Runs until it is killed.
import signal
import socket
import threading
import time


def bound(port=0):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    return s


def quiet(port=0):
    s = bound(port)
    s.listen(0)
    filler = socket.socket()
    filler.connect(s.getsockname())
    return s, filler


accepting = bound()
accepting.listen(16)


def serve():
    while True:
        connection, _ = accepting.accept()
        connection.close()


threading.Thread(target=serve, daemon=True).start()
refusing = bound()
silent = quiet()
switch = quiet()
switch_port = switch[0].getsockname()[1]


def refuse(*_):
    global switch
    if switch:
        for s in switch:
            s.close()
        switch = None


def hush(*_):
    global switch
    if not switch:
        switch = quiet(switch_port)


signal.signal(signal.SIGUSR1, refuse)
signal.signal(signal.SIGUSR2, hush)
print(
    accepting.getsockname()[1],
    refusing.getsockname()[1],
    silent[0].getsockname()[1],
    switch_port,
    flush=True,
)
while True:
    time.sleep(3600)
