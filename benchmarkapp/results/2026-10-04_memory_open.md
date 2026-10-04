# Memory when opening — OrcaSecureStorage 2.1.7 vs 2.1.8, macOS arm64

Release build, Apple Silicon Mac, [`lib/memory_main.dart`](../lib/memory_main.dart):
46,398 records of ~330 bytes (14.8 MB of JSON). Each storage was cleared in
its own process (`MEM_PHASE=clear`), then written and opened in fresh
processes. Two rounds per setup; ranges cover both. Memory is the resident
memory the storage added; UI stall is the longest time the UI isolate's
event loop was blocked (separate runs with `MEM_STALL=1`).

| | Orca 2.1.7 | Orca 2.1.8 | Hive CE (encrypted) |
|---|---:|---:|---:|
| Open: peak memory | 267–278 MB | 192–201 MB | 162 MB |
| Open: time (open + read all) | 276–355 ms | 214–278 ms | 448–471 ms |
| Open: longest UI stall | 4–6 ms | 4–6 ms | 3–5 ms |
| Write: peak memory | 129–141 MB | 124–145 MB | 87 MB |
| Write: time | 296–407 ms | 304–400 ms | 1675–1768 ms |
| Write: longest UI stall | 4–5 ms | 3–5 ms | 3–5 ms |

Orca covers all three variants (password, raw key, no password); they
differ by a few MB and, for opening with a password, the PBKDF2 time.

2.1.7 decoded the whole file into objects in its worker, copied them to the
UI isolate and then re-encoded each value into its cache. 2.1.8 cuts the
file into each key's JSON text without decoding it; a helper isolate
decodes the document once and moves the objects to the UI isolate with
`Isolate.exit`, without a copy.

**Correction:** the UI stall figures here are too low for storages that
block the UI until the end of a phase: a stall was only counted once the
next tick ran, and the run ended first. Hive's open blocks the UI for the
whole open (about 100 ms at 10,000 records, about 870 ms at 100,000); see
[2026-10-04_decode_on_read.md](2026-10-04_decode_on_read.md), measured with
the corrected meter.
