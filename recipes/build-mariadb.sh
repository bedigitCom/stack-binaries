#!/usr/bin/env bash
# Builds MariaDB server and clients for one LTS series, for example: build-mariadb.sh 11.8
# OpenSSL and zlib are linked statically. Plugins that need more libraries are left out.
source "$(dirname "$0")/lib.sh"

SERIES="${1:?Pass a MariaDB series, for example 11.8}"
SERIES_VAR="${SERIES//./_}"
VERSION_VAR="MARIADB_${SERIES_VAR}_VERSION"
SHA_VAR="MARIADB_${SERIES_VAR}_SHA256"
VERSION="${!VERSION_VAR:?Unknown MariaDB series $SERIES}"
SHA256="${!SHA_VAR}"
URL="https://archive.mariadb.org/mariadb-$VERSION/source/mariadb-$VERSION.tar.gz"

WORK="$ROOT/build/mariadb-$SERIES"
DEPS="$WORK/deps"
rm -rf "$WORK"
mkdir -p "$DEPS"

fetch_source "$URL" "$SHA256" "$WORK/src"
fetch_source "$OPENSSL_URL" "$OPENSSL_SHA256" "$WORK/openssl"

(cd "$WORK/openssl" && ./config --prefix="$DEPS" --libdir=lib no-shared no-tests no-docs \
  && make -j"$JOBS" && make install_sw)

# The prefix never exists on a customer's machine. The app passes --basedir at runtime.
cmake -S "$WORK/src" -B "$WORK/out" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/opt/bedigit-stack/mariadb \
  -DCMAKE_PREFIX_PATH="$DEPS" \
  -DCMAKE_FIND_FRAMEWORK=NEVER \
  -DWITH_SSL="$DEPS" \
  -DWITH_ZLIB=bundled \
  -DWITH_PCRE=bundled \
  -DWITH_LIBFMT=bundled \
  -DWITH_READLINE=ON \
  -DWITH_UNIT_TESTS=OFF \
  -DWITH_EMBEDDED_SERVER=OFF \
  -DWITH_WSREP=OFF \
  -DWITH_MARIABACKUP=OFF \
  -DWITH_NUMA=OFF \
  -DWITH_SYSTEMD=no \
  -DWITH_INNODB_BZIP2=OFF -DWITH_INNODB_LZ4=OFF -DWITH_INNODB_LZMA=OFF \
  -DWITH_INNODB_LZO=OFF -DWITH_INNODB_SNAPPY=OFF \
  -DWITH_ROCKSDB_BZip2=OFF -DWITH_ROCKSDB_LZ4=OFF -DWITH_ROCKSDB_ZSTD=OFF -DWITH_ROCKSDB_snappy=OFF \
  -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO -DPLUGIN_OQGRAPH=NO \
  -DPLUGIN_CONNECT=NO -DPLUGIN_S3=NO -DPLUGIN_SPHINX=NO -DPLUGIN_COLUMNSTORE=NO \
  -DPLUGIN_TOKUDB=NO -DPLUGIN_CRACKLIB_PASSWORD_CHECK=NO -DPLUGIN_AUTH_GSSAPI=NO \
  -DPLUGIN_AUTH_GSSAPI_CLIENT=OFF -DPLUGIN_AUTH_PAM=NO -DPLUGIN_AUTH_PAM_V1=NO \
  -DPLUGIN_HASHICORP_KEY_MANAGEMENT=NO -DPLUGIN_AWS_KEY_MANAGEMENT=NO \
  -DPLUGIN_PROVIDER_BZIP2=NO -DPLUGIN_PROVIDER_LZ4=NO -DPLUGIN_PROVIDER_LZMA=NO \
  -DPLUGIN_PROVIDER_LZO=NO -DPLUGIN_PROVIDER_SNAPPY=NO \
  -DCLIENT_PLUGIN_AUTH_GSSAPI_CLIENT=OFF \
  -DINSTALL_MYSQLTESTDIR= -DINSTALL_SQLBENCHDIR=
cmake --build "$WORK/out" --parallel "$JOBS"

STAGE="$WORK/stage"
DESTDIR="$WORK/install" cmake --install "$WORK/out"
INSTALLED="$WORK/install/opt/bedigit-stack/mariadb"

mkdir -p "$STAGE/bin" "$STAGE/scripts" "$STAGE/licenses"
for tool in mariadbd mariadb mariadb-dump mariadb-admin mariadb-upgrade mariadb-check my_print_defaults \
  resolveip; do
  cp "$INSTALLED/bin/$tool" "$STAGE/bin/$tool"
done
cp "$INSTALLED/scripts/mariadb-install-db" "$STAGE/scripts/mariadb-install-db"
cp -R "$INSTALLED/share" "$STAGE/share"
rm -rf "$STAGE/share/man" "$STAGE/share/doc" "$STAGE/share/info"
mkdir -p "$STAGE/lib"
cp -R "$INSTALLED/lib/plugin" "$STAGE/lib/plugin"

for binary in "$STAGE"/bin/*; do
  finish_binary "$binary"
  assert_portable "$binary"
done
for plugin in "$STAGE"/lib/plugin/*; do
  assert_portable "$plugin"
done

cp "$WORK/src/COPYING" "$STAGE/licenses/mariadb.txt"
cp "$WORK/src/THIRDPARTY" "$STAGE/licenses/mariadb-third-party.txt"
cp "$WORK/openssl/LICENSE.txt" "$STAGE/licenses/openssl.txt"
cat > "$STAGE/licenses/SOURCE.txt" <<SOURCE
MariaDB is licensed under the GPL, version 2. Its source code for this build:
$URL
sha256 $SHA256
The build recipe: https://github.com/bedigitCom/stack-binaries/blob/main/recipes/build-mariadb.sh
SOURCE

# Runs from a folder with a space, as macOS's Application Support is.
SMOKE="$WORK/smoke test"
mkdir -p "$SMOKE"
PORT=18997
env -i "$STAGE/scripts/mariadb-install-db" --no-defaults --basedir="$STAGE" --datadir="$SMOKE/data" \
  --auth-root-authentication-method=normal --skip-test-db > "$SMOKE/install.log" 2>&1 \
  || { cat "$SMOKE/install.log" >&2; exit 1; }
env -i "$STAGE/bin/mariadbd" --no-defaults --basedir="$STAGE" --datadir="$SMOKE/data" --port="$PORT" \
  --bind-address=127.0.0.1 --socket="/tmp/stack-smoke-$PORT.sock" --log-error="$SMOKE/error.log" &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true; cat "$SMOKE/error.log" 2>/dev/null || true' EXIT
RESULT=""
for _ in $(seq 1 100); do
  kill -0 "$SERVER" 2>/dev/null || { echo "The server exited during the smoke test" >&2; exit 1; }
  RESULT="$(env -i "$STAGE/bin/mariadb" --no-defaults --protocol=TCP -h127.0.0.1 -P"$PORT" -uroot -N -B \
    -e 'CREATE DATABASE smoke; CREATE TABLE smoke.t (v INT) ENGINE=InnoDB; INSERT INTO smoke.t VALUES (41); SELECT v + 1 FROM smoke.t' 2>/dev/null || true)"
  [[ -n "$RESULT" ]] && break
  sleep 0.5
done
if [[ "$RESULT" != "42" ]]; then
  echo "Smoke test failed: expected 42, got \"$RESULT\"" >&2
  exit 1
fi
echo "Smoke test passed: a table round trip returned $RESULT"
kill "$SERVER"
wait "$SERVER" || true
trap - EXIT

package mariadb "$VERSION" "$STAGE"
