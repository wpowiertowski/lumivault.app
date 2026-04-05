.PHONY: xcode test clean

xcode:
	xcodegen generate
	open LumiVault.xcodeproj

test:
	swift test
	xcodegen generate
	xcodebuild test -project LumiVault.xcodeproj -scheme LumiVaultTests -destination 'platform=macOS'

clean:
	rm -rf LumiVault.xcodeproj
	rm -rf ~/Library/Developer/Xcode/DerivedData/LumiVault-*
	swift package clean
