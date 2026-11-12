#!/bin/sh
# Runs every scenario of the test script, and stops at the first that fails.
# Needs Lua 5.1, the version WoW embeds.
set -e
cd "$(dirname "$0")/.."
run() {
	env "$@" lua5.1 tests/rebuff_test.lua > /dev/null
	echo "ok: ${*:-default}"
}
luac5.1 -p Rebuff.lua Window.lua
run
run INDEX=1
run HIDDEN=1
run LEGACY=1
run REFUSE=ButtonFrameTemplate,PortraitFrameTemplate,BasicFrameTemplateWithInset
run REFUSE=UICheckButtonTemplate
