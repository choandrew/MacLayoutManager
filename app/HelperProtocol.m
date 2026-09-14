#include "HelperProtocol.h"

#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

/// The most fields any record carries: `L`, name, flag, displays.
enum { MLMMaxFields = 4 };

/// V, S, every layout at capacity (type, three separators, flag, newline), a
/// message at capacity, and D.
_Static_assert(MLMOutputCapacity >
                   4 + 5 +
                       MLMMaxLayouts *
                           (MLMNameCapacity + MLMDisplaysCapacity + 5) +
                       2 + MLMMessageCapacity + 2,
               "the largest valid helper output must fit");

typedef enum {
  /// Nothing read yet: only `V`.
  MLMStageVersion,
  /// After `V`: `S`, `E`, or `D`.
  MLMStageLibrary,
  /// Inside the `S` block, with `L` records still owed.
  MLMStageLayouts,
  /// After the layouts: `E` or `D`.
  MLMStageMessage,
  /// After `E`: only `D`.
  MLMStageDone,
} MLMStage;

static bool MLMCopy(char *destination, size_t capacity, const char *source) {
  return strlcpy(destination, source, capacity) < capacity;
}

static bool MLMValidUTF8(const char *text) {
  CFStringRef string = CFStringCreateWithBytesNoCopy(
      NULL, (const UInt8 *)text, (CFIndex)strlen(text), kCFStringEncodingUTF8,
      false, kCFAllocatorNull);
  if (string == NULL)
    return false;
  CFRelease(string);
  return true;
}

/// Splits `line` on tabs in place. Returns the field count, or `capacity + 1`
/// when the line has more fields than `fields` holds.
static size_t MLMFields(char *line, char **fields, size_t capacity) {
  size_t count = 0;
  char *cursor = line;
  while (count < capacity) {
    fields[count++] = strsep(&cursor, "\t");
    if (cursor == NULL)
      break;
  }
  return cursor == NULL ? count : capacity + 1;
}

static bool MLMCount(const char *text, uint8_t *value) {
  if (text[0] == '\0')
    return false;
  unsigned parsed = 0;
  for (const char *digit = text; *digit != '\0'; digit++) {
    if (*digit < '0' || *digit > '9')
      return false;
    parsed = parsed * 10 + (unsigned)(*digit - '0');
    if (parsed > MLMMaxLayouts)
      return false;
  }
  *value = (uint8_t)parsed;
  return true;
}

static bool MLMFlag(const char *text, bool *value) {
  if (strcmp(text, "0") == 0) {
    *value = false;
  } else if (strcmp(text, "1") == 0) {
    *value = true;
  } else {
    return false;
  }
  return true;
}

