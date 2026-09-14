#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../HelperProtocol.h"

static int failures = 0;
static int checks = 0;

static void MLMCheck(const char *name, bool condition) {
  checks++;
  if (condition)
    return;
  fprintf(stderr, "%s: failed\n", name);
  failures++;
}

/// Parses a copy, because the parser splits its input in place.
static bool MLMParse(const char *fixture, MLMHelperResult *result) {
  char *text = strdup(fixture);
  bool parsed = MLMParseHelperOutput(text, result);
  free(text);
  return parsed;
}

static void MLMExpect(const char *name, const char *fixture, bool expected) {
  MLMHelperResult *result = calloc(1, sizeof(*result));
  MLMCheck(name, MLMParse(fixture, result) == expected);
  free(result);
}

/// A fixture whose single field is `length` copies of 'x' inside `format`.
static char *MLMFieldOfLength(const char *format, size_t length) {
  char *field = malloc(length + 1);
  memset(field, 'x', length);
  field[length] = '\0';
  size_t capacity = strlen(format) + length + 1;
  char *fixture = malloc(capacity);
  snprintf(fixture, capacity, format, field);
  free(field);
  return fixture;
}

static void MLMExpectFieldLength(const char *name, const char *format,
                                 size_t length, bool expected) {
  char *fixture = MLMFieldOfLength(format, length);
  MLMExpect(name, fixture, expected);
  free(fixture);
}

static void MLMExpectLayoutCount(const char *name, unsigned count,
                                 bool expected) {
  size_t capacity = 64 + count * 32;
  char *fixture = malloc(capacity);
  int used = snprintf(fixture, capacity, "V\t1\nS\t%u\n", count);
  for (unsigned index = 0; index < count; index++) {
    used += snprintf(fixture + used, capacity - (size_t)used, "L\tL%u\t0\t\n",
                     index);
  }
  snprintf(fixture + used, capacity - (size_t)used, "D\n");
  MLMExpect(name, fixture, expected);
  free(fixture);
}

static void MLMExpectRun(const char *name, const char *const *argv,
                         bool expected) {
  MLMHelperResult *result = calloc(1, sizeof(*result));
  MLMCheck(name, MLMRunHelper(argv, result) == expected);
  free(result);
}

