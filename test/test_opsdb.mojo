from refinery.opsdb import OpsDb
from std.testing import assert_equal, assert_true, TestSuite


def _db() raises -> OpsDb:
    return OpsDb(":memory:")


def test_new_invocation_returns_an_id() raises:
    var db = _db()
    var inv = db.new_invocation("/scenes/a.mcap", 7, "/work/a")
    assert_true(inv.byte_length() > 0)


def test_ids_are_distinct() raises:
    var db = _db()
    var a = db.new_invocation("/scenes/a.mcap", 1, "/work/a")
    var b = db.new_invocation("/scenes/b.mcap", 2, "/work/b")
    assert_true(a != b)


def test_seq_starts_at_zero_and_advances() raises:
    var db = _db()
    var inv = db.new_invocation("/s.mcap", 1, "/w")
    assert_equal(db.next_seq(inv), 0)
    _ = db.start_step(inv, 0, "export_scene", "subprocess", "{}")
    assert_equal(db.next_seq(inv), 1)


def test_finish_step_records_outcome() raises:
    var db = _db()
    var inv = db.new_invocation("/s.mcap", 1, "/w")
    var step = db.start_step(inv, 0, "geometry", "mojo", '{"terrain": true}')
    db.finish_step(step, "ok", '{"labels": "abc"}', '{"tracks": 12}', "/logs/g.log", "")
    var q = db.db.prepare("SELECT status, metrics_json, log_path FROM step_run WHERE id = ?")
    q.bind_text(1, step)
    var row = q.step()
    assert_true(Bool(row))
    ref r = row.value()
    assert_equal(r.text_val(0), "ok")
    assert_equal(r.text_val(1), '{"tracks": 12}')
    assert_equal(r.text_val(2), "/logs/g.log")


def test_decision_is_recorded() raises:
    var db = _db()
    var inv = db.new_invocation("/s.mcap", 1, "/w")
    _ = db.record_decision(inv, 0, '["a","b"]', "a", "random pick", "random")
    var q = db.db.prepare("SELECT chosen, model FROM router_decision WHERE invocation_id = ?")
    q.bind_text(1, inv)
    var row = q.step()
    assert_true(Bool(row))
    ref r = row.value()
    assert_equal(r.text_val(0), "a")
    assert_equal(r.text_val(1), "random")


def test_ledger_roundtrip_and_upsert() raises:
    var db = _db()
    assert_equal(db.ledger_key("/w", "export_scene"), "")
    db.record_ledger("/w", "export_scene", "key1", '{"tf": "h1"}', "{}")
    assert_equal(db.ledger_key("/w", "export_scene"), "key1")
    assert_equal(db.ledger_outputs("/w", "export_scene"), '{"tf": "h1"}')
    # re-running the same step replaces the row rather than duplicating it
    db.record_ledger("/w", "export_scene", "key2", '{"tf": "h2"}', "{}")
    assert_equal(db.ledger_key("/w", "export_scene"), "key2")
    var q = db.db.prepare("SELECT COUNT(*) FROM step_ledger")
    var row = q.step()
    ref r = row.value()
    assert_equal(r.int_val(0), 1)


def test_ledger_is_per_work_dir() raises:
    var db = _db()
    db.record_ledger("/w1", "geometry", "k1", "{}", "{}")
    db.record_ledger("/w2", "geometry", "k2", "{}", "{}")
    assert_equal(db.ledger_key("/w1", "geometry"), "k1")
    assert_equal(db.ledger_key("/w2", "geometry"), "k2")


def test_file_db_is_in_wal_mode() raises:
    var path = String(
        "/private/tmp/claude-501/-Volumes-ExtNVMe-dev-labelrefinery/"
        "52a63f46-5e24-45f5-801b-0e8f9c0fda9c/scratchpad/ops_wal_test.db"
    )
    var db = OpsDb(path)
    var q = db.db.prepare("PRAGMA journal_mode")
    var row = q.step()
    assert_true(Bool(row))
    ref r = row.value()
    assert_equal(r.text_val(0), "wal")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
