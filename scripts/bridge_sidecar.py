#!/usr/bin/env python3
"""
Sidecar для файлового моста: шаблон «внешнего клиента» без игровой логики.

Делает то же, что file_bridge_echo (пишет ok-response), плюс печатает краткое
содержимое входящего request — удобно проверить, что воркер шлёт ожидаемый JSON.

Запуск из корня репозитория (нужен тот же .env, что у воркера):

  python scripts/bridge_sidecar.py

Переменные:
  BRIDGE_SIDECAR_POLL   — секунды между опросами (по умолчанию 0.5)
  BRIDGE_SIDECAR_AUTO_OK — 1/0: автоматически писать {"ok": true, ...} (по умолчанию 1)
  BRIDGE_SIDECAR_VERBOSE — 1/0: печатать полный JSON request (по умолчанию 0)

Дальше: скопируй файл в external/ или свой проект и замени логику на вызов игры,
сохранив запись response в формате из README.
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from farm.game import file_bridge as fb  # noqa: E402

POLL = float(os.environ.get("BRIDGE_SIDECAR_POLL", os.environ.get("BRIDGE_ECHO_POLL", "0.5")))
AUTO_OK = os.environ.get("BRIDGE_SIDECAR_AUTO_OK", "1").strip().lower() in ("1", "true", "yes")
VERBOSE = os.environ.get("BRIDGE_SIDECAR_VERBOSE", "").strip().lower() in ("1", "true", "yes")


def _summarize_request(body: Any) -> str:
    if not isinstance(body, dict):
        return repr(body)[:500]
    bridge = body.get("bridge")
    tid = body.get("task_id")
    keys = sorted(body.keys())
    return f"bridge={bridge!r} task_id={tid!r} keys={keys}"


def build_response(body: dict[str, Any]) -> dict[str, Any]:
    """
    Замени тело ответа под реальную игру. По умолчанию — успех-заглушка.

    Для farm_tick обычно нужны поля из README (death_points_current и т.д.).
    """
    bridge = body.get("bridge")
    base: dict[str, Any] = {
        "ok": True,
        "log": f"bridge_sidecar stub (bridge={bridge!r})",
    }
    # farm_tick request не содержит "bridge", зато есть tick_seq (см. WindowsGameAdapter.farm_tick)
    if "tick_seq" in body:
        base["death_points_current"] = 0
    return base


def main() -> None:
    dirs = fb.iter_distinct_bridge_directories()
    print("bridge_sidecar: polling (Ctrl+C to stop)")
    print(f"  AUTO_OK={AUTO_OK} POLL={POLL}s")
    for d in dirs:
        print(" ", d.resolve())
    if not AUTO_OK:
        print("  BRIDGE_SIDECAR_AUTO_OK=0 — ответы не пишутся; только лог request.")

    while True:
        for d in dirs:
            if not d.is_dir():
                continue
            for req in sorted(d.glob("*.request.json")):
                resp = fb.echo_response_path_for_request(req)
                if resp is None:
                    continue
                if resp.exists():
                    continue
                try:
                    raw = req.read_bytes()
                    body = json.loads(raw.decode("utf-8-sig"))
                except Exception as exc:
                    print(f"! read {req}: {exc}")
                    continue

                print(f"\n>> {req.name}")
                if VERBOSE and isinstance(body, dict):
                    print(json.dumps(body, ensure_ascii=False, indent=2))
                else:
                    print(_summarize_request(body))

                if not AUTO_OK:
                    continue

                out = build_response(body) if isinstance(body, dict) else {"ok": True, "log": "non-dict body"}
                try:
                    resp.write_text(
                        json.dumps(out, ensure_ascii=False, indent=2),
                        encoding="utf-8",
                    )
                    print(f"<< {resp.name}")
                except OSError as exc:
                    print(f"! write {resp}: {exc}")
        time.sleep(POLL)


if __name__ == "__main__":
    main()
