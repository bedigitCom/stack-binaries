#!/usr/bin/env bash
# PHP with its extensions as separate files, built by static-php-cli at one commit. Takes the exact
# version, such as 8.4.27. The archive holds bin/php, bin/php-fpm, ext/ and licenses/.
source "$(dirname "$0")/lib.sh"

VERSION="${1:?Which PHP version?}"
MINOR="${VERSION%.*}"

# Stay in the base build: others need them, or Composer does.
BUILT_IN="ctype,dom,filter,iconv,mysqlnd,openssl,pdo,phar,posix,session,simplexml,tokenizer,xml,xmlreader,xmlwriter,zlib"
# What the app's checkboxes offer.
SEPARATE="bcmath,bz2,calendar,curl,exif,fileinfo,ftp,gd,gmp,imagick,intl,mbstring,mysqli,pcntl,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,redis,soap,sockets,sodium,sqlite3,xdebug,zip"
# From PHP 8.5, OPcache is always part of PHP.
[[ "$MINOR" != "8.5" ]] && SEPARATE="$SEPARATE,opcache"
# Current Xdebug needs PHP 8.2 or newer, and 8.1 is past its end of life.
[[ "$MINOR" == "8.1" ]] && SEPARATE="${SEPARATE/,xdebug/}"

WORK="$ROOT/build/php"
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

# On Linux, PHP 8.1's headers need system types that strict C17 hides.
if [[ "$MINOR" == "8.1" && "$PLATFORM" == linux-* ]]; then
  sed -i 's/-std=c17/-std=gnu17/' src/SPC/builder/extension/pgsql.php
fi

# On Intel Macs, the newer compiler refuses the old-style C in PHP 8.1's bcmath.
if [[ "$MINOR" == "8.1" && "$PLATFORM" == "darwin-x86_64" ]]; then
  sed -i '' 's/-apple-darwin -Os"/-apple-darwin -Os -std=gnu17"/' config/env.ini
fi

started=$SECONDS
"${SPC[@]}" download --with-php="$VERSION" --for-extensions="$BUILT_IN,$SEPARATE" --retry=3

# static-php-cli takes PHP's source from php.net, so check it against what php.net publishes.
[[ "$PLATFORM" == linux-* ]] && sudo chown -R "$(id -u):$(id -g)" downloads
SOURCE_FILE="$(find downloads -maxdepth 1 -name "php-$VERSION.tar.*" | head -1)"
[[ -n "$SOURCE_FILE" ]] || { ls downloads; echo "PHP $VERSION's source wasn't downloaded" >&2; exit 1; }
SOURCE_SHA="$(sha256_of "$SOURCE_FILE")"
curl --fail --silent --show-error --retry 3 "https://www.php.net/releases/index.php?json&version=$VERSION" \
  | grep -q "\"sha256\":\"$SOURCE_SHA\"" \
  || { echo "$SOURCE_FILE doesn't match php.net's checksum" >&2; exit 1; }
echo "PHP source matches php.net: $SOURCE_SHA"

"${SPC[@]}" build "$BUILT_IN" --build-shared="$SEPARATE" --build-cli --build-fpm --debug
"${SPC[@]}" dump-license --for-extensions="$BUILT_IN,$SEPARATE" --dump-dir=buildroot/license
echo "Build took $(((SECONDS - started) / 60)) minutes"

[[ "$PLATFORM" == linux-* ]] && sudo chown -R "$(id -u):$(id -g)" buildroot
STAGE="$WORK/stage"
mkdir -p "$STAGE/bin" "$STAGE/ext" "$STAGE/licenses"
cp buildroot/bin/php buildroot/bin/php-fpm "$STAGE/bin/"
cp buildroot/modules/*.so "$STAGE/ext/"
cp -R buildroot/license/. "$STAGE/licenses/"
[[ -n "$(ls -A "$STAGE/licenses")" ]] || { echo "No licenses were collected" >&2; exit 1; }
for binary in "$STAGE"/bin/* "$STAGE"/ext/*.so; do
  finish_binary "$binary"
done
ls -la "$STAGE/bin" "$STAGE/ext"
package php "$VERSION" "$STAGE"

# The source of everything inside, for the licenses that ask for it, such as GMP's. Only needed once.
if [[ "${WITH_SOURCES:-}" == "yes" ]]; then
  tar -czf "$DIST/php-$VERSION-sources.tar.gz" -C "$SPC_DIR" downloads
  sha256_of "$DIST/php-$VERSION-sources.tar.gz" > "$DIST/php-$VERSION-sources.tar.gz.sha256"
fi

# The check's test site goes through our real Nginx. Added after packaging, so it isn't in the archive.
mkdir -p "$STAGE/nginx"
curl --fail --location --silent --show-error --retry 3 \
  "https://github.com/bedigitCom/stack-binaries/releases/download/nginx-$NGINX_VERSION/nginx-$NGINX_VERSION-$PLATFORM.tar.gz" \
  | tar -xz -C "$STAGE/nginx"
