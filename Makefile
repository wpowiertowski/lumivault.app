.PHONY: generate xcode test hooks clean prune-branches

# LumiVault.xcodeproj is generated from project.yml and gitignored — run this
# after cloning, and after adding/removing/moving files.
generate:
	xcodegen generate

hooks:
	git config core.hooksPath .githooks
	@echo "pre-commit hook enabled (runs swift test)."

xcode: generate
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
	defaults delete app.lumivault hasSeenWelcome 2>/dev/null || true

prune-branches:
	@git fetch --prune origin
	@current=$$(git branch --show-current); \
	merged=$$(gh pr list --state merged --limit 200 --json headRefName --jq '.[].headRefName' | sort -u); \
	deleted=0; \
	for branch in $$(git for-each-ref --format='%(refname:short)' refs/heads/); do \
		case "$$branch" in main|master) continue ;; esac; \
		if [ "$$branch" = "$$current" ]; then continue; fi; \
		if printf '%s\n' "$$merged" | grep -qx "$$branch"; then \
			git branch -D "$$branch"; \
			deleted=$$((deleted + 1)); \
		fi; \
	done; \
	echo "Pruned $$deleted merged branch(es)."
