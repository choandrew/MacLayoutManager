#ifndef MLM_HELPER_PROTOCOL_H
#define MLM_HELPER_PROTOCOL_H

#include <stdbool.h>
#include <stdint.h>

/// The host keeps every layout it knows about in these fixed-size records, so a
/// resident process holds no Swift, JSON, or Accessibility state. The Swift
/// helper imports this header, so each limit below has one source.
enum {
  MLMMaxLayouts = 64,
  /// Capacities count the terminating NUL.
  MLMNameCapacity = 128,
  MLMDisplaysCapacity = 256,
  MLMMessageCapacity = 512,
  /// Room for the largest valid output; `HelperProtocol.m` asserts it fits.
  MLMOutputCapacity = 64 * 1024,
  /// Ten argv entries describe one display: UUID, name, frame x y width
  /// height, visible frame x y width height, all in Accessibility coordinates
  /// (origin at the main display's top-left, y down). The main display comes
  /// first.
  MLMDisplayArgumentCount = 10,
};

/// Helper verbs, after the executable path:
///
///   list
///   add <name> <display>...
///   replace <name> <display>...
///   restore <name> <display>...
///   auto-restore <display>...
///   rename <name> <new-name>
///   set-auto-restore <name> <0|1>
///   delete <name>
#define MLMVerbList "list"
#define MLMVerbAdd "add"
#define MLMVerbReplace "replace"
#define MLMVerbRestore "restore"
#define MLMVerbAutoRestore "auto-restore"
#define MLMVerbRename "rename"
#define MLMVerbSetAutoRestore "set-auto-restore"
#define MLMVerbDelete "delete"

#pragma clang assume_nonnull begin

typedef struct {
  char name[MLMNameCapacity];
  /// Display names joined with " + ", for the menu subtitle only.
  char displays[MLMDisplaysCapacity];
  bool autoRestore;
} MLMLayoutSummary;

typedef struct {
  MLMLayoutSummary layouts[MLMMaxLayouts];
  uint8_t count;
} MLMLibrary;

/// One helper run. `hasLibrary` is false only when the helper could not load
/// the layouts file, and then `message` says why. A non-empty `message` next to
/// a library is a failure of the command itself, such as a duplicate name.
typedef struct {
  bool hasLibrary;
  MLMLibrary library;
  char message[MLMMessageCapacity];
} MLMHelperResult;

/// The helper exits 2 on malformed argv and 0 once it has written complete
/// output; any other exit means the run failed. Output is UTF-8 lines of
/// tab-separated fields, in this order, with nothing after `D`:
///
///   V <1>
///   S <count>                          present iff the library loaded
///   L <name> <0|1> <displays>          exactly <count> lines, after S
///   E <message>                        at most one; required without S
///   D
///
/// No field contains a tab, CR, LF, or NUL.
bool MLMParseHelperOutput(char *text, MLMHelperResult *result);

/// Spawns `argv[0]` with `argv` (NULL-terminated), reads at most
/// `MLMOutputCapacity` bytes of output, and parses it. Blocks, so call it off
/// the main thread.
bool MLMRunHelper(const char *_Nullable const *_Nonnull argv,
                  MLMHelperResult *result);

#pragma clang assume_nonnull end

#endif
