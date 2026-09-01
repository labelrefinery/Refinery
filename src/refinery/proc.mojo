"""Run an external command, capture its output, and report how it exited.

`std.os.Process.run` spawns through `posix_spawnp` with no file actions, so the
child inherits our stdout and there is no way to redirect it. Every stage here
needs both a working directory and its output — metrics are scraped from stdout
(`raw detections: N`, `tracks: n kept: m`, `named_by k=v`) — so commands go
through `/bin/sh -c` with the working directory and redirection expressed in the
shell command itself.

The log is a file rather than a pipe on purpose: the control site links to it,
so a failed stage leaves something to read rather than a truncated string in an
error message.
"""

from std.os import Process, makedirs
from std.os.path import dirname, exists


@fieldwise_init
struct RunResult(Copyable, Movable):
    """What a finished command left behind."""

    var exit_code: Int
    """0 on success. A shell that could not exec reports 127."""
    var output: String
    """stdout and stderr, interleaved as the shell wrote them."""
    var log_path: String
    """Where `output` was captured, for the site to link to."""

    def ok(self) -> Bool:
        return self.exit_code == 0


def shell_quote(s: String) -> String:
    """Wrap `s` in single quotes so the shell takes it literally.

    A single quote inside is closed, escaped and reopened -- the standard
    `'\\''` dance. Paths here contain spaces often enough (the dev tree lives
    under `/Volumes/ExtNVMe`) that skipping this would be a bug waiting for the
    first directory with a space in it.
    """
    var out = String("'")
    for i in range(s.byte_length()):
        var c = s[byte=i]
        if c == "'":
            out += "'\\''"
        else:
            out += String(c)
    out += "'"
    return out^


def join_argv(argv: List[String]) -> String:
    """Quote every element and join with spaces."""
    var cmd = String("")
    var first = True
    for a in argv:
        if not first:
            cmd += " "
        cmd += shell_quote(a)
        first = False
    return cmd^


def tail(s: String, max_bytes: Int) -> String:
    """The last `max_bytes` bytes of `s`, for error messages."""
    var n = s.byte_length()
    if n <= max_bytes:
        return s.copy()
    var out = String("")
    for i in range(n - max_bytes, n):
        out += String(s[byte=i])
    return out^


def run(
    argv: List[String], log_path: String, cwd: String = ""
) raises -> RunResult:
    """Run `argv`, capturing stdout and stderr to `log_path`.

    Returns the result whatever the exit code; use `run_checked` to make a
    non-zero exit an error.
    """
    var log_dir = dirname(log_path)
    if log_dir != "" and not exists(log_dir):
        makedirs(log_dir, exist_ok=True)

    var script = String("")
    if cwd != "":
        script += "cd " + shell_quote(cwd) + " && "
    script += join_argv(argv) + " > " + shell_quote(log_path) + " 2>&1"

    var proc = Process.run("/bin/sh", ["-c", script])
    var status = proc.wait()
    var code = status.exit_code.or_else(-1)

    # The command may have died before the shell created the log.
    var output: String
    try:
        output = open(log_path, "r").read()
    except:
        output = String("")

    return RunResult(code, output^, log_path.copy())


def run_checked(
    argv: List[String], log_path: String, cwd: String = ""
) raises -> RunResult:
    """`run`, but a non-zero exit raises, mirroring the Python `ctx.run`."""
    var result = run(argv, log_path, cwd)
    if not result.ok():
        raise Error(
            "command failed ("
            + String(result.exit_code)
            + "): "
            + join_argv(argv)
            + "\nlog: "
            + result.log_path
            + "\n"
            + tail(result.output, 2000)
        )
    return result^
