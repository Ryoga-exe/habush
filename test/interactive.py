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


prompt = b"\x1b]133;B\x1b\\"


def check_status(fd):
    os.write(fd, b"/bin/echo __STATUS__$?\n")
    receive(fd, b"__STATUS__130\r\n")
    receive(fd, prompt)


cases = [
    ("loop", "while true; do :; done"),
    ("read", "read item"),
    ("nested loop", "value=$(while true; do :; done)"),
    ("nested external", "value=$(/bin/sleep 30)"),
    ("external", "/bin/sleep 30"),
]
for mode, term, commands in [
    ("on", "xterm", cases),
    ("off", "xterm", cases),
    ("auto", "dumb", []),
]:
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ, TERM=term, HABUSH_LINE_EDIT=mode,
                   HABUSH_SHELL_INTEGRATION="on")
        os.execve(binary, [binary], env)
    try:
        pending[fd] = bytearray()
        receive(fd, prompt)
        # Ctrl-C must cancel input itself, so the first new line is not thrown
        # away by a stale signal generation when it reaches the evaluator.
        os.write(fd, b"\x03")
        receive(fd, prompt)
        check_status(fd)
        # A here-document owns partial body/source buffers while it reads.
        os.write(fd, b": <<EOF\n")
        receive(fd, b"> ")
        os.write(fd, b"\x03")
        receive(fd, prompt)
        check_status(fd)
        print(f"interactive input cancellation: {mode} passed")
        for label, command in commands:
            os.write(fd, ("/bin/echo __STARTED__; " + command + "\n").encode())
            receive(fd, b"__STARTED__\r\n")
            # Let the next command enter its loop/read/foreground handoff.
            time.sleep(0.1)
            os.write(fd, b"\x03")
            receive(fd, prompt)
            check_status(fd)
            print(f"interactive cancellation: {mode} {label} passed")
        if mode != "auto":
            os.write(fd, b"/bin/sleep 30 & /bin/echo __STARTED__; while true; do :; done\n")
            receive(fd, b"__STARTED__\r\n")
            time.sleep(0.1)
            os.write(fd, b"\x03")
            receive(fd, prompt)
            check_status(fd)
            os.write(fd, b"jobs; /bin/echo __JOBS_END__$?\n")
            jobs = receive(fd, b"__JOBS_END__0\r\n")
            assert b"Running" in jobs, jobs
            receive(fd, prompt)
            print(f"interactive cancellation: {mode} background retained")
        os.write(fd, b"exit 0\n")
        status = wait_exit(pid, fd)
        pid = None
        assert os.waitstatus_to_exitcode(status) == 0
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
