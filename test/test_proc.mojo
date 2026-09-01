from refinery.proc import join_argv, run, run_checked, shell_quote, tail
from std.testing import assert_equal, assert_true, assert_raises, TestSuite

comptime TMP = "/private/tmp/claude-501/-Volumes-ExtNVMe-dev-labelrefinery/52a63f46-5e24-45f5-801b-0e8f9c0fda9c/scratchpad/proctest"


def test_shell_quote_wraps_and_escapes() raises:
    assert_equal(shell_quote("plain"), "'plain'")
    assert_equal(shell_quote("with space"), "'with space'")
    assert_equal(shell_quote("it's"), "'it'\\''s'")


def test_join_argv_quotes_every_element() raises:
    assert_equal(join_argv(["echo", "a b"]), "'echo' 'a b'")


def test_run_captures_stdout() raises:
    var r = run(["echo", "hello world"], TMP + "/echo.log")
    assert_equal(r.exit_code, 0)
    assert_true(r.ok())
    assert_equal(r.output, "hello world\n")


def test_run_captures_stderr_too() raises:
    var r = run(["sh", "-c", "echo oops >&2"], TMP + "/err.log")
    assert_equal(r.exit_code, 0)
    assert_equal(r.output, "oops\n")


def test_run_reports_exit_code() raises:
    var r = run(["sh", "-c", "exit 3"], TMP + "/code.log")
    assert_equal(r.exit_code, 3)
    assert_true(not r.ok())


def test_run_honours_cwd() raises:
    var r = run(["pwd"], TMP + "/pwd.log", cwd="/tmp")
    assert_equal(r.exit_code, 0)
    assert_true(r.output.startswith("/tmp") or r.output.startswith("/private/tmp"))


def test_args_with_spaces_survive() raises:
    var r = run(["echo", "one two", "three"], TMP + "/space.log")
    assert_equal(r.output, "one two three\n")


def test_run_checked_raises_on_failure() raises:
    with assert_raises():
        _ = run_checked(["sh", "-c", "echo boom; exit 1"], TMP + "/boom.log")


def test_tail_truncates() raises:
    assert_equal(tail("abcdef", 3), "def")
    assert_equal(tail("ab", 10), "ab")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
