#!/bin/sh
#
# Xcode Cloud post-clone hook.
#
# `LumiVault.xcodeproj` is generated from `project.yml` and is NOT committed, so
# it does not exist immediately after Xcode Cloud clones the repository. Xcode
# Cloud runs this script after the clone and before resolving dependencies or
# building, which is where the project has to come into being.
#
# Without this, Xcode Cloud fails with "project not found" — it is the App Store
# release pipeline, so this file is load-bearing.

set -e

echo "ci_post_clone: installing XcodeGen"
brew install xcodegen

cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "ci_post_clone: generating LumiVault.xcodeproj from project.yml"
xcodegen generate

# The setting that caused the v1.1.1 crash class: this toolchain silently ignores
# SWIFT_DEFAULT_ISOLATION, so the app must receive `-default-isolation MainActor`
# via OTHER_SWIFT_FLAGS or it builds with a nonisolated default and mutates the
# main-bound ModelContext off the main actor. Fail the build here rather than
# shipping that to App Store Connect.
if ! grep -q -- '-default-isolation MainActor' LumiVault.xcodeproj/project.pbxproj; then
    echo "error: generated project is missing -default-isolation MainActor" >&2
    exit 1
fi

echo "ci_post_clone: done"
