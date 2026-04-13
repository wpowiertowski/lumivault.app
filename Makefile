.PHONY: xcode test test-macos test-ipados build-macos build-ipados clean

# ── Open ──────────────────────────────────────────────────────────────

xcode:
	xcodegen generate
	open LumiVault.xcodeproj

# ── Build ─────────────────────────────────────────────────────────────

build-macos:
	xcodegen generate
	xcodebuild build \
		-project LumiVault.xcodeproj \
		-scheme LumiVault \
		-configuration Debug \
		CODE_SIGNING_ALLOWED=NO

build-ipados:
	xcodegen generate
	xcodebuild build \
		-project LumiVault.xcodeproj \
		-scheme LumiVault-iPadOS \
		-destination "generic/platform=iOS" \
		-configuration Debug \
		CODE_SIGNING_ALLOWED=NO

# ── Test ──────────────────────────────────────────────────────────────

test-macos: build-macos
	swift test
	xcodebuild archive \
		-project LumiVault.xcodeproj \
		-scheme LumiVault \
		-destination generic/platform=macOS \
		-archivePath /tmp/LumiVault-test.xcarchive \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		COMPILER_INDEX_STORE_ENABLE=NO

test-ipados: build-ipados
	xcodebuild archive \
		-project LumiVault.xcodeproj \
		-scheme LumiVault-iPadOS \
		-destination "generic/platform=iOS" \
		-archivePath /tmp/LumiVault-iPadOS-test.xcarchive \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		COMPILER_INDEX_STORE_ENABLE=NO

test: test-macos test-ipados

# ── Clean ─────────────────────────────────────────────────────────────

clean:
	rm -rf LumiVault.xcodeproj
	rm -rf ~/Library/Developer/Xcode/DerivedData/LumiVault-*
	swift package clean
	defaults delete app.lumivault hasSeenWelcome 2>/dev/null || true
