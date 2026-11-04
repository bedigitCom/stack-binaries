#!/usr/bin/env bash
# Phase 0 of our own PHP builds: PHP with its extensions as separate files, built by static-php-cli.
# A test only. Nothing here is published, and the workflow keeps no files.
source "$(dirname "$0")/lib.sh"

# Stay in the base build: others need them, or Composer does.
BUILT_IN="ctype,dom,filter,iconv,mysqlnd,openssl,pdo,phar,posix,session,simplexml,tokenizer,xml,xmlreader,xmlwriter,zlib"
# What the app's checkboxes would offer.
SEPARATE="bcmath,bz2,calendar,curl,exif,fileinfo,ftp,gd,gmp,imagick,intl,mbstring,mysqli,opcache,pcntl,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,redis,soap,sockets,sodium,sqlite3,xdebug,zip"

WORK="$ROOT/build/php-test"
rm -rf "$WORK"
mkdir -p "$WORK"
git -C "$WORK" init -q spc
SPC_DIR="$WORK/spc"
git -C "$SPC_DIR" remote add origin https://github.com/crazywhalecc/static-php-cli.git
git -C "$SPC_DIR" fetch -q --depth 1 origin "$STATIC_PHP_CLI_COMMIT"
git -C "$SPC_DIR" checkout -q FETCH_HEAD
cd "$SPC_DIR"

if [[ "$PLATFORM" == linux-* ]]; then
  # Builds in a CentOS 7 container, for an old glibc that newer systems can all run.
  mkdir -p buildroot source dist downloads pkgroot log
  SPC=(bin/spc-gnu-docker)
else
  bin/setup-runtime
  export PATH="$PWD/bin:$PATH"
  bin/php bin/composer install --no-dev --no-interaction --quiet
  SPC=(bin/spc)
  "${SPC[@]}" doctor --auto-fix
fi

started=$SECONDS
"${SPC[@]}" download --with-php=8.4 --for-extensions="$BUILT_IN,$SEPARATE" --retry=3
"${SPC[@]}" build "$BUILT_IN" --build-shared="$SEPARATE" --build-cli --build-fpm --debug
echo "Build took $(((SECONDS - started) / 60)) minutes"

[[ "$PLATFORM" == linux-* ]] && sudo chown -R "$(id -u):$(id -g)" buildroot
STAGE="$WORK/stage"
mkdir -p "$STAGE/bin" "$STAGE/ext"
cp buildroot/bin/php buildroot/bin/php-fpm "$STAGE/bin/"
find buildroot -name '*.so' -path '*extensions*' -exec cp {} "$STAGE/ext/" \;
if [[ -z "$(ls -A "$STAGE/ext")" ]]; then
  find buildroot -name '*.so' -print
  find buildroot -name '*.so' -exec cp {} "$STAGE/ext/" \;
fi
for binary in "$STAGE"/bin/* "$STAGE"/ext/*.so; do
  finish_binary "$binary"
done
ls -la "$STAGE/bin" "$STAGE/ext"
tar -czf "$WORK/size-check.tar.gz" -C "$STAGE" .
echo "Download size: $(($(wc -c < "$WORK/size-check.tar.gz") / 1048576)) MB"
rm "$WORK/size-check.tar.gz"

# The test site goes through our real Nginx.
mkdir -p "$STAGE/nginx"
curl --fail --location --silent --show-error --retry 3 \
  "https://github.com/bedigitCom/stack-binaries/releases/download/nginx-$NGINX_VERSION/nginx-$NGINX_VERSION-$PLATFORM.tar.gz" \
  | tar -xz -C "$STAGE/nginx"
