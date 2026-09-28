#pragma once
// Every fixture type of the profile table (core fixture/Profiles.h), for tests
// that run per type and for fwsim's --fixture option.

#include <string.h>

#include "fixture/Profiles.h"

struct NamedFixture {
  const char* name;  // --fixture value
  const FixtureProfile* profile;
};

inline constexpr NamedFixture kAllFixtures[] = {
    {"rgbw", &profiles::kRgbw},
    {"rgb", &profiles::kRgb},
    {"rgbcct", &profiles::kRgbcct},
    {"cct", &profiles::kCct},
    {"w", &profiles::kW},
};

inline const FixtureProfile* findFixture(const char* name) {
  for (const NamedFixture& f : kAllFixtures) {
    if (strcmp(f.name, name) == 0) return f.profile;
  }
  return nullptr;
}
