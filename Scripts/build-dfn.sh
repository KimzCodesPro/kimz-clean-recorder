#!/usr/bin/env bash
# Builds the DeepFilterNet Rust library into Vendor/libdfn.a
#   ./Scripts/build-dfn.sh              → this Mac's architecture (fastest)
#   ./Scripts/build-dfn.sh --universal  → Apple Silicon + Intel
set -euo pipefail
cd "$(dirname "$0")/.."

command -v cargo >/dev/null || { echo "Install Rust first: https://rustup.rs"; exit 1; }

if [[ "${1:-}" == "--universal" ]]; then
  targets=(aarch64-apple-darwin x86_64-apple-darwin)
else
  [[ "$(uname -m)" == "arm64" ]] && targets=(aarch64-apple-darwin) || targets=(x86_64-apple-darwin)
fi

libs=()
for t in "${targets[@]}"; do
  rustup target add "$t" >/dev/null
  echo "Building DeepFilterNet for $t (first build takes a few minutes)…"
  MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release --manifest-path dfn/Cargo.toml --target "$t"
  libs+=("dfn/target/$t/release/libdfn.a")
done

mkdir -p Vendor
if (( ${#libs[@]} > 1 )); then
  lipo -create "${libs[@]}" -output Vendor/libdfn.a
else
  cp "${libs[0]}" Vendor/libdfn.a
fi
echo "Done → Vendor/libdfn.a ($(du -h Vendor/libdfn.a | cut -f1))"
