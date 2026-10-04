// Memory benchmark from the command line, one storage and phase per process
// (see runMemoryChild for the environment variables). Not on the web. The
// main app runs the same measurement from its UI.
//
// flutter build macos --release -t lib/memory_main.dart
// MEM_STORAGE='Hive CE' MEM_PHASE=clear <app binary>   # then write, then open
import 'bench/memory_io.dart';

Future<void> main() => runMemoryChild();
