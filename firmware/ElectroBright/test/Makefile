# Host-side unit + simulation tests for the portable firmware core.
#   make            build and run all tests
#   make run T=club run only tests whose name contains "club"
#   make portable   verify portable sources never include Arduino / ESP-IDF headers

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
OBJS := $(patsubst $(SRC_DIR)/%.cpp,$(BUILD)/src/%.o,$(PORTABLE_SRCS)) \
        $(patsubst %.cpp,$(BUILD)/test/%.o,$(TEST_SRCS))

DEPS := $(OBJS:.o=.d)
-include $(DEPS)

.PHONY: all run clean portable

all: portable run

$(BUILD)/src/%.o: $(SRC_DIR)/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(SAN) -c $< -o $@

$(BUILD)/test/%.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(SAN) -c $< -o $@

$(BUILD)/tests: $(OBJS)
	$(CXX) $(SAN) $^ -o $@

run: $(BUILD)/tests
	./$(BUILD)/tests $(T)

portable:
	@! grep -rnE '#include *[<"](Arduino|esp_|freertos|driver/|nvs|NimBLE)' \
	    $(shell find $(SRC_DIR) -name '*.h' -o -name '*.cpp' | grep -v /platform/) \
	  || (echo "portable code must not include platform headers" && false)
	@echo "portable-core check passed"

clean:
	rm -rf $(BUILD)
