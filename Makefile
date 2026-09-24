APP := .build/HalfScreen.app
BIN := $(APP)/Contents/MacOS/HalfScreen

.PHONY: all clean install
all: $(BIN)

$(BIN): Sources/main.m Resources/Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter -O2 \
		-framework AppKit -framework CoreGraphics -framework ServiceManagement \
		-o $(BIN) Sources/main.m
	codesign --force --deep --sign - $(APP)

install: all
	ditto $(APP) /Applications/HalfScreen.app

clean:
	rm -rf .build
