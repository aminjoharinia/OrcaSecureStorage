# Opening a container: decode on first read (2.3.0) vs 2.2.1 vs Hive — macOS arm64

Release build, Apple Silicon Mac, [`lib/bench/memory_io.dart`](../lib/bench/memory_io.dart)
(`MEM_PHASE=open`, `MEM_STALL=1`): each storage opens data written by an
earlier process, as on an app start, then reads every record (yielding to
the event loop every 50 reads). Records are ~330 bytes of JSON. The rounds
alternated between the builds; each figure is the median, stalls show the
range. Memory is the resident memory the storage added.

"UI stall" is the longest time the UI isolate's event loop was blocked. A
stall still in progress at the end of opening counts too (earlier runs only
counted a stall once the next tick ran, which hid stalls that lasted until
the end of a phase, such as Hive's whole open).

## 100,000 records (32.3 MB of JSON), 6 rounds

| | Orca 2.2.1 | Orca 2.3.0 | Hive CE (encrypted) |
|---|---:|---:|---:|
| UI stall while opening | 14–23 ms | 5–6 ms | 869–891 ms |
| UI stall while reading every record | 1–7 ms | 4–5 ms | 1–2 ms |
| Open time | 445 ms | 267 ms | 899 ms |
| Memory right after opening | 403 MB | 190 MB | 313 MB |
| First read of a record | 12 µs | 10 µs | 7 µs |
| Memory after reading every record | 410 MB | 330 MB | 318 MB |

## 10,000 records (3.2 MB of JSON), 4 rounds

| | Orca 2.2.1 | Orca 2.3.0 | Hive CE (encrypted) |
|---|---:|---:|---:|
| UI stall while opening | 5–6 ms | 5–6 ms | 102–104 ms |
| Open time | 66 ms | 48 ms | 114 ms |
| Memory right after opening | 50 MB | 25 MB | 42 MB |
| Memory after reading every record | 50 MB | 48 MB | 44 MB |

## 15 MB of JSON (46,398 records), Orca 2.3.0, 2 rounds

After writing: 139–140 MB. Right after opening: 99–116 MB. After reading
every record: 158 MB (2.2.1: about 197 MB after opening).

The 5–6 ms left when opening is the platform call that finds the documents
folder (`getApplicationDocumentsDirectory`), which runs on the macOS main
thread; Hive makes the same call. Hive decodes the whole box on the UI
isolate when it opens, so the UI is blocked for the whole open.

2.2.1 decoded every value when opening, in a helper isolate: about a
million objects created in a burst, whose garbage collection paused the UI
isolate too (isolates share a heap). 2.3.0 hands the UI isolate each value's
JSON text and decodes a value when it is first read.
