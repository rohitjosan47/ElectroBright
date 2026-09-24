#pragma once
// Every fixture profile in firmware/fixtures/, for tests that run per fixture
// and for fwsim's --fixture option.

#include <string.h>

#include "ElectroBright_RGB/Fixture.h"
#include "ElectroBright_RGBW/Fixture.h"

struct NamedFixture {
  const char* name;  // --fixture value
  const FixtureProfile* profile;
};

inline constexpr NamedFixture kAllFixtures[] = {
    {"rgbw", &fx::rgbw::kProfile},
    {"rgb", &fx::rgb::kProfile},
};

inline const FixtureProfile* findFixture(const char* name) {
  for (const NamedFixture& f : kAllFixtures) {
    if (strcmp(f.name, name) == 0) return f.profile;
  }
  return nullptr;
}
