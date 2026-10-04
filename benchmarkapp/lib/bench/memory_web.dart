// The memory benchmark needs child processes, which the web does not have.
import 'memory.dart';

bool get memorySupported => false;

bool get isMemoryChild => false;

Future<MemoryResult?> runMemoryPhase(
  String storage,
  String phase,
  int entries, {
  Duration timeout = const Duration(seconds: 30),
}) => throw UnsupportedError('memory benchmark: desktop only');

Future<void> runMemoryChild() =>
    throw UnsupportedError('memory benchmark: desktop only');
