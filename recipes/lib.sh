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

# expect_response <pid> <port> <path> <expected body>: fails unless the running server answers.
# Printing a version proves little: a server can do that and still refuse to start.
expect_response() {
  local pid="$1" port="$2" path="$3" expected="$4" body=""
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || { echo "The server exited during the smoke test" >&2; return 1; }
    body="$(curl --silent --max-time 2 "http://127.0.0.1:$port$path" || true)"
    if [[ "$body" == "$expected" ]]; then
      echo "Smoke test passed: $path returned \"$body\""
      return 0
    fi
    sleep 0.2
  done
  echo "Smoke test failed: expected \"$expected\" from $path, got \"$body\"" >&2
  return 1
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

# build_key_value_store <name> <server> <client> <version> <url> <sha256> <license files...>: Redis and
# Valkey share a build system. TLS is off, since they only listen on loopback, so nothing is linked
# from outside. The smoke test proves data survives a restart, not just that the server answers.
build_key_value_store() {
  local name="$1" server="$2" client="$3" version="$4" url="$5" sha256="$6"
  shift 6
  local work="$ROOT/build/$name"
  rm -rf "$work"
  fetch_source "$url" "$sha256" "$work/src"
  make -C "$work/src" -j"$JOBS" BUILD_TLS=no USE_SYSTEMD=no

  local stage="$work/stage"
  mkdir -p "$stage/bin" "$stage/licenses"
  cp "$work/src/src/$server" "$work/src/src/$client" "$stage/bin/"
  for binary in "$stage"/bin/*; do
    finish_binary "$binary"
    assert_portable "$binary"
  done
  for license in "$@"; do
    cp "$work/src/$license" "$stage/licenses/$name-$license"
  done

  # Runs from a folder with a space, as macOS's Application Support is.
  local smoke="$work/smoke test" port=18996 result=""
  mkdir -p "$smoke"
  start_smoke_server() {
    env -i "$stage/bin/$server" --port "$port" --bind 127.0.0.1 --dir "$smoke" --daemonize no \
      > "$smoke/server.log" 2>&1 &
    SERVER=$!
    for _ in $(seq 1 50); do
      kill -0 "$SERVER" 2>/dev/null || { cat "$smoke/server.log" >&2; return 1; }
      [[ "$(env -i "$stage/bin/$client" -p "$port" ping 2>/dev/null)" == "PONG" ]] && return 0
      sleep 0.2
    done
    cat "$smoke/server.log" >&2
    return 1
  }
  start_smoke_server
  trap 'kill "$SERVER" 2>/dev/null || true' EXIT
  env -i "$stage/bin/$client" -p "$port" set smoke kept > /dev/null
  env -i "$stage/bin/$client" -p "$port" save > /dev/null
  kill "$SERVER"
  wait "$SERVER" || true
  start_smoke_server
  result="$(env -i "$stage/bin/$client" -p "$port" get smoke)"
  kill "$SERVER"
  wait "$SERVER" || true
  trap - EXIT
  if [[ "$result" != "kept" ]]; then
    echo "Smoke test failed: expected the value to survive a restart, got \"$result\"" >&2
    return 1
  fi
  echo "Smoke test passed: a saved value survived a restart"

  package "$name" "$version" "$stage"
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
