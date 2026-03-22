"""Тесты контракта файлового моста (без PostgreSQL и воркера)."""

from __future__ import annotations

from pathlib import Path

import pytest

from farm.game import file_bridge as fb


def test_echo_response_path_legacy() -> None:
    p = Path("/tmp/x") / "550e8400-e29b-41d4-a716-446655440000.request.json"
    r = fb.echo_response_path_for_request(p)
    assert r is not None
    assert r.name == "550e8400-e29b-41d4-a716-446655440000.response.json"


@pytest.mark.parametrize(
    "tag",
    [fb.TAG_FARM_TICK, fb.TAG_TRANSFER, fb.TAG_SELL],
)
def test_echo_response_path_unified(tag: str) -> None:
    tid = "550e8400-e29b-41d4-a716-446655440000"
    p = Path("/bridge") / f"{tid}.{tag}.request.json"
    r = fb.echo_response_path_for_request(p)
    assert r is not None
    assert r.name == f"{tid}.{tag}.response.json"


def test_bridge_request_path_and_canonical() -> None:
    d = Path("/b")
    tid = "abc-uuid"
    assert fb.bridge_request_path(d, tid, None) == d / f"{tid}.request.json"
    assert fb.bridge_canonical_response_name(tid, None) == f"{tid}.response.json"
    assert fb.bridge_request_path(d, tid, fb.TAG_TRANSFER) == d / f"{tid}.transfer.request.json"
    assert fb.bridge_canonical_response_name(tid, fb.TAG_TRANSFER) == f"{tid}.transfer.response.json"


def test_find_bridge_response_legacy(tmp_path: Path) -> None:
    tid = "task-one"
    resp = tmp_path / f"{tid}.response.json"
    resp.write_text('{"ok": true}', encoding="utf-8")
    found = fb.find_bridge_response_file(tmp_path, tid, None)
    assert found is not None
    assert found.resolve() == resp.resolve()


def test_find_bridge_response_unified(tmp_path: Path) -> None:
    tid = "task-two"
    tag = fb.TAG_FARM_TICK
    resp = tmp_path / f"{tid}.{tag}.resp.json"
    resp.write_text('{"ok": true}', encoding="utf-8")
    found = fb.find_bridge_response_file(tmp_path, tid, tag)
    assert found is not None


def test_cleanup_legacy_orphans(tmp_path: Path) -> None:
    (tmp_path / "a.request.json").write_text("{}", encoding="utf-8")
    (tmp_path / "b.request.json").write_text("{}", encoding="utf-8")
    removed = fb.cleanup_legacy_orphans(tmp_path, "a")
    assert "b.request.json" in removed
    assert (tmp_path / "a.request.json").exists()
    assert not (tmp_path / "b.request.json").exists()


def test_read_json_utf8(tmp_path: Path) -> None:
    p = tmp_path / "x.json"
    p.write_text('{"x": 1}', encoding="utf-8")
    assert fb.read_json_from_file_bytes(p) == {"x": 1}


