.PHONY: build test strict-concurrency clean verify-consumers test-project-1 examples-project-1

PROJECT_1 ?= ../messagevisor/projects/project-1

build:
	swift build

test:
	swift test

strict-concurrency:
	swift build -Xswiftc -swift-version -Xswiftc 6 -Xswiftc -strict-concurrency=complete

clean:
	swift package clean

verify-consumers:
	bash scripts/verify-consumers.sh

test-project-1:
	swift test
	swift run messagevisor-swift test --projectDirectoryPath=$(abspath $(PROJECT_1)) --onlyFailures --target=swift --normalizeSpaces --withIcuModule

examples-project-1:
	swift run messagevisor-swift examples --projectDirectoryPath=$(abspath $(PROJECT_1)) --target=swift --onlyFailures --normalizeSpaces --withIcuModule
