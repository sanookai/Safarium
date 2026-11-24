"""macOS acceptance: /usr/bin/python3 -ISB Tests/queue/test_queue.py [--scratch DIR] -v"""

import ctypes
import fcntl
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[2] / "bin" / "safarium-render"
FIXTURE = Path(__file__).resolve().with_name("fixture.py")
PY = [sys.executable, "-ISB"]
SCRATCH = None
IDLE = {"active": None, "waiting": []}


def fixture(*args):
    return [*PY, str(FIXTURE), *map(str, args)]


def wait_for(predicate, description, timeout=8):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = predicate()
        if result:
            return result
        time.sleep(0.03)
    raise AssertionError("timed out: " + description)


def write_executable(path, source):
    path.write_text(source)
    path.chmod(0o755)


@unittest.skipUnless(sys.platform == "darwin", "uses macOS process and kqueue APIs")
class QueueTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="queue-test-", dir=SCRATCH)
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.home = self.root / "system-home"
        self.prefix = self.root / "install"
        self.bin = self.prefix / "bin" / "safarium-render"
        self.libexec = self.prefix / "libexec" / "safarium"
        self.log = self.root / "events"
        self.release = self.root / "release"
        self.dirs = [self.root / "work one", self.root / "งานที่สอง"]
        self.poison = self.root / "untrusted-bin"
        for d in (self.home, self.bin.parent, self.libexec, self.poison, *self.dirs):
            d.mkdir(parents=True, mode=0o700)
        shutil.copyfile(SOURCE, self.bin)
        self.bin.chmod(0o755)
        self.state = self.home / runpy.run_path(str(self.bin))["STATE"]
        self.jobs = []
        self.addCleanup(self.cleanup_jobs)

    def cleanup_jobs(self):
        self.release.touch()
        for p in self.jobs:
            if p.poll() is None:
                p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait(timeout=3)
            for stream in (p.stdout, p.stderr):
                if stream:
                    stream.close()

    def env(self, n=0):
        cwd = str(self.dirs[n % 2])
        return {**os.environ, "HOME": cwd, "TMPDIR": cwd, "XDG_STATE_HOME": cwd,
                "PATH": str(self.poison) + os.pathsep + os.defpath,
                "QUEUE_TEST_PROFILE": str(n), "QUEUE_TEST_LOG": str(self.log),
                "SAFARIUM_RENDER_ACTIVE": "forged", "SAFARIUM_QUEUE_DIR": cwd}

    def cli(self, *args):
        return fixture("dispatch", self.bin, self.home, *args)

    def start(self, *args, n=0):
        p = subprocess.Popen(self.cli(*args), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, cwd=self.dirs[n % 2], env=self.env(n))
        self.jobs.append(p)
        return p

    def call(self, *args, n=0, data=None):
        return subprocess.run(self.cli(*args), input=data, capture_output=True, timeout=6,
                              cwd=self.dirs[n % 2], env=self.env(n))

    def status(self, n=0):
        x = self.call("status", n=n)
        self.assertEqual(x.returncode, 0, x.stderr)
        self.assertEqual(x.stderr, b"")
        return json.loads(x.stdout)

    def records(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def events(self):
        return [(e[0], e[1]) for e in self.records()]

    def hold(self, name, n=0, code=0, resist=False):
        return self.start("run", "--", *fixture("resist" if resist else "hold", self.log,
                                                name, self.release, code, "private-argv-test-marker"), n=n)

    def has_started(self, name):
        wait_for(lambda: ("start", name) in self.events(), name + " started")

    def await_status(self, active, waiting):
        expected = {"active": active, "waiting": waiting}
        wait_for(lambda: self.status(1) == expected, repr(expected))

    def completed(self, p, rc):
        out, err = p.communicate(timeout=8)
        self.assertEqual(p.returncode, rc, (out, err))
        return out, err

    def test_fifo_across_processes_cwds_profiles_and_failure(self):
        first = self.hold("one", code=19)
        self.has_started("one")
        order = ["one", "two", "three", "four", "five"]
        waiters = []
        proc = ctypes.CDLL("/usr/lib/libproc.dylib")
        for n, name in enumerate(order[1:], 1):
            p = self.hold(name, n=n)
            waiters.append(p)
            self.await_status(1, list(range(2, n + 2)))
            buf = (ctypes.c_int * 32)()
            self.assertEqual(proc.proc_listchildpids(p.pid, buf, ctypes.sizeof(buf)), 0)
        self.assertEqual(self.events(), [("start", "one")])
        for path in self.state.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertNotIn(b"private-argv-test-marker", path.read_bytes())
            self.assertNotIn("private-argv-test-marker", path.name)
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o700)
        self.assertNotIn(b"private-argv-test-marker", self.call("status").stdout)
        self.release.touch()
        self.completed(first, 19)
        for p in waiters:
            self.completed(p, 0)
        self.assertEqual(self.events(), [(event, name) for name in order for event in ("start", "end")])
        self.assertEqual(self.status(), IDLE)

    def test_waiting_interrupt_and_sigkill_never_launch(self):
        first = self.hold("first")
        self.has_started("first")
        cancel = self.hold("cancel", n=1)
        self.await_status(1, [2])
        die = self.hold("die")
        self.await_status(1, [2, 3])
        last = self.hold("last", n=1)
        self.await_status(1, [2, 3, 4])
        cancel.send_signal(signal.SIGINT)
        self.completed(cancel, -signal.SIGINT)
        die.kill()
        self.completed(die, -signal.SIGKILL)
        self.await_status(1, [4])
        self.release.touch()
        self.completed(first, 0)
        self.completed(last, 0)
        self.assertEqual(self.events(), [("start", "first"), ("end", "first"),
                                         ("start", "last"), ("end", "last")])

    def test_argv_cwd_env_binary_streams_match_direct_execution(self):
        args = ["", "a b", "🌼 ภาษาไทย", "$(touch SHOULD_NOT_EXIST)", "$HOME", "*", "--", ";", "'\"\\", "\n"]
        argv = fixture("echo", *args)
        data = b"\0stdin\r\n\xff"
        direct = subprocess.run(argv, cwd=self.dirs[1], env=self.env(1), input=data, capture_output=True)
        through = self.call("run", "--", *argv, n=1, data=data)
        self.assertEqual(through.returncode, 37, through.stderr)
        self.assertEqual((through.stdout, through.stderr), (direct.stdout, direct.stderr))
        self.assertFalse((self.dirs[1] / "SHOULD_NOT_EXIST").exists())

    def test_active_signals_reach_whole_group_and_caught_exit_is_preserved(self):
        p = self.start("run", "--", *fixture("family", self.log))
        names = ("leader", "member")
        wait_for(lambda: all(("ready", name) in self.events() for name in names), "both processes ready")
        p.send_signal(signal.SIGUSR1)
        wait_for(lambda: all(("SIGUSR1", name) in self.events() for name in names), "group received USR1")
        p.terminate()
        self.completed(p, 23)
        self.assertTrue(all(("SIGTERM", name) in self.events() for name in names))
        self.assertEqual(self.status(), IDLE)

    def test_sigkill_of_outer_closing_fds_cannot_release_live_child(self):
        first = self.hold("live", resist=True)
        self.has_started("live")
        _, _, worker, supervisor = self.records()[0]
        last = self.hold("next", n=1)
        self.await_status(1, [2])
        first.kill()
        self.assertEqual(first.wait(timeout=2), -signal.SIGKILL)
        wait_for(lambda: ("term", "live") in self.events(), "guardian noticed outer SIGKILL")
        os.kill(worker, 0)  # Still genuinely alive after the outer process is dead.
        self.await_status(1, [2])
        self.assertNotIn(("start", "next"), self.events())
        self.release.touch()
        self.completed(last, 0)
        self.assertEqual(self.events(), [("start", "live"), ("term", "live"), ("end", "live"),
                                         ("start", "next"), ("end", "next")])
        self.assertEqual(self.status(), IDLE)

        def guardian_gone():
            try:
                os.kill(supervisor, 0)
            except ProcessLookupError:
                return True
            return False

        wait_for(guardian_gone, "no guardian left behind")

    def test_unresponsive_active_child_escalates(self):
        p = self.hold("ignore", resist=True)
        self.has_started("ignore")
        p.terminate()
        self.completed(p, -signal.SIGKILL)
        self.assertIn(("term", "ignore"), self.events())
        self.assertEqual(self.status(), IDLE)

    def kill_test_guardian(self, outer, worker, sid):
        # Never signal from an on-disk marker. Check our controlled fixture's
        # actual ancestry and private kernel session before fault injection.
        lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        info = (ctypes.c_uint32 * 16)()
        self.assertEqual(os.getsid(worker), sid)
        self.assertEqual(os.getsid(sid), sid)
        self.assertEqual(lib.proc_pidinfo(sid, 13, ctypes.c_uint64(0), info,
                                         ctypes.sizeof(info)), ctypes.sizeof(info))
        self.assertEqual((info[0], info[1]), (sid, outer.pid))
        os.kill(sid, signal.SIGKILL)

    def test_guardian_loss_surviving_outer_stays_until_worker_finishes(self):
        outer = self.hold("worker", resist=True)
        self.has_started("worker")
        _, _, worker, sid = self.records()[0]
        self.kill_test_guardian(outer, worker, sid)
        following = self.hold("following", n=1)
        self.await_status(1, [2])
        self.assertIsNone(outer.poll())
        self.assertEqual(self.events(), [("start", "worker")])
        self.release.touch()
        self.completed(outer, -signal.SIGKILL)
        self.completed(following, 0)
        self.assertEqual(self.events(), [(e, name) for name in ("worker", "following")
                                         for e in ("start", "end")])

    def test_both_guardian_and_outer_lost_recovery_without_any_existing_waiter(self):
        outer = self.hold("survivor", resist=True)
        self.has_started("survivor")
        _, _, worker, sid = self.records()[0]
        self.kill_test_guardian(outer, worker, sid)
        outer.kill()
        self.assertEqual(outer.wait(timeout=2), -signal.SIGKILL)
        active = self.state / ("t-1-active-%d" % sid)

        def all_lease_holders_gone():
            with active.open("rb") as fd:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return False
            return True

        wait_for(all_lease_holders_gone, "ticket has no remaining lease owner")
        self.assertRegex(active.read_bytes(), rb"^v2 [0-9a-f-]{36} [0-9]+\n$")
        os.kill(worker, 0)
        self.assertEqual(self.status(), {"active": 1, "waiting": []})
        following = self.hold("following", n=1)
        self.await_status(1, [2])
        self.assertEqual(self.events(), [("start", "survivor")])
        self.release.touch()
        self.completed(following, 0)
        self.assertEqual(self.events(), [(e, name) for name in ("survivor", "following")
                                         for e in ("start", "end")])
        self.assertEqual(self.status(), IDLE)

    def test_cancel_synchronous_wrapper_waits_for_other_process_group(self):
        outer = self.start("run", "--", *fixture("other-group", self.log, self.release))
        self.has_started("other-group")
        records = {r[1]: r for r in self.records()}
        _, _, wrapper, sid = records["wrapper"]
        _, _, helper, helper_sid = records["other-group"]
        self.assertEqual(sid, helper_sid)
        self.assertNotEqual(os.getpgid(wrapper), os.getpgid(helper))
        outer.terminate()

        def direct_gone():
            try:
                os.getpgid(wrapper)
            except ProcessLookupError:
                return True
            return False

        wait_for(direct_gone, "direct foreground command exited")
        following = self.hold("following", n=1)
        self.await_status(1, [2])
        self.assertIsNone(outer.poll())
        os.kill(helper, 0)
        self.assertNotIn(("start", "following"), self.events())
        self.release.touch()
        self.completed(outer, -signal.SIGTERM)
        self.completed(following, 0)
        self.assertLess(self.events().index(("end", "other-group")), self.events().index(("start", "following")))

    def test_first_new_registrant_recovers_when_only_other_group_survives(self):
        outer = self.start("run", "--", *fixture("other-group", self.log, self.release))
        self.has_started("other-group")
        _, _, helper, sid = next(r for r in self.records() if r[1] == "other-group")
        outer.terminate()

        def guardian_gone():
            try:
                os.getsid(sid)
            except ProcessLookupError:
                return True
            return False

        wait_for(guardian_gone, "guardian and its direct worker gone")
        outer.kill()  # The helper in another group is now the sole job-session member.
        self.assertEqual(outer.wait(timeout=2), -signal.SIGKILL)
        self.assertEqual(os.getsid(helper), sid)
        following = self.hold("following", n=1)  # Intentionally no intervening status.
        self.await_status(1, [2])
        self.assertNotIn(("start", "following"), self.events())
        self.release.touch()
        self.completed(following, 0)
        self.assertLess(self.events().index(("end", "other-group")), self.events().index(("start", "following")))
        self.assertEqual(self.status(), IDLE)

    def test_nested_same_thread_and_new_session_fail_promptly(self):
        inside = self.cli("run", "--", *fixture("exit", "0"))
        for cmd in [inside, fixture("nested-session", *inside)]:
            with self.subTest(cmd=cmd[3]):
                result = self.call("run", "--", *cmd)
                self.assertEqual(result.returncode, os.EX_USAGE, result.stderr)
                self.assertIn(b"nested", result.stderr)
                self.assertEqual(self.status(), IDLE)

    def test_stale_waiting_and_active_tickets_even_with_live_unrelated_pid(self):
        self.assertEqual(self.status(), IDLE)
        original_lock = (self.state / "queue.lock").stat().st_ino
        for name in ["t-11", "t-12-active-2147483647"]:
            (self.state / name).touch(mode=0o600)
        sentinel = subprocess.Popen(fixture("hold", self.log, "unrelated", self.release, 0),
                                    env=self.env(), cwd=self.dirs[0], start_new_session=True)
        self.jobs.append(sentinel)
        self.has_started("unrelated")
        api = runpy.run_path(str(self.bin))
        boot = api["boot_uuid"]()
        birth = api["birth_id"](ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True), sentinel.pid)
        old_boot = (b"1" if boot[:1] == b"0" else b"0") + boot[1:]
        for ticket, witness in [(13, (old_boot, birth)), (14, (boot, birth + 1))]:
            path = self.state / ("t-%d-active-%d" % (ticket, sentinel.pid))
            path.touch(mode=0o600)
            path.write_bytes(b"v2 %s %d\n" % witness)
        self.assertEqual(self.call("run", "--", *fixture("exit", 0)).returncode, 0)
        self.assertEqual(self.status(), IDLE)
        self.assertEqual([p.name for p in self.state.iterdir()], ["queue.lock"])
        self.assertEqual((self.state / "queue.lock").stat().st_ino, original_lock)
        self.assertIsNone(sentinel.poll())
        self.release.touch()
        self.assertEqual(sentinel.wait(timeout=3), 0)

    def test_uncertifiable_active_record_fails_closed(self):
        self.assertEqual(self.status(), IDLE)
        path = self.state / "t-3-active-12345"
        path.touch(mode=0o600)
        path.write_bytes(b"v2 truncated")
        for argv in (["status"], ["run", "--", *fixture("hold", self.log, "never", self.release, 0)]):
            result = self.call(*argv)
            self.assertEqual(result.returncode, os.EX_TEMPFAIL, result.stderr)
            self.assertIn(b"slot retained", result.stderr)
            self.assertTrue(path.exists())
        self.assertFalse(self.log.exists())
        # A real record plus a denied kernel membership query is also not idle.
        api = runpy.run_path(str(self.bin))
        path.write_bytes(b"v2 %s 1\n" % api["boot_uuid"]())
        path = path.rename(self.state / "t-3-active-2147483647")
        messages = []
        with mock.patch("os.getsid", side_effect=PermissionError), \
                mock.patch.dict(api["main"].__globals__, {"complain": messages.append}):
            self.assertEqual(api["main"](["status"], home=self.home), os.EX_TEMPFAIL)
        self.assertIn("slot retained", messages[0])
        self.assertTrue(path.exists())
        with self.subTest("xpc_teardown_race_recovery"):
            with mock.patch.dict(api["session_busy"].__globals__, {
                "session_member": mock.Mock(side_effect=[False, None, None, False]),
                "birth_fence": mock.Mock(side_effect=[10, 11, 12, 13, 14, 15]),
                "birth_id": mock.Mock(return_value=1),
                "time": mock.Mock(),
            }):
                self.assertFalse(api["session_busy"](2147483647, path.read_bytes()))
            with mock.patch.dict(api["session_busy"].__globals__, {
                "session_member": mock.Mock(return_value=None),
                "birth_fence": mock.Mock(side_effect=range(100, 140)),
                "birth_id": mock.Mock(return_value=1),
                "time": mock.Mock(),
            }):
                with self.assertRaises(api["Refusal"]) as ctx:
                    api["session_busy"](2147483647, path.read_bytes())
                self.assertEqual(ctx.exception.code, os.EX_TEMPFAIL)

    def test_unsafe_state_rejected_without_following_or_clobbering_links(self):
        self.state.mkdir(mode=0o700)
        gate = self.state / "queue.lock"
        victim = self.root / "untouched"
        victim.write_bytes(b"sentinel")
        victim.chmod(0o600)
        gate.symlink_to(victim)
        self.assertNotEqual(self.call("status").returncode, 0)
        self.assertTrue(gate.is_symlink())
        gate.unlink()
        os.link(victim, gate)
        self.assertNotEqual(self.call("status").returncode, 0)
        gate.unlink()
        (self.state / "t-7").symlink_to(victim)
        self.assertNotEqual(self.call("status").returncode, 0)
        self.assertTrue((self.state / "t-7").is_symlink())
        self.assertEqual(victim.read_bytes(), b"sentinel")
        self.state.chmod(0o755)
        self.assertNotEqual(self.call("status").returncode, 0)
        self.state.rename(self.root / "original-state")
        self.state.symlink_to(self.root / "original-state", target_is_directory=True)
        self.assertNotEqual(self.call("status").returncode, 0)

    def test_html_and_verify_only_trusted_siblings_through_same_slot(self):
        bad = "#!/bin/sh\nexit 99\n"
        for name in ("safarium-html", "safarium-verify", "safarium-soundtrack", "safarium-hf"):
            write_executable(self.poison / name, bad)
            write_executable(self.bin.parent / name, bad)
        for mode in ("html", "verify"):
            missing = self.call(mode, "--help")
            self.assertEqual(missing.returncode, os.EX_UNAVAILABLE, missing.stderr)
            self.assertIn(("safarium-" + mode).encode(), missing.stderr)
            path = self.libexec / ("safarium-" + mode)
            path.symlink_to(self.poison / path.name)
            self.assertEqual(self.call(mode).returncode, os.EX_UNAVAILABLE)
            path.unlink()
            write_executable(path, """#!/usr/bin/python3 -ISB
import json, os, sys
name = os.path.basename(__file__)
with open(os.environ["QUEUE_TEST_LOG"], "a") as f:
    print(json.dumps(["native", name, os.getpid(), os.getsid(0)]), file=f)
print(json.dumps([name, sys.argv[1:]]))
""")
        first = self.hold("run")
        self.has_started("run")
        html = self.start("html", "--help", n=1)
        self.await_status(1, [2])
        args = ["ref one.mp4", "งาน ; $HOME.mp4"]
        verify = self.start("verify", *args)
        self.await_status(1, [2, 3])
        self.assertEqual(self.events(), [("start", "run")])
        self.release.touch()
        self.completed(first, 0)
        self.assertEqual(json.loads(self.completed(html, 0)[0]), ["safarium-html", ["--help"]])
        self.assertEqual(json.loads(self.completed(verify, 0)[0]), ["safarium-verify", args])
        self.assertEqual(self.events(), [("start", "run"), ("end", "run"),
                                         ("native", "safarium-html"), ("native", "safarium-verify")])
        self.assertEqual(json.loads(self.call("verify", args[0]).stdout), ["safarium-verify", args[:1]])

    def test_native_release_pinned_at_submission_across_atomic_switch(self):
        other = self.root / "second-release"
        shutil.copytree(self.prefix, other)
        for release, prefix in [("R1", self.prefix), ("R2", other)]:
            for mode in ("html", "verify"):
                write_executable(prefix / "libexec" / "safarium" / ("safarium-" + mode),
                                 "#!/bin/sh\necho " + release + "-" + mode + "\n")
        current = self.root / "current"
        current.symlink_to(self.prefix, target_is_directory=True)
        self.bin = current / "bin" / "safarium-render"
        first = self.hold("blocking")
        self.has_started("blocking")
        html = self.start("html", "--help")
        self.await_status(1, [2])
        verify = self.start("verify", "fixture.mp4", n=1)
        self.await_status(1, [2, 3])
        replacement = self.root / "switch"
        replacement.symlink_to(other, target_is_directory=True)
        os.replace(replacement, current)
        latest = self.start("html", "--help", n=1)
        self.await_status(1, [2, 3, 4])
        self.release.touch()
        self.completed(first, 0)
        for p, expected in [(html, b"R1-html\n"), (verify, b"R1-verify\n"), (latest, b"R2-html\n")]:
            self.assertEqual(self.completed(p, 0)[0], expected)
        self.assertEqual(self.status(), IDLE)

    def test_direct_and_path_resolved_denials_no_shell_fallback_and_exit_codes(self):
        def stub(program, script):
            path = (self.dirs[0] if "/" in program else self.poison) / program
            path.parent.mkdir(parents=True, exist_ok=True)
            write_executable(path, "#!/bin/sh\n" + script)

        blocked = ("FFmpeg", "ffprobe", "ffplay", "avconv", "avprobe", "ffmpeg7", "ffmpeg-7.1", "ffprobe8",
                   "relative/chromium", "google-chrome-stable", "Chrome.app/Contents/MacOS/helper",
                   "chrome-headless-shell", "Safari", "Safari Technology Preview", "SafariTechnologyPreview",
                   "safaridriver", "Safari.app/Contents/MacOS/Safari", "Safari.app/Contents/MacOS/helper",
                   "Safari Technology Preview.app/Contents/MacOS/helper")
        # Even a broken guard can reach only inert scratch stubs, including via PATH.
        for program in blocked:
            stub(program, 'echo unexpected-launch >> "$QUEUE_TEST_LOG"\nexit 99\n')
        (self.poison / "innocent-alias").symlink_to(self.poison / "ffprobe")
        (self.poison / "preview-alias").symlink_to(self.dirs[0] / blocked[-1])
        stub("env", 'echo unexpected-env-launch >> "$QUEUE_TEST_LOG"\nexit 99\n')
        for program in (*blocked, "innocent-alias", "preview-alias"):
            with self.subTest(program=program):
                x = self.call("run", "--", program)
                self.assertEqual(x.returncode, 126, x.stderr)
                self.assertIn(b"refused", x.stderr)
        for wrapped in (["env", "FOO=1", "ffmpeg"], ["env", "-i", "ffmpeg7"], ["/usr/bin/env", "ffprobe"]):
            with self.subTest(wrapped=wrapped):
                x = self.call("run", "--", *wrapped)
                self.assertEqual(x.returncode, 126, x.stderr)
                self.assertIn(b"refused", x.stderr)
        self.assertFalse(self.log.exists(), "a refused fixture was launched")
        for program in ("WebKit", "Safarium.app/Contents/MacOS/Safarium", "safari-report",
                        "safari/my-script", "Safari Tools.app/Contents/MacOS/helper"):
            with self.subTest(allowed=program):
                stub(program, "exit 27\n")
                self.assertEqual(self.call("run", "--", program).returncode, 27)
        write_executable(self.poison / "no-shebang", "exit 98\n")
        self.assertEqual(self.call("run", "--", "no-shebang").returncode, 126)
        self.assertEqual(self.call("run", "--", "missing-queue-test-command").returncode, 127)
        self.assertEqual(self.call("run", "--", *fixture("signal-self", int(signal.SIGTERM))).returncode,
                         -signal.SIGTERM)
        self.assertEqual(self.call("run", "--", *fixture("exit", 143)).returncode, 143)
        ignored = subprocess.run(fixture("ignore-chld-exec", *self.cli("run", "--", *fixture("exit", 29))),
                                 capture_output=True, cwd=self.dirs[0], env=self.env(), timeout=6)
        self.assertEqual(ignored.returncode, 29, ignored.stderr)

    def test_help_cli_shape_and_default_home_ignores_profiles(self):
        help_text = subprocess.run([str(self.bin), "--help"], cwd=self.dirs[1], env=self.env(1),
                                   check=True, capture_output=True).stdout
        for word in (b"run --", b"verify", b"html", b"FIFO", b"single-worker"):
            self.assertIn(word, help_text)
        for args in ([], ["run"], ["run", "echo"], ["run", "--"], ["status", "--other"]):
            self.assertEqual(self.call(*args).returncode, os.EX_USAGE)
        api = runpy.run_path(str(self.bin))
        with mock.patch.dict(os.environ, self.env(1)), mock.patch("pwd.getpwuid") as lookup:
            lookup.return_value.pw_dir = str(self.home)
            self.assertEqual(api["account_home"](), str(self.home))
            lookup.assert_called_once_with(os.getuid())

    def test_media_modes_pin_safarium_media_through_same_slot(self):
        modes = ("extract-audio", "mix-audio", "extract-frames", "gif", "cutout", "hybrid", "mux", "probe", "qa", "splice", "warm-worker")
        missing = self.call("extract-audio", "--help")
        self.assertEqual(missing.returncode, os.EX_UNAVAILABLE, missing.stderr)
        self.assertIn(b"safarium-media", missing.stderr)
        media_bin = self.libexec / "safarium-media"
        media_bin.symlink_to(self.poison / "safarium-media")
        self.assertEqual(self.call("gif", "--help").returncode, os.EX_UNAVAILABLE)
        media_bin.unlink()
        write_executable(media_bin, """#!/usr/bin/python3 -ISB
import json, os, sys
name = os.path.basename(__file__)
with open(os.environ["QUEUE_TEST_LOG"], "a") as f:
    print(json.dumps(["native", name, sys.argv[1], os.getpid(), os.getsid(0)]), file=f)
print(json.dumps([name, sys.argv[1:]]))
""")
        first = self.hold("run")
        self.has_started("run")
        procs = []
        for i, m in enumerate(modes, start=2):
            p = self.start(m, "--help", n=i - 1)
            procs.append((m, p))
            self.await_status(1, list(range(2, i + 1)))
        self.assertEqual(self.events(), [("start", "run")])
        self.release.touch()
        self.completed(first, 0)
        for m, p in procs:
            out = json.loads(self.completed(p, 0)[0])
            self.assertEqual(out, ["safarium-media", [m, "--help"]])
        self.assertEqual(self.status(), IDLE)

    def test_forge_pins_safarium_forge_through_same_slot(self):
        missing = self.call("forge", "--help")
        self.assertEqual(missing.returncode, os.EX_UNAVAILABLE, missing.stderr)
        self.assertIn(b"safarium-forge", missing.stderr)
        forge_bin = self.libexec / "safarium-forge"
        forge_bin.symlink_to(self.poison / "safarium-forge")
        self.assertEqual(self.call("forge", "capabilities").returncode, os.EX_UNAVAILABLE)
        forge_bin.unlink()
        write_executable(forge_bin, """#!/usr/bin/python3 -ISB
import json, os, sys
name = os.path.basename(__file__)
with open(os.environ["QUEUE_TEST_LOG"], "a") as f:
    print(json.dumps(["native", name, sys.argv[1:] if len(sys.argv) > 1 else [], os.getpid(), os.getsid(0)]), file=f)
print(json.dumps([name, sys.argv[1:]]))
""")
        first = self.hold("run")
        self.has_started("run")
        p1 = self.start("forge", "capabilities", n=1)
        self.await_status(1, [2])
        p2 = self.start("forge", "run", "--recipe", "งาน ; $HOME.json", n=0)
        self.await_status(1, [2, 3])
        self.assertEqual(self.events(), [("start", "run")])
        self.release.touch()
        self.completed(first, 0)
        self.assertEqual(json.loads(self.completed(p1, 0)[0]), ["safarium-forge", ["capabilities"]])
        self.assertEqual(json.loads(self.completed(p2, 0)[0]), ["safarium-forge", ["run", "--recipe", "งาน ; $HOME.json"]])
        self.assertEqual(self.status(), IDLE)

    def test_install_render_symlinked_ancestor_and_extra_file_detection(self):
        installer = Path(__file__).resolve().parents[2] / "Tools" / "install-render.py"
        real_parent = self.root / "real-parent"
        real_parent.mkdir(mode=0o700)
        link_parent = self.root / "link-parent"
        link_parent.symlink_to(real_parent, target_is_directory=True)
        sym_prefix = link_parent / "prefix"

        release = self.root / "dummy-release"
        release.mkdir(mode=0o700)
        for name in ("safarium-html", "safarium-media", "safarium-forge"):
            shutil.copyfile("/usr/bin/true", release / name)
            os.chmod(release / name, 0o700)
        bundle = release / "Safarium_SafariumCore.bundle" / "Contents" / "Resources"
        bundle.mkdir(parents=True, mode=0o700)
        real_clock = Path(__file__).resolve().parents[2] / "Sources" / "SafariumCore" / "Resources" / "clock.js"
        shutil.copyfile(real_clock, bundle / "clock.js")
        verifier = self.root / "dummy-verify"
        shutil.copyfile("/usr/bin/true", verifier)
        os.chmod(verifier, 0o700)

        inst = subprocess.run(
            [*PY, str(installer), "--prefix", str(sym_prefix), "--release", str(release), "--verifier", str(verifier)],
            capture_output=True, text=True, timeout=15
        )
        self.assertEqual(inst.returncode, 0, inst.stderr)
        chk = subprocess.run(
            [*PY, str(installer), "--prefix", str(sym_prefix), "--check"],
            capture_output=True, text=True, timeout=15
        )
        self.assertEqual(chk.returncode, 0, chk.stderr)
        info = json.loads(chk.stdout)
        release_dir = sym_prefix.resolve() / "share" / "safarium" / "releases" / info["release"]
        (release_dir / "rogue.txt").write_text("unexpected")
        chk_bad = subprocess.run(
            [*PY, str(installer), "--prefix", str(sym_prefix), "--check"],
            capture_output=True, text=True, timeout=15
        )
        self.assertNotEqual(chk_bad.returncode, 0, chk_bad.stdout)

    def test_readonly_bypass_and_doctor_status_detail_do_not_block(self):
        forge_bin = self.libexec / "safarium-forge"
        write_executable(forge_bin, """#!/usr/bin/python3 -ISB
import json, sys
print(json.dumps({"tool": "safarium-forge", "argv": sys.argv[1:]}))
""")
        self.assertEqual(self.call("doctor", "--bogus").returncode, os.EX_USAGE)

        first = self.hold("run")
        self.has_started("run")

        det = self.call("status", "--json-detail")
        self.assertEqual(det.returncode, 0, det.stderr)
        det_json = json.loads(det.stdout)
        self.assertEqual(det_json["active"], 1)
        self.assertEqual(len(det_json["details"]), 1)
        self.assertEqual(det_json["details"][0]["ticket"], 1)

        ver = self.call("version")
        self.assertEqual(ver.returncode, 0, ver.stderr)
        self.assertEqual(json.loads(ver.stdout)["safarium_render"], "wave6")

        doc = self.call("doctor", "--json")
        doc_json = json.loads(doc.stdout)
        self.assertEqual(doc_json["queue"]["active"], 1)
        self.assertIn("workers", doc_json)
        self.assertIn("host", doc_json)

        for cmd in (
            ("capabilities",),
            ("schema", "recipe"),
            ("forge", "schema"),
            ("forge", "validate", "--recipe", "r.json"),
            ("forge", "inspect", "clip.mp4"),
            ("forge", "probe", "clip.mp4"),
            ("forge", "cache", "stats"),
            ("forge", "run", "--recipe", "r.json", "--dry-run"),
        ):
            r = self.call(*cmd)
            self.assertEqual(r.returncode, 0, f"{cmd} failed: {r.stderr}")
            self.assertEqual(json.loads(r.stdout)["tool"], "safarium-forge")

        # Mutating forge run must STILL block in FIFO behind active slot 1!
        mut = self.start("forge", "run", "--recipe", "mut.json", n=1)
        self.await_status(1, [2])

        # `--dry-run` as the value of `--recipe` is a filename, not a read-only flag: must NOT bypass FIFO!
        tricky = self.start("forge", "run", "--recipe", "--dry-run", n=1)
        self.await_status(1, [2, 3])

        # Unknown env flags and bogus schema flags must be rejected
        self.assertEqual(self.call("schema", "--bogus-flag").returncode, os.EX_USAGE)

        self.release.touch()
        self.completed(first, 0)
        self.assertEqual(json.loads(self.completed(mut, 0)[0])["argv"], ["run", "--recipe", "mut.json"])
        self.assertEqual(json.loads(self.completed(tricky, 0)[0])["argv"], ["run", "--recipe", "--dry-run"])
        self.assertEqual(self.status(), IDLE)

        env_bad = self.call("run", "--", "env", "-iS", "ffmpeg -version")
        self.assertEqual(env_bad.returncode, 126)
        self.assertEqual(self.status(), IDLE)

    def test_unified_safarium_cli_routing_and_install_verify(self):
        repo_root = Path(__file__).resolve().parents[2]
        safarium_src = repo_root / "bin" / "safarium"
        self.assertTrue(safarium_src.is_file(), f"missing unified entrypoint: {safarium_src}")
        self.assertTrue(os.access(safarium_src, os.X_OK), "bin/safarium must be executable")

        unified = self.bin.parent / "safarium"
        shutil.copyfile(safarium_src, unified)
        unified.chmod(0o700)

        # Stub sibling safarium-render and safarium-hf in isolated temp prefix (never touches live ~/.safarium-render-queue)
        write_executable(self.bin, """#!/usr/bin/python3 -ISB
import json, sys
print(json.dumps({"routed": "safarium-render", "argv": sys.argv[1:]}))
""")
        hf_stub = self.bin.parent / "safarium-hf"
        write_executable(hf_stub, """#!/usr/bin/python3 -ISB
import json, sys
print(json.dumps({"routed": "safarium-hf", "argv": sys.argv[1:]}))
""")

        def run_unified(*args):
            return subprocess.run([str(unified), *args], capture_output=True, text=True, timeout=6,
                                  cwd=self.dirs[0], env=self.env(0))

        h = run_unified("--help")
        self.assertEqual(h.returncode, 0, h.stderr)
        for token in ("safarium", "html", "media", "forge", "prism", "hf", "raster", "verify", "doctor", "status"):
            self.assertIn(token, h.stdout)

        for args, expected in [
            (("status", "--json-detail"), ["status", "--json-detail"]),
            (("doctor", "--json"), ["doctor", "--json"]),
            (("capabilities",), ["capabilities"]),
            (("version",), ["version"]),
            (("schema", "recipe"), ["schema", "recipe"]),
            (("html", "a.html", "-o", "b.mp4"), ["html", "a.html", "-o", "b.mp4"]),
            (("verify", "a.mp4", "b.mp4"), ["verify", "a.mp4", "b.mp4"]),
            (("forge", "capabilities"), ["forge", "capabilities"]),
            (("extract-frames", "in.mp4", "--times", "0.1"), ["extract-frames", "in.mp4", "--times", "0.1"]),
            (("media", "extract-frames", "in.mp4", "--times", "0.1"), ["extract-frames", "in.mp4", "--times", "0.1"]),
            (("prism", "render-web", "a.html"), ["forge", "prism", "render-web", "a.html"]),
            (("run", "--", "/usr/bin/true"), ["run", "--", "/usr/bin/true"]),
        ]:
            r = run_unified(*args)
            self.assertEqual(r.returncode, 0, f"{args} failed: {r.stderr}")
            self.assertEqual(json.loads(r.stdout), {"routed": "safarium-render", "argv": expected})

        # `safarium media` help & invalid subcommand
        self.assertEqual(run_unified("media", "--help").returncode, 0)
        self.assertEqual(run_unified("media", "bogus-op").returncode, os.EX_USAGE)

        # `safarium hf` delegates cleanly to sibling `safarium-hf`
        r_hf = run_unified("hf", "check", "scene")
        self.assertEqual(r_hf.returncode, 0, r_hf.stderr)
        self.assertEqual(json.loads(r_hf.stdout), {"routed": "safarium-hf", "argv": ["check", "scene"]})

        # `safarium raster info` reports libSafariumRaster.dylib presence/path/ABI cleanly
        r_missing = run_unified("raster", "info")
        self.assertEqual(r_missing.returncode, 0, r_missing.stderr)
        info_missing = json.loads(r_missing.stdout)
        self.assertFalse(info_missing["present"])

        raster_dylib = self.libexec / "libSafariumRaster.dylib"
        shutil.copyfile("/usr/lib/libSystem.B.dylib" if Path("/usr/lib/libSystem.B.dylib").exists() else "/usr/bin/true", raster_dylib)
        r_present = run_unified("raster", "info")
        self.assertEqual(r_present.returncode, 0, r_present.stderr)
        info_present = json.loads(r_present.stdout)
        self.assertTrue(info_present["present"])
        self.assertEqual(Path(info_present["path"]).resolve(), raster_dylib.resolve())
        self.assertIn("abi", info_present)

        # Verify install-render.py installs & checks BOTH bin/safarium and bin/safarium-render
        installer = repo_root / "Tools" / "install-render.py"
        inst_prefix = self.root / "unified-install"
        release = self.root / "unified-release"
        release.mkdir(mode=0o700)
        for name in ("safarium-html", "safarium-media", "safarium-forge"):
            shutil.copyfile("/usr/bin/true", release / name)
            os.chmod(release / name, 0o700)
        bundle = release / "Safarium_SafariumCore.bundle" / "Contents" / "Resources"
        bundle.mkdir(parents=True, mode=0o700)
        shutil.copyfile(repo_root / "Sources" / "SafariumCore" / "Resources" / "clock.js", bundle / "clock.js")
        verifier = self.root / "unified-verify"
        shutil.copyfile("/usr/bin/true", verifier)
        os.chmod(verifier, 0o700)

        inst = subprocess.run(
            [*PY, str(installer), "--prefix", str(inst_prefix), "--release", str(release), "--verifier", str(verifier)],
            capture_output=True, text=True, timeout=15
        )
        self.assertEqual(inst.returncode, 0, inst.stderr)
        self.assertTrue((inst_prefix / "bin" / "safarium").is_symlink())
        self.assertTrue((inst_prefix / "bin" / "safarium-render").is_symlink())
        chk = subprocess.run([*PY, str(installer), "--prefix", str(inst_prefix), "--check"],
                             capture_output=True, text=True, timeout=15)
        self.assertEqual(chk.returncode, 0, chk.stderr)
        chk_json = json.loads(chk.stdout)
        rel_dir = inst_prefix / "share" / "safarium" / "releases" / chk_json["release"]
        manifest = json.loads((rel_dir / "manifest.json").read_text())
        self.assertIn("bin/safarium", manifest["files"])
        self.assertIn("bin/safarium-render", manifest["files"])
        self.assertTrue((inst_prefix / "bin" / "safarium").exists())
        # Tampering with bin/safarium inside release must fail --check
        (rel_dir / "bin" / "safarium").write_text("#!/bin/sh\nexit 1\n")
        chk_tampered = subprocess.run([*PY, str(installer), "--prefix", str(inst_prefix), "--check"],
                                      capture_output=True, text=True, timeout=15)
        self.assertNotEqual(chk_tampered.returncode, 0)

        # Upgrading from an older Wave 6 release (manifest lacking bin/safarium) must succeed cleanly
        legacy_prefix = self.root / "legacy-install"
        for sub in ("bin", "libexec", "share/safarium/releases"):
            (legacy_prefix / sub).mkdir(parents=True, mode=0o700)
        import hashlib
        legacy_files = {
            "bin/safarium-render": {"sha256": hashlib.sha256((repo_root / "bin/safarium-render").read_bytes()).hexdigest(), "mode": 0o700},
            "libexec/safarium/safarium-html": {"sha256": hashlib.sha256((release / "safarium-html").read_bytes()).hexdigest(), "mode": 0o700},
            "libexec/safarium/safarium-verify": {"sha256": hashlib.sha256(verifier.read_bytes()).hexdigest(), "mode": 0o700},
            "libexec/safarium/Safarium_SafariumCore.bundle/Contents/Resources/clock.js": {
                "sha256": hashlib.sha256((bundle / "clock.js").read_bytes()).hexdigest(), "mode": 0o600
            },
            "share/safarium/render-standard.md": {"sha256": hashlib.sha256((repo_root / "docs/render-standard.md").read_bytes()).hexdigest(), "mode": 0o600},
        }
        legacy_tag = hashlib.sha256(json.dumps(legacy_files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        legacy_rel = legacy_prefix / "share/safarium/releases" / legacy_tag
        for rel_path, src_path, mode in [
            ("bin/safarium-render", repo_root / "bin/safarium-render", 0o700),
            ("libexec/safarium/safarium-html", release / "safarium-html", 0o700),
            ("libexec/safarium/safarium-verify", verifier, 0o700),
            ("libexec/safarium/Safarium_SafariumCore.bundle/Contents/Resources/clock.js", bundle / "clock.js", 0o600),
            ("share/safarium/render-standard.md", repo_root / "docs/render-standard.md", 0o600),
        ]:
            dst_p = legacy_rel / rel_path
            dst_p.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src_path, dst_p)
            dst_p.chmod(mode)
        (legacy_rel / "manifest.json").write_text(json.dumps({"format": "safarium.personal-render-release/1", "files": legacy_files}, indent=2, sort_keys=True) + "\n")
        (legacy_prefix / "share/safarium/current").symlink_to(f"releases/{legacy_tag}")
        (legacy_prefix / "bin/safarium-render").symlink_to("../share/safarium/current/bin/safarium-render")
        (legacy_prefix / "libexec/safarium").symlink_to("../share/safarium/current/libexec/safarium")
        (legacy_prefix / "share/safarium/render-standard.md").symlink_to("current/share/safarium/render-standard.md")
        (legacy_prefix / "share/safarium/project-video-rule.md").symlink_to("current/share/safarium/project-video-rule.md")

        upg = subprocess.run(
            [*PY, str(installer), "--prefix", str(legacy_prefix), "--release", str(release), "--verifier", str(verifier)],
            capture_output=True, text=True, timeout=15
        )
        self.assertEqual(upg.returncode, 0, upg.stderr)
        upg_json = json.loads(upg.stdout)
        self.assertEqual(upg_json["status"], "installed")
        self.assertEqual(upg_json["previous_release"], legacy_tag)
        self.assertTrue((legacy_prefix / "bin/safarium").is_symlink())
        chk_upg = subprocess.run([*PY, str(installer), "--prefix", str(legacy_prefix), "--check"],
                                 capture_output=True, text=True, timeout=15)
        self.assertEqual(chk_upg.returncode, 0, chk_upg.stderr)



if __name__ == "__main__":
    if "--scratch" in sys.argv:
        i = sys.argv.index("--scratch")
        SCRATCH = str(Path(sys.argv[i + 1]).resolve(strict=True))
        del sys.argv[i:i + 2]
    unittest.main()
