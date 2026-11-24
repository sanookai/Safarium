"""Private subprocess roles for test_queue.py. No media, network or real queue."""

import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import time


def event(log, kind, name):
    record = [kind, name, os.getpid(), os.getsid(0)]
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, (json.dumps(record) + "\n").encode())
    finally:
        os.close(fd)


def main(role, args):
    if role == "dispatch":
        # An explicit Python call into an unmodified copy of the production CLI.
        # There is deliberately no environment variable or CLI flag for this.
        api = runpy.run_path(args[0])
        api["exit_as"](api["main"](args[2:], home=args[1]))
    if role in ("hold", "resist"):
        log, name, release, code, *_ = args
        if role == "resist":
            for fd in map(int, os.listdir("/dev/fd")):
                if fd > 2:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
            signal.signal(signal.SIGTERM, lambda *_: event(log, "term", name))
        event(log, "start", name)
        limit = time.monotonic() + 20  # A failed test cannot leave an infinite worker.
        while not Path(release).exists():
            if time.monotonic() > limit:
                return 91
            time.sleep(0.02)
        time.sleep(0.04)
        event(log, "end", name)
        return int(code)
    if role == "echo":
        print(json.dumps([args, os.getcwd(), sorted(os.environ.items()),
                          sys.stdin.buffer.read().hex()], ensure_ascii=True))
        os.write(2, b"fixture stderr\x00\xff\n")
        return 37
    if role == "nested-session":
        return subprocess.run(args, env={"PATH": "/usr/bin:/bin"},
                              start_new_session=True, timeout=4).returncode
    if role == "signal-self":
        os.kill(os.getpid(), int(args[0]))
        return 92
    if role == "ignore-chld-exec":
        signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        os.execv(args[0], args)
    if role == "exit":
        return int(args[0])
    if role == "other-group":
        log, release = args
        child = os.fork()
        if child:
            event(log, "waiting", "wrapper")
            os.waitpid(child, 0)  # A synchronous launcher on its normal path.
            return 0
        os.setpgid(0, 0)  # Different group, SAME POSIX session; no daemon/setsid.
        return main("hold", [log, "other-group", release, "0"])
    if role == "family":
        log, = args
        parent = os.getpid()
        peer = os.fork()
        name = "leader" if os.getpid() == parent else "member"
        stopped = []

        def mark(sig, _frame):
            event(log, signal.Signals(sig).name, name)
            if sig == signal.SIGTERM:
                stopped.append(True)

        signal.signal(signal.SIGTERM, mark)
        signal.signal(signal.SIGUSR1, mark)
        event(log, "ready", name)
        deadline = time.monotonic() + 10
        while not stopped and time.monotonic() < deadline:
            time.sleep(0.01)
        if peer:
            os.waitpid(peer, 0)
        return 23 if stopped else 93
    raise AssertionError(role)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2:]))
