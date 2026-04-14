"""Проверка встраивания JSON в universal_sonaria_bot.lua для инжекторов без variadic args."""

from __future__ import annotations

from farm.game import injector_backend as ib
from farm.game import injector_launcher as inj


def test_lua_long_bracket_handles_json_with_brackets() -> None:
    s = 'a]]b"}{[]'
    lit = ib._lua_long_bracket_string(s)
    assert lit.startswith("[")
    assert lit.endswith("]")
    assert s in lit


def test_materialize_prepends_rawset_glob(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(inj, "REPO_ROOT", tmp_path)
    monkeypatch.setenv("INJECTOR_UNIVERSAL_EMBED_PARAMS", "1")

    src = tmp_path / "universal_sonaria_bot.lua"
    src.write_text('print("body")\n', encoding="utf-8")

    out = ib.materialize_universal_script_bundle(
        task_id="abc-task",
        source_path=src,
        params={"command": "farm", "x": 1},
    )
    text = out.read_text(encoding="utf-8")
    assert "rawset(_G," in text
    assert "__SONARIA_PARAMS_JSON" in text
    assert '"command":"farm"' in text
    assert 'print("body")' in text
    assert out.is_file()
    assert out.parent.name == "inject_universal_wrap"


def test_materialize_skip_when_disabled(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(inj, "REPO_ROOT", tmp_path)
    monkeypatch.setenv("INJECTOR_UNIVERSAL_EMBED_PARAMS", "0")

    src = tmp_path / "u.lua"
    src.write_text("x\n", encoding="utf-8")
    assert ib.materialize_universal_script_bundle(task_id="t", source_path=src, params={}) == src.resolve()
