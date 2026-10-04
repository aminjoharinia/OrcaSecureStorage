# Memory after writing: objects vs text (2.4.0) vs Hive — macOS arm64

Release build, Apple Silicon Mac, [`lib/bench/memory_io.dart`](../lib/bench/memory_io.dart)
(`MEM_PHASE=write`): each run clears the store in its own process, then
writes the records (~330 bytes of JSON each) in a fresh process, waits until
saved, and reports the memory the storage added (held two seconds later,
and at its highest). Medians of 3 interleaved rounds.

- **objects**: `write` one by one, default (`keepWrittenObjects: true`).
- **option off**: `write` one by one with `keepWrittenObjects: false`
  (measured through a temporary benchmark row, "OrcaSecureStorage (key,
  text values)").
- **writeAll**: `writeAll` with 1,000 records per call (`MEM_BATCH=1000`).

| Records (JSON) | objects | option off | writeAll | Hive CE (encrypted) |
|---|---:|---:|---:|---:|
| 500 (0.2 MB) | 6 MB | 6 MB | 6 MB | 6 MB |
| 1,000 (0.3 MB) | 9 MB | 7 MB | 8 MB | 7 MB |
| 5,000 (1.6 MB) | 30 MB | 22 MB | 24 MB | 15 MB |
| 10,000 (3.2 MB) | 44 MB | 31 MB | 33 MB | 24 MB |
| 100,000 (32 MB) | 277 MB | 113 MB | 115 MB | 182 MB |

Peak while writing 100,000: 277 / 114 / 116 / 182 MB. Write time at
100,000: 724 / 617 / 580 / 3,463 ms; at 10,000: 99 / 94 / 84 / 364 ms.
Longest UI stall while writing: 4–5 ms, except writeAll 8–9 ms (each call
encodes its 1,000 records on the UI thread).

Opening the data again in a new process is the same for all three Orca
modes (100,000: about 188 MB right after opening, about 330 MB after
reading every record), since values are always decoded when first read
after opening.
