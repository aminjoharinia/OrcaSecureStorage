/// How far a save goes before it counts as saved (`flush()` completes).
/// Only affects files (not the web, where the browser decides).
enum Durability {
  /// Every save is fsynced: it survives an app crash, an OS crash and a
  /// power loss (as far as the device honours fsync). The default.
  fsync,

  /// Changes appended to the change log are handed to the OS without
  /// fsync. They survive an app crash, but an OS crash or power loss can
  /// lose the most recent saves. Snapshots are still fsynced and replaced
  /// atomically, so the container is never left damaged: at worst it goes
  /// back to an earlier state. Saves cost less where fsync is slow (often
  /// on phones).
  os,
}
