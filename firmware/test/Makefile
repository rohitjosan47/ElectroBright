# Host-side unit + simulation tests for the shared firmware core (core/ElectroBrightCore)
# and the fixture profiles (fixtures/*/Fixture.h).
#   make            build and run all tests, then build fwsim
#   make run T=club run only tests whose name contains "club"
#   make portable   verify portable sources never include Arduino / ESP-IDF headers
#   make fwsim      build build/fwsim/fwsim: the real core behind a stdin/stdout
#                   protocol, used by the app's firmware-in-the-loop tests
#   make conformance   run tools/fw_conformance.py against fwsim for every fixture
#   make golden-record re-record golden/rgbw.golden (only for intended RGBW changes)

.DEFAULT_GOAL := all   # the -include of *.d files below must not change the default target

CXX      ?= c++
SRC_DIR  := ../core/ElectroBrightCore/src
BUILD    := build
CXXFLAGS := -std=c++17 -O1 -g -Wall -Wextra -Werror -Wshadow -Wconversion -Wno-sign-conversion \
            -Wno-float-conversion -Wno-implicit-int-float-conversion -fno-omit-frame-pointer -ffp-contract=off -MMD -MP \
            -I$(SRC_DIR) -I../fixtures
SAN      := -fsanitize=address,undefined -fno-sanitize-recover=undefined

# Everything except the platform layer is portable.
PORTABLE_SRCS := $(shell find $(SRC_DIR) -name '*.cpp' -not -path '*/platform/*')
TEST_SRCS     := $(wildcard *.cpp) $(wildcard golden/*.cpp)
PORTABLE_OBJS := $(patsubst $(SRC_DIR)/%.cpp,$(BUILD)/src/%.o,$(PORTABLE_SRCS))
FWSIM_OBJ  := $(BUILD)/fwsim/SimDevice.o
FWSIM_MAIN := $(BUILD)/fwsim/main.o
OBJS := $(PORTABLE_OBJS) $(patsubst %.cpp,$(BUILD)/test/%.o,$(TEST_SRCS)) $(FWSIM_OBJ)

DEPS := $(OBJS:.o=.d) $(FWSIM_MAIN:.o=.d)
-include $(DEPS)

.PHONY: all run clean portable fwsim golden-record conformance

all: portable run fwsim

$(BUILD)/src/%.o: $(SRC_DIR)/%.cpp
	@mkdir -p $(dir $@)
	@echo "  CXX $<"
	@$(CXX) $(CXXFLAGS) $(SAN) -c $< -o $@

$(BUILD)/test/%.o: %.cpp
	@mkdir -p $(dir $@)
	@echo "  CXX $<"
	@$(CXX) $(CXXFLAGS) $(SAN) -c $< -o $@

$(BUILD)/fwsim/%.o: fwsim/%.cpp
	@mkdir -p $(dir $@)
	@echo "  CXX $<"
	@$(CXX) $(CXXFLAGS) $(SAN) -c $< -o $@

$(BUILD)/tests: $(OBJS)
	@echo "  LD  $@"
	@$(CXX) $(SAN) $^ -o $@

$(BUILD)/fwsim/fwsim: $(PORTABLE_OBJS) $(FWSIM_OBJ) $(FWSIM_MAIN)
	@echo "  LD  $@"
	@$(CXX) $(SAN) $^ -o $@

fwsim: $(BUILD)/fwsim/fwsim

run: $(BUILD)/tests
	./$(BUILD)/tests $(T)

# Re-records golden/rgbw.golden. Only when an RGBW behaviour change is intended.
golden-record: $(BUILD)/tests
	GOLDEN_RECORD=1 ./$(BUILD)/tests golden_

FIXTURES := rgbw rgb

conformance: $(BUILD)/fwsim/fwsim
	@for f in $(FIXTURES); do \
	  echo "== conformance: $$f"; \
	  out=$$(python3 ../tools/fw_conformance.py --fwsim $(BUILD)/fwsim/fwsim --fixture $$f --stress 3 --factory-reset); \
	  rc=$$?; echo "$$out" | grep -E "FAIL|passed"; [ $$rc -eq 0 ] || exit 1; \
	done

portable:
	@! grep -rnE '#include *[<"](Arduino|esp_|freertos|driver/|nvs|NimBLE)' \
	    $(shell find $(SRC_DIR) -name '*.h' -o -name '*.cpp' | grep -v /platform/) \
	  || (echo "portable code must not include platform headers" && false)
	@echo "portable-core check passed"

clean:
	rm -rf $(BUILD)
