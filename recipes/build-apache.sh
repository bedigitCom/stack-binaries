#!/usr/bin/env bash
# Builds a self-contained Apache httpd. APR, PCRE2, zlib, Expat, OpenSSL and every module are
# linked statically, so a single executable can run from any folder.
source "$(dirname "$0")/lib.sh"

WORK="$ROOT/build/apache"
DEPS="$WORK/deps"
rm -rf "$WORK"
mkdir -p "$DEPS"

fetch_source "$HTTPD_URL" "$HTTPD_SHA256" "$WORK/httpd"
fetch_source "$APR_URL" "$APR_SHA256" "$WORK/httpd/srclib/apr"
fetch_source "$APR_UTIL_URL" "$APR_UTIL_SHA256" "$WORK/httpd/srclib/apr-util"
fetch_source "$PCRE2_URL" "$PCRE2_SHA256" "$WORK/pcre2"
fetch_source "$ZLIB_URL" "$ZLIB_SHA256" "$WORK/zlib"
fetch_source "$EXPAT_URL" "$EXPAT_SHA256" "$WORK/expat"
fetch_source "$OPENSSL_URL" "$OPENSSL_SHA256" "$WORK/openssl"

(cd "$WORK/pcre2" && ./configure --prefix="$DEPS" --disable-shared --enable-static && make -j"$JOBS" install)
(cd "$WORK/zlib" && ./configure --prefix="$DEPS" --static && make -j"$JOBS" install)
(cd "$WORK/expat" && ./configure --prefix="$DEPS" --disable-shared --enable-static \
  --without-docbook --without-tests --without-examples && make -j"$JOBS" install)
(cd "$WORK/openssl" && ./config --prefix="$DEPS" --libdir=lib no-shared no-tests no-docs \
  && make -j"$JOBS" && make install_sw)

MODULES="authn_core authz_core authz_host access_compat log_config mime dir alias rewrite setenvif env \
headers expires deflate filter remoteip reqtimeout unixd status ssl socache_shmcb proxy proxy_fcgi \
proxy_http proxy_wstunnel"

# APR would otherwise link the system's libuuid, which isn't on every Linux. It has its own.
export ac_cv_search_uuid_create=no ac_cv_search_uuid_generate=no
export ac_cv_func_uuid_create=no ac_cv_func_uuid_generate=no

cd "$WORK/httpd"
# The prefix never exists on a customer's machine. The app passes -d and -f at runtime.
./configure \
  --prefix=/opt/bedigit-stack/httpd \
  --with-included-apr \
  --disable-shared \
  --with-mpm=event \
  --with-pcre="$DEPS/bin/pcre2-config" \
  --with-ssl="$DEPS" \
  --with-z="$DEPS" \
  --with-expat="$DEPS" \
  --enable-mods-shared=none \
  --enable-mods-static="$MODULES" \
  --disable-proxy-connect --disable-proxy-ftp --disable-proxy-scgi --disable-proxy-uwsgi \
  --disable-proxy-fdpass --disable-proxy-ajp --disable-proxy-express --disable-proxy-hcheck \
  --disable-proxy-balancer --disable-lbmethod-byrequests --disable-lbmethod-bytraffic \
  --disable-lbmethod-bybusyness --disable-lbmethod-heartbeat \
  CPPFLAGS="-I$DEPS/include" \
  LDFLAGS="-L$DEPS/lib"
make -j"$JOBS"

STAGE="$WORK/stage"
mkdir -p "$STAGE/bin" "$STAGE/conf" "$STAGE/licenses"
cp .libs/httpd "$STAGE/bin/httpd" 2>/dev/null || cp httpd "$STAGE/bin/httpd"
cp docs/conf/mime.types "$STAGE/conf/mime.types"
finish_binary "$STAGE/bin/httpd"
assert_portable "$STAGE/bin/httpd"

cp LICENSE "$STAGE/licenses/httpd.txt"
cp NOTICE "$STAGE/licenses/httpd-notice.txt"
cp srclib/apr/LICENSE "$STAGE/licenses/apr.txt"
cp srclib/apr-util/LICENSE "$STAGE/licenses/apr-util.txt"
cp "$WORK/pcre2/LICENCE.md" "$STAGE/licenses/pcre2.txt"
cp "$WORK/zlib/LICENSE" "$STAGE/licenses/zlib.txt"
cp "$WORK/expat/COPYING" "$STAGE/licenses/expat.txt"
cp "$WORK/openssl/LICENSE.txt" "$STAGE/licenses/openssl.txt"

env -i "$STAGE/bin/httpd" -V
env -i "$STAGE/bin/httpd" -l

# Runs from a folder with a space, as macOS's Application Support is.
SMOKE="$WORK/smoke test"
mkdir -p "$SMOKE"
cat > "$SMOKE/httpd.conf" <<CONF
ServerName localhost
Listen 127.0.0.1:18998
PidFile "$SMOKE/httpd.pid"
DefaultRuntimeDir "$SMOKE"
Mutex "file:$SMOKE" default
ErrorLog "$SMOKE/error.log"
TypesConfig "$STAGE/conf/mime.types"
DocumentRoot "$SMOKE"
<Directory "$SMOKE">
    Require all granted
</Directory>
CONF
printf ok > "$SMOKE/smoke.txt"
env -i "$STAGE/bin/httpd" -D FOREGROUND -d "$SMOKE" -f "$SMOKE/httpd.conf" &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true; cat "$SMOKE/error.log" 2>/dev/null || true' EXIT
expect_response "$SERVER" 18998 /smoke.txt ok
kill "$SERVER"
wait "$SERVER" || true
trap - EXIT

package apache "$HTTPD_VERSION" "$STAGE"