/// The whole file at `path`, NUL-terminated, or NULL.
static char *MLMReadFile(const char *path) {
  FILE *file = fopen(path, "rb");
  if (file == NULL)
    return NULL;
  char *text = calloc(MLMOutputCapacity, 1);
  size_t used = text == NULL ? 0 : fread(text, 1, MLMOutputCapacity - 1, file);
  bool complete = text != NULL && feof(file) && !ferror(file);
  fclose(file);
  if (!complete || used == 0) {
    free(text);
    return NULL;
  }
  return text;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: ProtocolTests <protocol-output.txt>\n");
    return 2;
  }
  // tests/LayoutCoreTests.swift asserts the helper emits exactly this file.
  char *fixture = MLMReadFile(argv[1]);
  MLMHelperResult *result = calloc(1, sizeof(*result));
  bool parsed = fixture != NULL && MLMParseHelperOutput(fixture, result);
  free(fixture);
  MLMCheck("shared fixture parses", parsed);
  MLMCheck("shared fixture library",
           result->hasLibrary && result->library.count == 2);
  MLMCheck("shared fixture first layout",
           strcmp(result->library.layouts[0].name, "Desk") == 0 &&
               result->library.layouts[0].autoRestore &&
               strcmp(result->library.layouts[0].displays,
                      "Built-in Retina Display + DELL U2720Q") == 0);
  MLMCheck("shared fixture second layout",
           strcmp(result->library.layouts[1].name, "Couch") == 0 &&
               !result->library.layouts[1].autoRestore &&
               strcmp(result->library.layouts[1].displays,
                      "Built-in Retina Display") == 0);
  MLMCheck("shared fixture message",
           strcmp(result->message, "A layout named “Desk” already exists.") ==
               0);

  memset(result, 0, sizeof(*result));
  MLMCheck(
      "load failure parses",
      MLMParse("V\t1\nE\tThe data isn't in the correct format.\nD\n", result) &&
          !result->hasLibrary &&
          strcmp(result->message, "The data isn't in the correct format.") ==
              0);

  memset(result, 0, sizeof(*result));
  strcpy(result->message, "untouched");
  MLMCheck("rejected output leaves the result untouched",
           !MLMParse("V\t1\nS\t1\nL\tDesk\t1\tA\n", result) &&
               strcmp(result->message, "untouched") == 0 &&
               !result->hasLibrary);
  free(result);

  MLMExpect("empty library", "V\t1\nS\t0\nD\n", true);
  MLMExpect("library with message", "V\t1\nS\t0\nE\tNo layout.\nD\n", true);
  MLMExpect("empty displays", "V\t1\nS\t1\nL\tDesk\t0\t\nD\n", true);

  MLMExpect("missing version", "S\t0\nD\n", false);
  MLMExpect("wrong version", "V\t2\nS\t0\nD\n", false);
  MLMExpect("version extra field", "V\t1\t1\nS\t0\nD\n", false);
  MLMExpect("repeated version", "V\t1\nV\t1\nS\t0\nD\n", false);
  MLMExpect("no library and no message", "V\t1\nD\n", false);
  MLMExpect("repeated summary", "V\t1\nS\t0\nS\t0\nD\n", false);
  MLMExpect("signed count", "V\t1\nS\t+1\nL\tDesk\t0\tA\nD\n", false);
  MLMExpect("negative count", "V\t1\nS\t-1\nD\n", false);
  MLMExpect("count garbage", "V\t1\nS\t1x\nL\tDesk\t0\tA\nD\n", false);
  MLMExpect("empty count", "V\t1\nS\t\nD\n", false);
  MLMExpect("summary missing count", "V\t1\nS\nD\n", false);
  MLMExpect("fewer layouts than count", "V\t1\nS\t2\nL\tDesk\t1\tA\nD\n",
            false);
  MLMExpect("more layouts than count",
            "V\t1\nS\t1\nL\tDesk\t1\tA\nL\tCouch\t0\tB\nD\n", false);
  MLMExpect("layout without summary", "V\t1\nL\tDesk\t1\tA\nE\tx\nD\n", false);
  MLMExpect("duplicate name", "V\t1\nS\t2\nL\tDesk\t1\tA\nL\tDesk\t0\tB\nD\n",
            false);
  MLMExpect("empty name", "V\t1\nS\t1\nL\t\t1\tA\nD\n", false);
  MLMExpect("invalid flag", "V\t1\nS\t1\nL\tDesk\t2\tA\nD\n", false);
  MLMExpect("empty flag", "V\t1\nS\t1\nL\tDesk\t\tA\nD\n", false);
  MLMExpect("layout missing field", "V\t1\nS\t1\nL\tDesk\t1\nD\n", false);
  MLMExpect("layout extra field", "V\t1\nS\t1\nL\tDesk\t1\tA\tB\nD\n", false);
  MLMExpect("empty message", "V\t1\nS\t0\nE\t\nD\n", false);
  MLMExpect("message extra field", "V\t1\nS\t0\nE\ta\tb\nD\n", false);
  MLMExpect("two messages", "V\t1\nE\ta\nE\tb\nD\n", false);
  MLMExpect("message before summary", "V\t1\nE\ta\nS\t0\nD\n", false);
  MLMExpect("message inside layouts",
            "V\t1\nS\t2\nL\tDesk\t1\tA\nE\ta\nL\tCouch\t0\tB\nD\n", false);
  MLMExpect("done with field", "V\t1\nS\t0\nD\t1\n", false);
  MLMExpect("record after done", "V\t1\nS\t0\nD\nE\tlate\n", false);
  MLMExpect("blank line after done", "V\t1\nS\t0\nD\n\n", false);
  MLMExpect("version only", "V\t1", false);
  MLMExpect("missing done", "V\t1\nS\t0\n", false);
  MLMExpect("done without newline", "V\t1\nS\t0\nD", false);
  MLMExpect("unknown record", "V\t1\nS\t0\nX\t1\nD\n", false);
  MLMExpect("blank line inside", "V\t1\n\nS\t0\nD\n", false);
  MLMExpect("empty output", "", false);
  MLMExpect("invalid UTF-8", "V\t1\nS\t1\nL\tDesk\xff\t0\t\nD\n", false);

  MLMExpectLayoutCount("maximum layouts", MLMMaxLayouts, true);
  MLMExpectLayoutCount("too many layouts", MLMMaxLayouts + 1, false);
  MLMExpectFieldLength("longest name", "V\t1\nS\t1\nL\t%s\t0\t\nD\n",
                       MLMNameCapacity - 1, true);
  MLMExpectFieldLength("name too long", "V\t1\nS\t1\nL\t%s\t0\t\nD\n",
                       MLMNameCapacity, false);
  MLMExpectFieldLength("longest displays", "V\t1\nS\t1\nL\tDesk\t0\t%s\nD\n",
                       MLMDisplaysCapacity - 1, true);
  MLMExpectFieldLength("displays too long", "V\t1\nS\t1\nL\tDesk\t0\t%s\nD\n",
                       MLMDisplaysCapacity, false);
  MLMExpectFieldLength("longest message", "V\t1\nE\t%s\nD\n",
                       MLMMessageCapacity - 1, true);
  MLMExpectFieldLength("message too long", "V\t1\nE\t%s\nD\n",
                       MLMMessageCapacity, false);

  // printf and sh stand in for the helper, so these need no extra files.
  const char *const valid[] = {"/usr/bin/printf", "V\\t1\\nS\\t0\\nD\\n", NULL};
  MLMExpectRun("run parses output", valid, true);
  const char *const falseExit[] = {"/usr/bin/false", NULL};
  MLMExpectRun("run fails on nonzero exit", falseExit, false);
  const char *const missing[] = {"/nonexistent/helper", NULL};
  MLMExpectRun("run fails on missing helper", missing, false);
  const char *const exitCode[] = {
      "/bin/sh", "-c", "printf 'V\\t1\\nS\\t0\\nD\\n'; exit 3", NULL};
  MLMExpectRun("run fails on valid output with nonzero exit", exitCode, false);
  const char *const embeddedNul[] = {"/usr/bin/printf",
                                     "V\\t1\\nS\\t0\\nD\\n\\000x", NULL};
  MLMExpectRun("run rejects embedded NUL", embeddedNul, false);
  const char *const oversized[] = {
      "/bin/sh", "-c",
      "printf 'V\\t1\\nE\\t'; head -c 70000 /dev/zero | tr '\\000' x; "
      "printf '\\nD\\n'",
      NULL};
  MLMExpectRun("run rejects oversized output", oversized, false);

  if (failures != 0) {
    fprintf(stderr, "ProtocolTests: %d of %d checks failed\n", failures,
            checks);
    return 1;
  }
  printf("ProtocolTests: %d checks passed\n", checks);
  return 0;
}
