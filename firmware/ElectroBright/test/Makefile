# Host-side unit + simulation tests for the portable firmware core.
#   make            build and run all tests, then build fwsim
#   make run T=club run only tests whose name contains "club"
#   make portable   verify portable sources never include Arduino / ESP-IDF headers
#   make fwsim      build build/fwsim/fwsim: the real core behind a stdin/stdout
#                   protocol, used by the app's firmware-in-the-loop tests

.DEFAULT_GOAL := all   # the -include of *.d files below must not change the default target

CXX      ?= c++
SRC_DIR  := ../src
BUILD    := build
CXXFLAGS := -std=c++17 -O1 -g -Wall -Wextra -Werror -Wshadow -Wconversion -Wno-sign-conversion \
            -Wno-float-conversion -Wno-implicit-int-float-conversion -fno-omit-frame-pointer -MMD -MP
SAN      := -fsanitize=address,undefined -fno-sanitize-recover=undefined

# Everything except the platform layer is portable.
PORTABLE_SRCS := $(shell find $(SRC_DIR) -name '*.cpp' -not -path '*/platform/*')
TEST_SRCS     := $(wildcard *.cpp)
PORTABLE_OBJS := $(patsubst $(SRC_DIR)/%.cpp,$(BUILD)/src/%.o,$(PORTABLE_SRCS))
FWSIM_OBJ  := $(BUILD)/fwsim/SimDevice.o
FWSIM_MAIN := $(BUILD)/fwsim/main.o
OBJS := $(PORTABLE_OBJS) $(patsubst %.cpp,$(BUILD)/test/%.o,$(TEST_SRCS)) $(FWSIM_OBJ)

DEPS := $(OBJS:.o=.d) $(FWSIM_MAIN:.o=.d)
-include $(DEPS)

.PHONY: all run clean portable fwsim

all: portable run fwsim

$(BUILD)/src/%.o: $(SRC_DIR)/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(SAN) -c $< -o $@

$(BUILD)/test/%.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(SAN) -c $< -o $@

$(BUILD)/fwsim/%.o: fwsim/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(SAN) -c $< -o $@

$(BUILD)/tests: $(OBJS)
	$(CXX) $(SAN) $^ -o $@

$(BUILD)/fwsim/fwsim: $(PORTABLE_OBJS) $(FWSIM_OBJ) $(FWSIM_MAIN)
	$(CXX) $(SAN) $^ -o $@

fwsim: $(BUILD)/fwsim/fwsim

run: $(BUILD)/tests
	./$(BUILD)/tests $(T)

portable:
	@! grep -rnE '#include *[<"](Arduino|esp_|freertos|driver/|nvs|NimBLE)' \
	    $(shell find $(SRC_DIR) -name '*.h' -o -name '*.cpp' | grep -v /platform/) \
	  || (echo "portable code must not include platform headers" && false)
	@echo "portable-core check passed"

clean:
	rm -rf $(BUILD)
