APP      := dist/HeadphoneLabHost.app
EXEC     := $(APP)/Contents/MacOS/HeadphoneLabHost
PLIST    := $(APP)/Contents/Info.plist
SOURCES  := $(wildcard Sources/*.swift)

DRIVER        := dist/HeadphoneLab.driver
DRIVER_EXEC   := $(DRIVER)/Contents/MacOS/HeadphoneLabDriver
DRIVER_PLIST  := $(DRIVER)/Contents/Info.plist
DRIVER_SWIFT  := $(wildcard Sources/driver/*.swift)
DRIVER_BRIDGE := Sources/driver/HPLDriverBridge.m
DRIVER_HEADER := Sources/driver/HPLDriverBridge.h
BUILD_DIR     := build/driver

.PHONY: all run driver clean

all: $(APP) driver

$(EXEC): $(SOURCES)
	@mkdir -p $(@D)
	xcrun swiftc -O -swift-version 5 -o $@ $(SOURCES) \
		-framework Cocoa -framework AVFoundation -framework AudioToolbox -framework CoreAudio

$(PLIST): Resources/Info.plist
	@mkdir -p $(@D)
	cp $< $@

HELPER := $(APP)/Contents/Helpers/HeadphoneLabCapture
HELPER_SOURCES := Sources/capture-helper/main.swift Sources/ShmCapture.swift

$(HELPER): $(HELPER_SOURCES)
	@mkdir -p $(@D)
	xcrun swiftc -O -swift-version 5 -o $@ $(HELPER_SOURCES) -framework CoreAudio -framework AudioToolbox -framework Foundation

$(APP)/Contents/Resources/AppIcon.icns: Resources/AppIcon.icns
	@mkdir -p $(@D)
	cp $< $@

$(APP): $(EXEC) $(PLIST) $(HELPER) $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign - --timestamp=none $(APP)

# --- AudioServerPlugIn driver (ported from eqMac's driver target, which is a
# --- com.apple.product-type.bundle / wrapper.cfbundle product, i.e. a BNDL
# --- bundle whose executable is a Swift dylib + a tiny ObjC CFPlugIn bridge)

# Step 1 compiles all Swift sources in one frontend batch; with no -o the driver
# drops one .o per source into the CWD, which is why we cd into BUILD_DIR.
# The generated ObjC header is what HPLDriverBridge.m imports in step 2.
# Step 3 relinks every object (Swift + bridge) into the bundle executable.
$(DRIVER_EXEC): $(DRIVER_SWIFT) $(DRIVER_BRIDGE) $(DRIVER_HEADER)
	@mkdir -p $(BUILD_DIR) $(@D)
	cd $(BUILD_DIR) && xcrun swiftc -c -O -swift-version 5 \
		-module-name HeadphoneLabDriver \
		-emit-objc-header -emit-objc-header-path HeadphoneLabDriver-Swift.h \
		$(addprefix $(CURDIR)/,$(DRIVER_SWIFT))
	xcrun clang -c -fobjc-arc -fmodules -I$(BUILD_DIR) \
		$(DRIVER_BRIDGE) -o $(BUILD_DIR)/HPLDriverBridge.o
	xcrun swiftc -emit-library -o $@ $(BUILD_DIR)/*.o

$(DRIVER_PLIST): Resources/driver/Info.plist
	@mkdir -p $(@D)
	cp $< $@

$(DRIVER): $(DRIVER_EXEC) $(DRIVER_PLIST)
	codesign --force --sign - --timestamp=none $(DRIVER)

driver: $(DRIVER)

run: $(APP)
	open $(APP)

clean:
	rm -rf dist build

HAL_DIR := $(HOME)/Library/Audio/Plug-Ins/HAL

.PHONY: install-driver reload-coreaudio

install-driver: driver
	mkdir -p $(HAL_DIR)
	rm -rf $(HAL_DIR)/HeadphoneLab.driver
	cp -R dist/HeadphoneLab.driver $(HAL_DIR)/
	@echo "driver installed to $(HAL_DIR)"

reload-coreaudio:
	sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
	@echo "coreaudiod restarted"

SYSTEM_HAL_DIR := /Library/Audio/Plug-Ins/HAL

install-driver-system: driver
	sudo rm -rf $(SYSTEM_HAL_DIR)/HeadphoneLab.driver
	sudo cp -R dist/HeadphoneLab.driver $(SYSTEM_HAL_DIR)/
	sudo killall coreaudiod
	@echo "driver installed to $(SYSTEM_HAL_DIR) and coreaudiod restarted"
