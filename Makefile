.PHONY: xcode test clean

xcode:
	xcodegen generate
	open LumiVault.xcodeproj

test:
	swift test
	xcodegen generate
	xcodebuild build -project LumiVault.xcodeproj -scheme LumiVault -configuration Debug

clean:
	rm -rf LumiVault.xcodeproj
	rm -rf ~/Library/Developer/Xcode/DerivedData/LumiVault-*
	swift package clean
