"""POSIX controlling-terminal checks; run with the path to a native habush."""
import os
import pty
import select
import signal
import sys
import time


pending = {}


def receive(fd, needle, timeout=5):
    output = pending.setdefault(fd, bytearray())
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if needle in output:
            end = output.index(needle) + len(needle)
            result = bytes(output[:end])
            del output[:end]
            return result
        if not select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]:
            break
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        output.extend(chunk)
    raise AssertionError(f"missing {needle!r}: {bytes(output)[-1500:]!r}")


binary = os.path.abspath(sys.argv[1])


def wait_exit(pid, fd):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        child, status = os.waitpid(pid, os.WNOHANG)
        if child:
            return status
        if select.select([fd], [], [], 0.01)[0]:
            try:
                os.read(fd, 65536)
            except OSError:
                pass
    raise AssertionError("shell did not exit")


for label, command in [
    ("loop", "while true; do :; done"),
    ("read", "read item"),
    ("nested loop", "value=$(while true; do :; done)"),
    ("external", "/bin/sleep 30"),
]:
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ, TERM="xterm", HABUSH_LINE_EDIT="on",
                   HABUSH_SHELL_INTEGRATION="off")
        os.execve(binary, [binary], env)
    try:
        pending[fd] = bytearray()
        receive(fd, b"habush> ")
        os.write(fd, ("/bin/echo __STARTED__; " + command + "\n").encode())
        receive(fd, b"__STARTED__\r\n")
        # Let the next command enter its loop/read/foreground handoff.
        time.sleep(0.1)
        os.write(fd, b"\x03")
        receive(fd, b"habush> ")
        os.write(fd, b"/bin/echo __STATUS__$?\n")
        receive(fd, b"__STATUS__130\r\n")
        receive(fd, b"habush> ")
        os.write(fd, b"exit 0\n")
        status = wait_exit(pid, fd)
        pid = None
        assert os.waitstatus_to_exitcode(status) == 0
        print(f"interactive cancellation: {label} passed")
    finally:
        if pid is not None:
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if fd is not None:
            os.close(fd)
        if pid is not None:
            os.waitpid(pid, 0)