def test_bridge_directories_unified_env(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    uni = tmp_path / "one_dir"
    uni.mkdir()
    monkeypatch.delenv("FILE_BRIDGE_ROOT", raising=False)
    monkeypatch.delenv("FARM_TICK_DIR", raising=False)
    monkeypatch.delenv("TRANSFER_BRIDGE_DIR", raising=False)
    monkeypatch.delenv("SELL_BRIDGE_DIR", raising=False)
    monkeypatch.setenv("FILE_BRIDGE_UNIFIED_DIR", str(uni))

    a, b, c = fb.bridge_directories_for_worker()
    assert a == b == c
    assert a.resolve() == uni.resolve()


def test_bridge_dir_from_file_bridge_root(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    root = tmp_path / "root"
    root.mkdir()
    monkeypatch.delenv("FILE_BRIDGE_UNIFIED_DIR", raising=False)
    monkeypatch.delenv("FARM_TICK_DIR", raising=False)
    monkeypatch.setenv("FILE_BRIDGE_ROOT", str(root))
    p = fb.bridge_dir_from_env(fb.ENV_FARM_TICK_DIR)
    assert p == fb.resolve_repo_relative(str(root / "farm_tick"))


def test_legacy_bridge_task_id() -> None:
    assert fb.legacy_bridge_task_id("x.request.json") == "x"
    assert fb.legacy_bridge_task_id("x.response.json.txt") == "x"
    assert fb.legacy_bridge_task_id("nope.txt") is None


def test_find_legacy_response_via_resp_json(tmp_path: Path) -> None:
    tid = "u1"
    (tmp_path / f"{tid}.resp.json").write_text('{"ok": true}', encoding="utf-8")
    found = fb.find_legacy_response_file(tmp_path, tid)
    assert found is not None


def test_cleanup_unified_orphans(tmp_path: Path) -> None:
    tag = fb.TAG_TRANSFER
    tid_keep = "keep-me"
    tid_drop = "drop-me"
    (tmp_path / f"{tid_keep}.{tag}.request.json").write_text("{}", encoding="utf-8")
    (tmp_path / f"{tid_drop}.{tag}.request.json").write_text("{}", encoding="utf-8")
    removed = fb.cleanup_unified_orphans(tmp_path, tid_keep, tag)
    assert f"{tid_drop}.{tag}.request.json" in removed
    assert (tmp_path / f"{tid_keep}.{tag}.request.json").exists()


def test_wipe_unified_tag_files(tmp_path: Path) -> None:
    tag = fb.TAG_SELL
    (tmp_path / f"a.{tag}.request.json").write_text("{}", encoding="utf-8")
    (tmp_path / f"b.{fb.TAG_FARM_TICK}.request.json").write_text("{}", encoding="utf-8")
    wiped = fb.wipe_unified_tag_files(tmp_path, tag)
    assert f"a.{tag}.request.json" in wiped
    assert (tmp_path / f"b.{fb.TAG_FARM_TICK}.request.json").exists()


def test_wipe_all_legacy_bridge_files(tmp_path: Path) -> None:
    (tmp_path / "x.request.json").write_text("{}", encoding="utf-8")
    (tmp_path / "readme.txt").write_text("x", encoding="utf-8")
    wiped = fb.wipe_all_legacy_bridge_files(tmp_path)
    assert "x.request.json" in wiped
    assert (tmp_path / "readme.txt").exists()


def test_pre_exchange_remove_stale_legacy(tmp_path: Path) -> None:
    tid = "t1"
    (tmp_path / f"{tid}.response.json").write_text('{"ok":true}', encoding="utf-8")
    (tmp_path / f"{tid}.resp.json").write_text('{"ok":true}', encoding="utf-8")
    fb.pre_exchange_remove_stale_responses(tmp_path, tid, None)
    assert not (tmp_path / f"{tid}.response.json").exists()
    assert not (tmp_path / f"{tid}.resp.json").exists()


def test_pre_exchange_remove_stale_unified(tmp_path: Path) -> None:
    tid = "t2"
    tag = fb.TAG_FARM_TICK
    (tmp_path / f"{tid}.{tag}.response.json").write_text("{}", encoding="utf-8")
    fb.pre_exchange_remove_stale_responses(tmp_path, tid, tag)
    assert not (tmp_path / f"{tid}.{tag}.response.json").exists()


def test_iter_distinct_three_separate_dirs(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.delenv("FILE_BRIDGE_UNIFIED_DIR", raising=False)
    monkeypatch.delenv("FILE_BRIDGE_ROOT", raising=False)
    d1 = tmp_path / "ft"
    d2 = tmp_path / "tr"
    d3 = tmp_path / "sl"
    for d in (d1, d2, d3):
        d.mkdir()
    monkeypatch.setenv("FARM_TICK_DIR", str(d1))
    monkeypatch.setenv("TRANSFER_BRIDGE_DIR", str(d2))
    monkeypatch.setenv("SELL_BRIDGE_DIR", str(d3))
    dirs = fb.iter_distinct_bridge_directories()
    assert len(dirs) == 3


def test_iter_distinct_unified_single_dir(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    uni = tmp_path / "u"
    uni.mkdir()
    monkeypatch.delenv("FILE_BRIDGE_ROOT", raising=False)
    monkeypatch.delenv("FARM_TICK_DIR", raising=False)
    monkeypatch.delenv("TRANSFER_BRIDGE_DIR", raising=False)
    monkeypatch.delenv("SELL_BRIDGE_DIR", raising=False)
    monkeypatch.setenv("FILE_BRIDGE_UNIFIED_DIR", str(uni))
    assert len(fb.iter_distinct_bridge_directories()) == 1


def test_unified_bridge_task_id() -> None:
    tid = "11111111-1111-1111-1111-111111111111"
    assert fb.unified_bridge_task_id(f"{tid}.{fb.TAG_SELL}.request.json", fb.TAG_SELL) == tid
    assert fb.unified_bridge_task_id(f"{tid}.{fb.TAG_SELL}.response.json", fb.TAG_SELL) == tid
    assert fb.unified_bridge_task_id("wrong.json", fb.TAG_SELL) is None


def test_read_json_utf16_le(tmp_path: Path) -> None:
    p = tmp_path / "u16.json"
    payload = '{"k": "в"}'.encode("utf-16-le")
    p.write_bytes(b"\xff\xfe" + payload)
    assert fb.read_json_from_file_bytes(p) == {"k": "в"}


def test_cleanup_bridge_orphans_dispatch_unified(tmp_path: Path) -> None:
    tag = fb.TAG_TRANSFER
    (tmp_path / f"a.{tag}.request.json").write_text("{}", encoding="utf-8")
    (tmp_path / f"b.{tag}.request.json").write_text("{}", encoding="utf-8")
    r = fb.cleanup_bridge_orphans(tmp_path, "a", tag)
    assert f"b.{tag}.request.json" in r
