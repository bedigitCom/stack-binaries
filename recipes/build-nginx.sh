#!/usr/bin/env bash
# Builds a self-contained Nginx: PCRE2, zlib and OpenSSL are linked statically.
source "$(dirname "$0")/lib.sh"

WORK="$ROOT/build/nginx"
rm -rf "$WORK"
fetch_source "$NGINX_URL" "$NGINX_SHA256" "$WORK/nginx"
fetch_source "$PCRE2_URL" "$PCRE2_SHA256" "$WORK/pcre2"
fetch_source "$ZLIB_URL" "$ZLIB_SHA256" "$WORK/zlib"
fetch_source "$OPENSSL_URL" "$OPENSSL_SHA256" "$WORK/openssl"

cd "$WORK/nginx"
# Paths are relative because the app passes its own prefix with -p.
./configure \
  --prefix=. \
  --sbin-path=nginx \
  --conf-path=nginx.conf \
  --pid-path=nginx.pid \
  --lock-path=nginx.lock \
  --error-log-path=stderr \
  --http-log-path=access.log \
  --http-client-body-temp-path=client_body_temp \
  --http-proxy-temp-path=proxy_temp \
  --http-fastcgi-temp-path=fastcgi_temp \
  --http-uwsgi-temp-path=uwsgi_temp \
  --http-scgi-temp-path=scgi_temp \
  --with-threads \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-http_realip_module \
  --with-http_gzip_static_module \
  --with-http_stub_status_module \
  --with-http_auth_request_module \
  --with-pcre="$WORK/pcre2" \
  --with-pcre-jit \
  --with-zlib="$WORK/zlib" \
  --with-openssl="$WORK/openssl" \
  --with-openssl-opt="no-shared no-tests no-docs"
make -j"$JOBS"

STAGE="$WORK/stage"
mkdir -p "$STAGE/licenses"
cp objs/nginx "$STAGE/nginx"
finish_binary "$STAGE/nginx"
assert_portable "$STAGE/nginx"

cp LICENSE "$STAGE/licenses/nginx.txt"
cp "$WORK/pcre2/LICENCE.md" "$STAGE/licenses/pcre2.txt"
cp "$WORK/zlib/LICENSE" "$STAGE/licenses/zlib.txt"
cp "$WORK/openssl/LICENSE.txt" "$STAGE/licenses/openssl.txt"

env -i "$STAGE/nginx" -V
package nginx "$NGINX_VERSION" "$STAGE"
