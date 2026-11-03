# Shared by every recipe. Sourced, not run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$ROOT/.cache"
DIST="$ROOT/dist"
# shellcheck source=recipes/versions.env
source "$ROOT/recipes/versions.env"

case "$(uname -s)-$(uname -m)" in
  Darwin-x86_64) PLATFORM=darwin-x86_64 ;;
  Darwin-arm64) PLATFORM=darwin-aarch64 ;;
  Linux-x86_64) PLATFORM=linux-x86_64 ;;
  Linux-aarch64) PLATFORM=linux-aarch64 ;;
  *) echo "Unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

if [[ "$PLATFORM" == darwin-* ]]; then
  # The oldest macOS these builds promise to run on.
  export MACOSX_DEPLOYMENT_TARGET=11.0
  JOBS="$(sysctl -n hw.ncpu)"
else
  JOBS="$(nproc)"
fi

sha256_of() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# fetch_source <url> <sha256> <dest dir>: downloads once, verifies, and unpacks without the top folder.
fetch_source() {
  local url="$1" expected="$2" dest="$3"
  local file="$CACHE/$(basename "$url")"
  mkdir -p "$CACHE" "$dest"
  if [[ ! -f "$file" ]]; then
    curl --fail --location --silent --show-error --retry 3 --output "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  local actual
  actual="$(sha256_of "$file")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$file"
    echo "Checksum mismatch for $url: expected $expected, got $actual" >&2
    exit 1
  fi
  tar -xf "$file" -C "$dest" --strip-components=1
}

# assert_portable <binary>: fails if it links anything a customer's machine might not have.
assert_portable() {
  local binary="$1" foreign
  if [[ "$PLATFORM" == darwin-* ]]; then
    foreign="$(otool -L "$binary" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' || true)"
  else
    foreign="$(ldd "$binary" | awk '{print $1}' \
      | grep -vE '^(linux-vdso|linux-gate|/lib.*/ld-linux|ld-linux|libc\.|libm\.|libdl\.|libpthread\.|librt\.|libcrypt\.|libresolv\.)' || true)"
  fi
  if [[ -n "$foreign" ]]; then
    echo "$binary links libraries that won't exist everywhere:" >&2
    echo "$foreign" >&2
    exit 1
  fi
  echo "Portable: $binary"
}

# finish_binary <binary>: strips symbols, and re-signs on macOS, which stripping invalidates.
finish_binary() {
  local binary="$1"
  if [[ "$PLATFORM" == darwin-* ]]; then
    strip -x "$binary"
    codesign --sign - --force "$binary"
  else
    strip "$binary"
  fi
}

# package <name> <version> <stage dir>: writes the archive and its checksum to dist/.
package() {
  local name="$1" version="$2" stage="$3"
  local archive="$DIST/$name-$version-$PLATFORM.tar.gz"
  mkdir -p "$DIST"
  tar -czf "$archive" -C "$stage" .
  sha256_of "$archive" > "$archive.sha256"
  echo "Built $archive"
  echo "sha256 $(cat "$archive.sha256")"
}
