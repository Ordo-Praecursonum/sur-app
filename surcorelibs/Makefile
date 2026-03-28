# Sur Protocol — surcorelibs build
#
# Builds libsurcorelibs.a for iOS (arm64-apple-ios) and simulator (x86_64-apple-ios-simulator)
# and assembles them into an XCFramework for Xcode integration.
#
# Prerequisites:
#   - Go 1.22+
#   - Xcode command line tools (for lipo, xcodebuild)
#   - CGO_ENABLED=1

MODULE = github.com/Ordo-Praecursonum/sur-app/surcorelibs
LIB_NAME = libsurcorelibs
XCFRAMEWORK = $(LIB_NAME).xcframework

BUILD_DIR = build
IOS_DIR = $(BUILD_DIR)/ios-arm64
SIM_DIR = $(BUILD_DIR)/ios-sim-x86_64
SIM_ARM_DIR = $(BUILD_DIR)/ios-sim-arm64

.PHONY: all clean test ios-device ios-simulator xcframework

all: test

# Run all Go tests
test:
	go test -v -count=1 ./poseidon/
	go test -v -count=1 ./gnark/ -run TestCircuitCompiles
	go test -v -count=1 ./gnark/ -run TestCircuitConstraintCount

# Build static library for iOS device (arm64)
ios-device:
	@mkdir -p $(IOS_DIR)
	CGO_ENABLED=1 \
	GOOS=ios \
	GOARCH=arm64 \
	CC=$(shell xcrun --sdk iphoneos --find clang) \
	CGO_CFLAGS="-isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -arch arm64 -miphoneos-version-min=16.0" \
	CGO_LDFLAGS="-isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -arch arm64" \
	go build -buildmode=c-archive -o $(IOS_DIR)/$(LIB_NAME).a ./gnark/

# Build static library for iOS simulator (arm64 for Apple Silicon, x86_64 for Intel)
ios-simulator:
	@mkdir -p $(SIM_ARM_DIR)
	CGO_ENABLED=1 \
	GOOS=ios \
	GOARCH=arm64 \
	CC=$(shell xcrun --sdk iphonesimulator --find clang) \
	CGO_CFLAGS="-isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path) -arch arm64 -miphonesimulator-version-min=16.0" \
	CGO_LDFLAGS="-isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path) -arch arm64" \
	go build -buildmode=c-archive -o $(SIM_ARM_DIR)/$(LIB_NAME).a ./gnark/

# Assemble XCFramework from device and simulator builds
xcframework: ios-device ios-simulator
	@rm -rf $(XCFRAMEWORK)
	xcodebuild -create-xcframework \
		-library $(IOS_DIR)/$(LIB_NAME).a -headers $(IOS_DIR)/$(LIB_NAME).h \
		-library $(SIM_ARM_DIR)/$(LIB_NAME).a -headers $(SIM_ARM_DIR)/$(LIB_NAME).h \
		-output $(XCFRAMEWORK)
	@echo "✅ XCFramework built: $(XCFRAMEWORK)"

clean:
	rm -rf $(BUILD_DIR) $(XCFRAMEWORK)
