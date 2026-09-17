#!/usr/bin/env python3
"""Build and exercise vendored dtach without touching application sessions.

Set DTACH_TEST_BINARY to verify an existing packaged helper or an old baseline
instead of building the checked-out source.
"""

import array
import errno
import fcntl
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "vendor" / "dtach"
PAYLOAD = b"".join(index.to_bytes(4, "big") for index in range(524288))
PACKET = struct.Struct("BB8s")


def configure_producer(directory):
    root = Path(directory)
    signal.alarm(30)
    tty.setraw(0)
    signal.signal(signal.SIGWINCH, lambda *_: os.write(1, b"WINCH\n"))
    (root / "producer.pid.tmp").write_text(str(os.getpid()))
    (root / "producer.pid.tmp").replace(root / "producer.pid")
    return root


def producer(directory):
    root = configure_producer(directory)
    while command := os.read(0, 1):
        if command == b"R":
            os.write(1, b"READY\n")
        elif command == b"F":
            sent = 0
            while sent < len(PAYLOAD):
                sent += os.write(1, PAYLOAD[sent:sent + 4096])
                (root / "progress.tmp").write_text(str(sent))
                (root / "progress.tmp").replace(root / "progress")
        elif command == b"E":
            os.write(1, b"ECHO\n")


def controlled_producer(directory, descriptor):
    configure_producer(directory)
    control = socket.socket(fileno=descriptor)
    if os.read(0, 1) != b"R":
        raise RuntimeError("controlled producer did not receive its ready request")
    os.write(1, b"READY\n")
    while command := control.recv(1):
        if command in (b"0", b"7"):
            raise SystemExit(int(command))
        if command == b"M":
            blocked = signal.pthread_sigmask(signal.SIG_BLOCK, set())
            control.sendall(b"B" if signal.SIGCHLD in blocked else b"U")
            continue
        if command == b"K":
            os.kill(os.getpid(), signal.SIGTERM)
        data = {
            b"W": b"x" * 1024,
            b"T": b"t" * 1024,
            b"F": PAYLOAD,
        }.get(command)
        if data is None:
            raise RuntimeError(f"unknown controlled command: {command!r}")
        remaining = memoryview(data)
        while remaining:
            remaining = remaining[os.write(1, remaining):]
        if command in (b"T", b"F"):
            raise SystemExit(7)
        control.sendall(b"K")


class DtachFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        override = os.environ.get("DTACH_TEST_BINARY")
        if override:
            cls.binary = Path(override).resolve(strict=True)
            return
        cls.build = tempfile.TemporaryDirectory(prefix="dtach-build-", dir="/tmp")
        cls.addClassCleanup(cls.build.cleanup)
        subprocess.run([str(SOURCE / "configure")], cwd=cls.build.name,
                       check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["make", "-s", "CFLAGS=-O2 -Wall -Wextra -I."],
                       cwd=cls.build.name, check=True)
        cls.binary = Path(cls.build.name) / "dtach"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dtach-test-", dir="/tmp")
        self.root = Path(self.temp.name)
        self.path = self.root / "s"
        self.clients = []
        self.senders = []
        self.master = self.start_master()
        self.addCleanup(self.stop)
        self.wait_until(lambda: self.path.exists(), "master did not create its socket")
        self.wait_until(lambda: (self.root / "producer.pid").exists(), "producer did not start")
        self.client = self.connect()
        self.packet(self.client, 0, b"R")
        self.assertEqual(self.receive(self.client, 6), b"READY\n")

    def start_master(self):
        return subprocess.Popen(
            [str(self.binary), "-N", str(self.path), "-r", "winch",
             sys.executable, str(Path(__file__).resolve()), "--producer", str(self.root)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    def stop(self):
        pid_file = self.root / "producer.pid"
        producer_pid = int(pid_file.read_text()) if pid_file.exists() else None
        for client in self.clients:
            if client.fileno() >= 0:
                try:
                    client.shutdown(socket.SHUT_RDWR)
                except OSError as error:
                    if error.errno != errno.ENOTCONN:
                        raise
            client.close()
        for sender in self.senders:
            sender.join(timeout=3)
        # Closing this private master's PTY hangs up its producer as well.
        # Popen retains the unreaped PID, so it cannot target a reused PID.
        if self.master.poll() is None:
            self.master.terminate()
        try:
            self.master.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.master.kill()
            self.master.wait(timeout=3)
        if producer_pid is not None:
            deadline = time.monotonic() + 5
            while True:
                try:
                    os.kill(producer_pid, 0)
                except ProcessLookupError:
                    break
                self.assertLess(time.monotonic(), deadline, "fixture producer did not exit")
                time.sleep(0.01)
        self.temp.cleanup()

    def connect(self, attach=True):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(3)
        self.clients.append(client)
        client.connect(str(self.path))
        if attach:
            self.packet(client, 1)
        return client

    @staticmethod
    def packet(client, kind, data=b"", length=None):
        client.sendall(PACKET.pack(kind, len(data) if length is None else length, data))

    def receive(self, client, count, timeout=5):
        result = bytearray()
        deadline = time.monotonic() + timeout
        while len(result) < count:
            remaining = deadline - time.monotonic()
            self.assertGreater(remaining, 0, f"only received {len(result)} of {count} bytes")
            self.assertTrue(select.select([client], [], [], remaining)[0],
                            f"only received {len(result)} of {count} bytes")
            chunk = client.recv(count - len(result))
            self.assertTrue(chunk, "master closed the connection")
            result.extend(chunk)
        return bytes(result)

    def wait_until(self, condition, message):
        deadline = time.monotonic() + 10
        while not condition():
            self.assertIsNone(self.master.poll(), "fixture master exited")
            self.assertLess(time.monotonic(), deadline, message)
            time.sleep(0.01)

    def progress(self):
        path = self.root / "progress"
        return int(path.read_text()) if path.exists() else 0

    def saturate(self):
        self.packet(self.client, 0, b"F")
        self.wait_until(lambda: self.progress() > 0, "producer did not start")
        previous = -1
        stable_since = time.monotonic()

        def blocked():
            nonlocal previous, stable_since
            current = self.progress()
            self.assertLess(current, len(PAYLOAD), "fixture did not produce backpressure")
            if current != previous:
                previous = current
                stable_since = time.monotonic()
            return time.monotonic() - stable_since >= 0.2

        self.wait_until(blocked, "producer did not block behind the stale client")

    def request_redraw(self):
        dimensions = struct.pack("HHHH", 30, 90, 0, 0)
        self.packet(self.client, 4, dimensions, length=3)
        self.assertEqual(self.receive(self.client, 6), b"WINCH\n")
        # A size change plus explicit redraw can deliver two SIGWINCH signals.
        while select.select([self.client], [], [], 0.1)[0]:
            self.assertEqual(self.receive(self.client, 6), b"WINCH\n")
        return dimensions


class DtachTests(DtachFixture):
    def test_single_reattach_with_saturated_client(self):
        self.saturate()
        fresh = self.connect()
        self.assertTrue(self.receive(fresh, 4096))

    def test_delayed_attach_handshake_with_saturated_client(self):
        self.saturate()
        fresh = self.connect(attach=False)
        time.sleep(0.1)
        self.packet(fresh, 1)
        self.assertTrue(self.receive(fresh, 4096))

    def test_connection_during_backpressure_preserves_pending_bytes(self):
        self.saturate()
        self.connect(attach=False)
        time.sleep(0.1)
        self.assertEqual(self.receive(self.client, len(PAYLOAD)), PAYLOAD)

    def test_input_during_backpressure_preserves_pending_bytes(self):
        self.saturate()
        self.packet(self.client, 0, b"E")
        self.assertEqual(self.receive(self.client, len(PAYLOAD) + 5), PAYLOAD + b"ECHO\n")

    def test_disconnect_of_saturated_client_releases_producer(self):
        self.saturate()
        self.client.close()
        self.wait_until(lambda: self.progress() == len(PAYLOAD),
                        "disconnected client kept the producer blocked")

    def test_full_input_queue_cannot_block_the_pending_chunk(self):
        self.saturate()
        queued = array.array("i", [0])
        fcntl.ioctl(self.client, termios.FIONREAD, queued, True)
        failures = []

        def flood_input():
            try:
                for _ in range(10000):
                    self.packet(self.client, 0, b"XXXXXXXX")
            except socket.timeout:
                pass  # Filling the input queue is intentional in this test.
            except OSError as error:
                failures.append(error)

        sender = threading.Thread(target=flood_input, daemon=True)
        self.senders.append(sender)
        sender.start()
        time.sleep(0.1)
        # Read beyond the bytes already queued: the inner wait must deliver
        # its in-hand chunk before the outer loop handles the input backlog.
        self.assertEqual(self.receive(self.client, queued[0] + 1), PAYLOAD[:queued[0] + 1])
        self.assertEqual(failures, [])

    def test_input_resize_detach_and_reattach(self):
        self.packet(self.client, 0, b"E")
        self.assertEqual(self.receive(self.client, 5), b"ECHO\n")
        self.request_redraw()
        self.packet(self.client, 2)
        fresh = self.connect()
        self.packet(fresh, 0, b"E")
        self.assertEqual(self.receive(fresh, 5), b"ECHO\n")
        self.assertFalse(select.select([self.client], [], [], 0.1)[0])


class ChildExitTests(DtachFixture):
    block_sigchld = False

    def start_master(self):
        self.control, child_control = socket.socketpair()
        self.control.settimeout(3)
        self.addCleanup(self.control.close)
        previous_mask = None
        try:
            mode = signal.SIG_BLOCK if self.block_sigchld else signal.SIG_UNBLOCK
            previous_mask = signal.pthread_sigmask(mode, {signal.SIGCHLD})
            return subprocess.Popen(
                [str(self.binary), "-N", str(self.path), "-r", "winch",
                 sys.executable, str(Path(__file__).resolve()), "--controlled-producer",
                 str(self.root), str(child_control.fileno())],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                pass_fds=(child_control.fileno(),),
            )
        finally:
            if previous_mask is not None:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            child_control.close()

    def queued_output(self):
        count = array.array("i", [0])
        fcntl.ioctl(self.client, termios.FIONREAD, count, True)
        return count[0]

    def hold_one_chunk(self):
        sent = 0
        for _ in range(4096):
            before = self.queued_output()
            self.control.sendall(b"W")
            self.assertEqual(self.control.recv(1), b"K")
            sent += 1024
            deadline = time.monotonic() + 0.2
            while self.queued_output() < before + 1024 and time.monotonic() < deadline:
                time.sleep(0.002)
            if self.queued_output() < before + 1024:
                pending = sent - self.queued_output()
                self.assertGreater(pending, 0)
                self.assertLessEqual(pending, 1024, "more than the in-hand block is pending")
                return sent
        self.fail("could not backpressure the fixture client")

    def assert_exit_while_blocked(self, command, status):
        self.hold_one_chunk()
        self.control.sendall(command)
        self.assertEqual(self.master.wait(timeout=5), status)
        self.assertFalse(self.path.exists(), "exited master left its socket behind")

    def test_normal_exit_while_output_is_blocked(self):
        self.assert_exit_while_blocked(b"0", 0)

    def test_signal_mask_fixture_matches_mode(self):
        self.control.sendall(b"M")
        expected = b"B" if self.block_sigchld else b"U"
        self.assertEqual(self.control.recv(1), expected)

    def test_nonzero_exit_status_while_output_is_blocked(self):
        self.assert_exit_while_blocked(b"7", 7)

    def test_signal_termination_while_output_is_blocked(self):
        self.assert_exit_while_blocked(b"K", 1)

    def test_exit_with_additional_kernel_output(self):
        self.assert_exit_while_blocked(b"T", 7)

    def test_control_traffic_does_not_postpone_child_exit(self):
        dimensions = self.request_redraw()
        self.hold_one_chunk()
        stop = threading.Event()
        failures = []

        def resize_repeatedly():
            while not stop.wait(0.05):
                try:
                    self.packet(self.client, 3, dimensions)
                except OSError as error:
                    if error.errno not in (errno.EPIPE, errno.ECONNRESET, errno.ENOTCONN):
                        failures.append(error)
                    return

        sender = threading.Thread(target=resize_repeatedly, daemon=True)
        self.senders.append(sender)
        sender.start()
        try:
            self.control.sendall(b"0")
            self.assertEqual(self.master.wait(timeout=5), 0)
        finally:
            stop.set()
            sender.join(timeout=3)
        self.assertFalse(sender.is_alive())
        self.assertEqual(failures, [])

    def test_slow_reader_receives_pending_output_after_exit(self):
        sent = self.hold_one_chunk()
        self.control.sendall(b"0")
        time.sleep(0.2)
        received = bytearray()
        while len(received) < sent:
            received.extend(self.receive(self.client, min(1024, sent - len(received))))
            time.sleep(0.05)
        self.assertEqual(received, b"x" * sent)
        self.assertEqual(self.master.wait(timeout=5), 0)

    def test_exit_late_in_wait_still_allows_reader_to_drain(self):
        sent = self.hold_one_chunk()
        # The blocked wait has already run for about 200ms. Exit near its end,
        # then resume reading within 250ms of exit, not of the original wait.
        time.sleep(0.65)
        self.control.sendall(b"0")
        time.sleep(0.25)
        self.assertEqual(self.receive(self.client, sent), b"x" * sent)
        self.assertEqual(self.master.wait(timeout=5), 0)

    def test_live_client_drains_final_output_beside_stale_client(self):
        self.hold_one_chunk()
        fresh = self.connect()
        self.control.sendall(b"F")
        expected = b"x" * 1024 + PAYLOAD
        self.assertEqual(self.receive(fresh, len(expected), timeout=15), expected)
        self.assertEqual(self.master.wait(timeout=5), 7)

    def test_stopped_and_continued_child_keeps_pending_output(self):
        sent = self.hold_one_chunk()
        producer_pid = int((self.root / "producer.pid").read_text())
        try:
            os.kill(producer_pid, signal.SIGSTOP)
            self.wait_until(
                lambda: subprocess.check_output(
                    ["ps", "-p", str(producer_pid), "-o", "stat="], text=True
                ).strip().startswith("T"),
                "fixture producer did not stop",
            )
            time.sleep(1.2)
            self.assertIsNone(self.master.poll(), "stopped child was treated as exited")
        finally:
            try:
                os.kill(producer_pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
        self.assertEqual(self.receive(self.client, sent), b"x" * sent)
        self.control.sendall(b"0")
        self.assertEqual(self.master.wait(timeout=5), 0)

    def test_healthy_reader_receives_final_output_and_status(self):
        self.control.sendall(b"F")
        self.assertEqual(self.receive(self.client, len(PAYLOAD), timeout=15), PAYLOAD)
        self.assertEqual(self.master.wait(timeout=5), 7)


class BlockedChildSignalTests(ChildExitTests):
    """The same exit contract must hold even without a SIGCHLD wakeup."""

    block_sigchld = True


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--controlled-producer":
        controlled_producer(sys.argv[2], int(sys.argv[3]))
    elif len(sys.argv) == 3 and sys.argv[1] == "--producer":
        producer(sys.argv[2])
    else:
        unittest.main()
