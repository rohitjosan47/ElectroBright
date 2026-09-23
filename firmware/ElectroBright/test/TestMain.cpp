#include "TestFramework.h"

int main(int argc, char** argv) {
  const char* filter = argc > 1 ? argv[1] : nullptr;
  int run = 0;
  for (const auto& t : tf::registry()) {
    if (filter && !strstr(t.name, filter)) continue;
    const int before = tf::failures();
    t.fn();
    ++run;
    printf("%s %s\n", tf::failures() == before ? "  ok  " : "  FAIL", t.name);
  }
  printf("\n%d tests, %d failed checks\n", run, tf::failures());
  return tf::failures() == 0 ? 0 : 1;
}
