"""Reproducible synthetic SQLite search benchmark for 10k/100k/300k entries."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import random
import sqlite3
import statistics
import tempfile
import time

from packages.search_engine import SearchEngine
from tools.database_builder.builder import SCHEMA_SQL


def _entry_rows(start: int, end: int):
    for index in range(start, end):
        entry_id = f"synthetic_{index:06d}"
        headword = f"模擬語{index:06d}"
        payload = json.dumps(
            {"entry_id": entry_id, "headword": headword, "frequency_rank": index + 1},
            ensure_ascii=False, sort_keys=True, separators=(",", ":"),
        )
        yield (entry_id, headword, index + 1, payload, "imported", "imported",
               "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z", "benchmark")


def build_synthetic_database(path: Path, size: int) -> float:
    if size < 1:
        raise ValueError("size must be positive")
    if path.exists():
        path.unlink()
    start_time = time.perf_counter()
    connection = sqlite3.connect(path)
    connection.executescript(SCHEMA_SQL)
    connection.execute("PRAGMA synchronous = OFF")
    connection.execute("INSERT INTO parts_of_speech VALUES ('noun')")
    batch_size = 5_000
    with connection:
        for start in range(0, size, batch_size):
            end = min(start + batch_size, size)
            connection.executemany("INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", _entry_rows(start, end))
            readings = []
            entry_pos = []
            senses = []
            definitions = []
            keys = []
            for index in range(start, end):
                entry_id = f"synthetic_{index:06d}"
                headword = f"模擬語{index:06d}"
                reading = f"もぎご{index:06d}"
                sense_id = f"{entry_id}:sense"
                readings.append((f"{entry_id}:reading", entry_id, reading, reading, 1))
                entry_pos.append((entry_id, "noun", 1))
                senses.append((sense_id, entry_id, 1, "", "neutral", "primary", "imported"))
                definitions.append((f"{sense_id}:definition", sense_id, "ja-simple", f"性能測定用の語{index}。"))
                keys.append((f"{entry_id}:key:primary", entry_id, headword, headword, headword, "primary", 1))
                keys.append((f"{entry_id}:key:reading", entry_id, reading, reading, reading, "reading", 1))
            connection.executemany("INSERT INTO readings VALUES (?, ?, ?, ?, ?)", readings)
            connection.executemany("INSERT INTO entry_parts_of_speech VALUES (?, ?, ?)", entry_pos)
            connection.executemany("INSERT INTO senses VALUES (?, ?, ?, ?, ?, ?, ?)", senses)
            connection.executemany("INSERT INTO definitions VALUES (?, ?, ?, ?)", definitions)
            connection.executemany("INSERT INTO search_keys VALUES (?, ?, ?, ?, ?, ?, ?)", keys)
    connection.execute("ANALYZE")
    connection.close()
    return time.perf_counter() - start_time


def run_benchmark(path: Path, size: int, *, seed: int, queries: int) -> dict[str, object]:
    rng = random.Random(seed)
    query_values: list[str] = []
    for _ in range(queries):
        draw = rng.random()
        index = rng.randrange(size)
        if draw < 0.58:
            query_values.append(f"模擬語{index:06d}")
        elif draw < 0.83:
            query_values.append(f"もぎご{index:06d}")
        elif draw < 0.98:
            prefix_digits = max(1, len(str(size - 1)) - 2)
            query_values.append("模擬語" + f"{index:06d}"[:prefix_digits])
        else:
            query_values.append(f"不存在{index:06d}")
    latencies: list[float] = []
    hit_count = 0
    with SearchEngine(path) as engine:
        for value in query_values[: min(20, queries)]:
            engine.search(value, limit=20)
        for value in query_values:
            started = time.perf_counter()
            results = engine.search(value, limit=20)
            latencies.append((time.perf_counter() - started) * 1000)
            hit_count += bool(results)
    ordered = sorted(latencies)
    p95_index = max(0, min(len(ordered) - 1, int(0.95 * len(ordered) + 0.999999) - 1))
    return {
        "size": size,
        "seed": seed,
        "query_count": queries,
        "hit_count": hit_count,
        "p50_ms": round(statistics.median(latencies), 3),
        "p95_ms": round(ordered[p95_index], 3),
        "max_ms": round(max(latencies), 3),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", type=int, choices=(10_000, 100_000, 300_000), default=10_000)
    parser.add_argument("--seed", type=int, default=20260722)
    parser.add_argument("--queries", type=int, default=200)
    parser.add_argument("--database", type=Path, help="keep/reuse this generated database path")
    parser.add_argument("--reuse", action="store_true", help="do not rebuild --database")
    args = parser.parse_args(argv)
    if args.queries < 1:
        parser.error("--queries must be positive")
    temporary = None
    if args.database:
        database = args.database.resolve()
        database.parent.mkdir(parents=True, exist_ok=True)
    else:
        temporary = tempfile.TemporaryDirectory(prefix="kotoba-benchmark-")
        database = Path(temporary.name) / "dictionary.sqlite"
    build_seconds = 0.0
    if not args.reuse or not database.exists():
        build_seconds = build_synthetic_database(database, args.size)
    result = run_benchmark(database, args.size, seed=args.seed, queries=args.queries)
    result["build_seconds"] = round(build_seconds, 3)
    result["database_bytes"] = database.stat().st_size
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    if temporary:
        temporary.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
