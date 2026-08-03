#!/usr/bin/env bash

set -euo pipefail

package_path="$(cd "$(dirname "$0")/.." && pwd)"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT

create_consumer() {
  local name="$1"
  local products="$2"
  local imports="$3"
  local source="$4"
  local directory="$work_directory/$name"

  mkdir -p "$directory/Sources/$name"
  cat > "$directory/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "$name",
    platforms: [.macOS(.v10_15)],
    dependencies: [.package(path: "$package_path")],
    targets: [
        .executableTarget(
            name: "$name",
            dependencies: [$products]
        )
    ]
)
EOF
  cat > "$directory/Sources/$name/main.swift" <<EOF
$imports

$source
EOF
  swift build --package-path "$directory"
}

create_consumer \
  "CoreConsumer" \
  '.product(name: "Messagevisor", package: "messagevisor-swift")' \
  'import Messagevisor' \
  $'let m = createMessagevisor()\n_ = Task.detached { m.getLocale() }\nprint(m.getLocale() ?? "Messagevisor")'

create_consumer \
  "ModulesConsumer" \
  '.product(name: "Messagevisor", package: "messagevisor-swift"), .product(name: "MessagevisorICU", package: "messagevisor-swift"), .product(name: "MessagevisorInterpolation", package: "messagevisor-swift"), .product(name: "MessagevisorMissingTranslations", package: "messagevisor-swift")' \
  $'import Messagevisor\nimport MessagevisorICU\nimport MessagevisorInterpolation\nimport MessagevisorMissingTranslations' \
  $'let modules = [\n    createICUModule(),\n    createInterpolationModule(),\n    createMissingTranslationsModule(.init(handler: { _ in }))\n]\nlet m = createMessagevisor(MessagevisorOptions(modules: modules))\nprint(m.getLocale() ?? "Messagevisor")'

echo "Messagevisor Swift public products build from clean consumer packages."
