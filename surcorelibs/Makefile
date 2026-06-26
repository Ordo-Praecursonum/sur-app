.PHONY: all xcframework device-only test clean

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
# Cross-compiling a Go c-archive with cgo for iOS requires pointing clang at the
# correct SDK sysroot — otherwise cgo fails with "'stdlib.h' file not found".
# We pass -isysroot / -arch / -m*-version-min through CGO_CFLAGS and CGO_LDFLAGS.
MIN_IOS := 17.0
GO      ?= go

# SDK paths and compilers, resolved via xcrun.
IOS_SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
IOS_CC  := $(shell xcrun --sdk iphoneos --find clang)
SIM_SDK := $(shell xcrun --sdk iphonesimulator --show-sdk-path)
SIM_CC  := $(shell xcrun --sdk iphonesimulator --find clang)

BUILD := build

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

all: xcframework

# Full XCFramework with both device (arm64) and simulator (arm64) slices, so the
# app links whether it runs on a real device or the iOS Simulator.
#
# Usage in Xcode: drag build/libsurcorelibs.xcframework into the project and add
# it under "Frameworks, Libraries, and Embedded Content" (this is a manual Xcode
# step, not a shell command).
xcframework: $(BUILD)/device/libsurcorelibs.a $(BUILD)/sim/libsurcorelibs.a
	rm -rf $(BUILD)/libsurcorelibs.xcframework
	xcodebuild -create-xcframework \
		-library $(BUILD)/device/libsurcorelibs.a -headers $(BUILD)/device/include \
		-library $(BUILD)/sim/libsurcorelibs.a    -headers $(BUILD)/sim/include \
		-output $(BUILD)/libsurcorelibs.xcframework
	@echo "Built $(BUILD)/libsurcorelibs.xcframework (device arm64 + simulator arm64)"

# Device-only fallback: use if the simulator slice fails to build on your
# toolchain. App Attest / Secure Enclave require a real device anyway.
device-only: $(BUILD)/device/libsurcorelibs.a
	rm -rf $(BUILD)/libsurcorelibs.xcframework
	xcodebuild -create-xcframework \
		-library $(BUILD)/device/libsurcorelibs.a -headers $(BUILD)/device/include \
		-output $(BUILD)/libsurcorelibs.xcframework
	@echo "Built $(BUILD)/libsurcorelibs.xcframework (device arm64 only)"

# Device slice: iphoneos arm64.
$(BUILD)/device/libsurcorelibs.a:
	mkdir -p $(BUILD)/device/include
	CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
	CC="$(IOS_CC)" \
	CGO_CFLAGS="-isysroot $(IOS_SDK) -arch arm64 -mios-version-min=$(MIN_IOS)" \
	CGO_LDFLAGS="-isysroot $(IOS_SDK) -arch arm64 -mios-version-min=$(MIN_IOS)" \
	$(GO) build -buildmode=c-archive -o $(BUILD)/device/libsurcorelibs.a ./ffi/
	cp $(BUILD)/device/libsurcorelibs.h $(BUILD)/device/include/
	printf 'module libsurcorelibs {\n  header "libsurcorelibs.h"\n  export *\n}\n' > $(BUILD)/device/include/module.modulemap

# Simulator slice: iphonesimulator arm64 (Apple Silicon Macs).
$(BUILD)/sim/libsurcorelibs.a:
	mkdir -p $(BUILD)/sim/include
	CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
	CC="$(SIM_CC)" \
	CGO_CFLAGS="-isysroot $(SIM_SDK) -arch arm64 -target arm64-apple-ios$(MIN_IOS)-simulator" \
	CGO_LDFLAGS="-isysroot $(SIM_SDK) -arch arm64 -target arm64-apple-ios$(MIN_IOS)-simulator" \
	$(GO) build -buildmode=c-archive -tags ios -o $(BUILD)/sim/libsurcorelibs.a ./ffi/
	cp $(BUILD)/sim/libsurcorelibs.h $(BUILD)/sim/include/
	printf 'module libsurcorelibs {\n  header "libsurcorelibs.h"\n  export *\n}\n' > $(BUILD)/sim/include/module.modulemap

# Run all Go tests (host platform, not cross-compiled).
test:
	$(GO) test ./...

# Remove all build artifacts.
clean:
	rm -rf $(BUILD)/
