.PHONY: xcode test clean

xcode:
	xcodegen generate
	open LumiVault.xcodeproj

test:
	swift test
	xcodegen generate
	xcodebuild build -project LumiVault.xcodeproj -scheme LumiVault -configuration Debug CODE_SIGNING_ALLOWED=NO
	xcodebuild archive -project LumiVault.xcodeproj -scheme LumiVault -destination generic/platform=macOS -archivePath /tmp/LumiVault-test.xcarchive CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO

clean:
	rm -rf LumiVault.xcodeproj
	rm -rf ~/Library/Developer/Xcode/DerivedData/LumiVault-*
	swift package clean
