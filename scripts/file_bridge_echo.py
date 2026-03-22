#!/usr/bin/env python3
"""
Авто-ответ на файловый мост (тест без инжектора).

Каталоги берутся из тех же правил, что и WindowsGameAdapter
(``farm.game.file_bridge``): три папки по умолчанию, либо ``FILE_BRIDGE_UNIFIED_DIR``
(один каталог — один вотчер на все типы мостов).

Для каждого нового ``*.request.json`` создаётся рядом канонический ``*.response.json`` с
``{"ok": true, "log": "..."}``.

Запуск из корня репозитория:
  python scripts/file_bridge_echo.py

Осторожно: с активным фармом будет отвечать на каждый тик — для стресс-теста ок,
для ручной отладки лучше остановить echo или фарм.

Переменные окружения:
  BRIDGE_ECHO_POLL — интервал опроса сек (по умолчанию 0.5)
  FILE_BRIDGE_ROOT / FILE_BRIDGE_UNIFIED_DIR / FARM_TICK_DIR / … — как у воркера
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from farm.game import file_bridge as fb  # noqa: E402

POLL = float(os.environ.get("BRIDGE_ECHO_POLL", "0.5"))


def main() -> None:
    dirs = fb.iter_distinct_bridge_directories()
    print("file_bridge_echo: watching (Ctrl+C to stop)")
    for d in dirs:
        print(" ", d.resolve())
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
                    body = json.loads(req.read_bytes())
                except Exception as exc:
                    body = {"_read_error": str(exc)}
                bridge = body.get("bridge") if isinstance(body, dict) else None
                out = {
                    "ok": True,
                    "log": f"file_bridge_echo auto ok (bridge={bridge!r})",
                }
                try:
                    resp.write_text(
                        json.dumps(out, ensure_ascii=False, indent=2),
                        encoding="utf-8",
                    )
                    print(f"+ {resp}")
                except OSError as exc:
                    print(f"! write failed {resp}: {exc}")
        time.sleep(POLL)


if __name__ == "__main__":
    main()
