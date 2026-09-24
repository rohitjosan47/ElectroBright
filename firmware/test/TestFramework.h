#pragma once
// Minimal self-registering test framework (no external dependencies).

#include <math.h>
#include <stdio.h>
#include <string.h>

#include <functional>
#include <string>
#include <vector>

namespace tf {

struct TestCase {
  const char* name;
  void (*fn)();
};

inline std::vector<TestCase>& registry() {
  static std::vector<TestCase> r;
  return r;
}

inline int& failures() {
  static int f = 0;
  return f;
}

struct Registrar {
  Registrar(const char* name, void (*fn)()) { registry().push_back({name, fn}); }
};

inline void fail(const char* file, int line, const std::string& msg) {
  ++failures();
  printf("    FAIL %s:%d: %s\n", file, line, msg.c_str());
}

}  // namespace tf

#define TEST(name)                                           \
  static void name();                                        \
  static tf::Registrar reg_##name(#name, name);              \
  static void name()

#define CHECK(cond)                                                     \
  do {                                                                  \
    if (!(cond)) tf::fail(__FILE__, __LINE__, "CHECK(" #cond ")");      \
  } while (0)

#define CHECK_EQ(a, b)                                                                           \
  do {                                                                                           \
    const auto va_ = (a);                                                                        \
    const auto vb_ = (b);                                                                        \
    if (!(va_ == vb_))                                                                           \
      tf::fail(__FILE__, __LINE__,                                                               \
               std::string("CHECK_EQ(" #a ", " #b ") got ") + std::to_string(va_) + " vs " +     \
                   std::to_string(vb_));                                                         \
  } while (0)

#define CHECK_STR(a, b)                                                                                 \
  do {                                                                                                  \
    const std::string sa_ = (a);                                                                        \
    const std::string sb_ = (b);                                                                        \
    if (sa_ != sb_) tf::fail(__FILE__, __LINE__, "CHECK_STR got \"" + sa_ + "\" expected \"" + sb_ + "\""); \
  } while (0)

#define CHECK_NEAR(a, b, tol)                                                                          \
  do {                                                                                                 \
    const double va_ = (a);                                                                            \
    const double vb_ = (b);                                                                            \
    if (!(fabs(va_ - vb_) <= (tol)))                                                                   \
      tf::fail(__FILE__, __LINE__,                                                                     \
               std::string("CHECK_NEAR(" #a ", " #b ") got ") + std::to_string(va_) + " vs " +         \
                   std::to_string(vb_) + " tol " + std::to_string(tol));                               \
  } while (0)