bool MLMParseHelperOutput(char *text, MLMHelperResult *result) {
  // Checked once here, so every string the host builds from a record exists.
  if (!MLMValidUTF8(text))
    return false;
  MLMHelperResult parsed = {0};
  MLMStage stage = MLMStageVersion;
  uint8_t remaining = 0;
  char *lines = text;
  char *line = NULL;

  while ((line = strsep(&lines, "\n")) != NULL) {
    char *fields[MLMMaxFields];
    size_t count = MLMFields(line, fields, MLMMaxFields);
    const char *type = fields[0];

    if (strcmp(type, "V") == 0) {
      if (stage != MLMStageVersion || count != 2 || strcmp(fields[1], "1") != 0)
        return false;
      stage = MLMStageLibrary;
    } else if (strcmp(type, "S") == 0) {
      if (stage != MLMStageLibrary || count != 2 ||
          !MLMCount(fields[1], &remaining)) {
        return false;
      }
      parsed.hasLibrary = true;
      stage = remaining == 0 ? MLMStageMessage : MLMStageLayouts;
    } else if (strcmp(type, "L") == 0) {
      if (stage != MLMStageLayouts || count != 4 || fields[1][0] == '\0')
        return false;
      MLMLayoutSummary *layout = &parsed.library.layouts[parsed.library.count];
      if (!MLMCopy(layout->name, sizeof(layout->name), fields[1]) ||
          !MLMFlag(fields[2], &layout->autoRestore) ||
          !MLMCopy(layout->displays, sizeof(layout->displays), fields[3])) {
        return false;
      }
      for (uint8_t index = 0; index < parsed.library.count; index++) {
        if (strcmp(parsed.library.layouts[index].name, layout->name) == 0)
          return false;
      }
      parsed.library.count++;
      if (--remaining == 0)
        stage = MLMStageMessage;
    } else if (strcmp(type, "E") == 0) {
      if ((stage != MLMStageLibrary && stage != MLMStageMessage) ||
          count != 2 || fields[1][0] == '\0' ||
          !MLMCopy(parsed.message, sizeof(parsed.message), fields[1])) {
        return false;
      }
      stage = MLMStageDone;
    } else if (strcmp(type, "D") == 0) {
      // A run that loaded no library has to say why. Only the empty token
      // after D's own newline may follow it.
      if ((stage != MLMStageLibrary && stage != MLMStageMessage &&
           stage != MLMStageDone) ||
          count != 1 || (!parsed.hasLibrary && parsed.message[0] == '\0') ||
          lines == NULL || lines[0] != '\0') {
        return false;
      }
      *result = parsed;
      return true;
    } else {
      return false;
    }
  }
  return false;
}

bool MLMRunHelper(const char *_Nullable const *_Nonnull argv,
                  MLMHelperResult *result) {
  char *output = mmap(NULL, MLMOutputCapacity, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANON, -1, 0);
  if (output == MAP_FAILED)
    return false;

  int descriptors[2];
  // Close-on-exec keeps both ends out of the helper; dup2 gives its stdout a
  // copy without the flag.
  if (pipe(descriptors) != 0) {
    munmap(output, MLMOutputCapacity);
    return false;
  }
  posix_spawn_file_actions_t actions = NULL;
  if (fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) != 0 ||
      fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) != 0 ||
      posix_spawn_file_actions_init(&actions) != 0) {
    close(descriptors[0]);
    close(descriptors[1]);
    munmap(output, MLMOutputCapacity);
    return false;
  }
  pid_t process = 0;
  int spawnStatus =
      posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
  if (spawnStatus == 0) {
    spawnStatus = posix_spawn(&process, argv[0], &actions, NULL,
                              (char *const *)argv, environ);
  }
  posix_spawn_file_actions_destroy(&actions);
  close(descriptors[1]);
  if (spawnStatus != 0) {
    close(descriptors[0]);
    munmap(output, MLMOutputCapacity);
    return false;
  }

  // Output that fills the buffer is already invalid, so reading stops there
  // and closing the pipe ends a helper still writing.
  size_t used = 0;
  bool failed = false;
  for (;;) {
    if (used + 1 >= MLMOutputCapacity) {
      failed = true;
      break;
    }
    ssize_t count =
        read(descriptors[0], output + used, MLMOutputCapacity - used - 1);
    if (count > 0) {
      used += (size_t)count;
    } else if (count < 0 && errno == EINTR) {
      continue;
    } else {
      failed = count < 0;
      break;
    }
  }
  close(descriptors[0]);
  output[used] = '\0';

  int processStatus = 0;
  pid_t waited = 0;
  do {
    waited = waitpid(process, &processStatus, 0);
  } while (waited < 0 && errno == EINTR);
  // A NUL inside the output would end the parse early and hide what follows.
  bool success = !failed && memchr(output, '\0', used) == NULL &&
                 waited == process && WIFEXITED(processStatus) &&
                 WEXITSTATUS(processStatus) == 0 &&
                 MLMParseHelperOutput(output, result);
  munmap(output, MLMOutputCapacity);
  return success;
}
