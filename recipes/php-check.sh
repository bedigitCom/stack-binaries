#!/usr/bin/env bash
# Does a PHP build work somewhere with no build tools? Takes the folder build-php.sh made, and the
# version it should be. Only needs bash, so it can run in a bare container as an ordinary user.
source "$(dirname "$0")/lib.sh"

SOURCE="$1"
EXPECTED_VERSION="$2"
# A space in the path, as macOS's Application Support has.
BASE="$(mktemp -d)/smoke test"
mkdir -p "$BASE/site" "$BASE/run"
cp -R "$SOURCE" "$BASE/php"
PHP="$BASE/php/bin/php"
FPM="$BASE/php/bin/php-fpm"
EXT="$BASE/php/ext"
FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

echo "=== Linked libraries"
# On top of what lib.sh expects from any system: every Linux desktop that can run the app already has
# these, because its web view needs them. libutil comes with glibc.
for binary in "$PHP" "$FPM" "$EXT"/*.so; do
  if [[ "$PLATFORM" == linux-* ]]; then
    foreign="$(ldd "$binary" | awk '{print $1}' \
      | grep -vE '^(linux-vdso|linux-gate|/lib.*/ld-linux|ld-linux|libc\.|libm\.|libdl\.|libpthread\.|librt\.|libcrypt\.|libresolv\.|libutil\.|libstdc\+\+\.|libgcc_s\.)' || true)"
    missing="$(ldd "$binary" | grep 'not found' || true)"
    if [[ -n "$foreign" || -n "$missing" ]]; then
      fail "$(basename "$binary") links: $foreign $missing"
    fi
  else
    ( assert_portable "$binary" ) || fail "$(basename "$binary") links something a customer might not have"
  fi
done
pass "nothing links outside the operating system"

write_ini() {
  local skip="${1:-}"
  {
    echo "extension_dir = \"$EXT\""
    echo "date.timezone = UTC"
    echo "display_startup_errors = On"
    echo "error_reporting = E_ALL"
    echo "opcache.enable = 1"
    for file in "$EXT"/*.so; do
      local name
      name="$(basename "$file" .so)"
      [[ "$name" == "$skip" ]] && continue
      case "$name" in
        opcache | xdebug) echo "zend_extension = $name" ;;
        *) echo "extension = $name" ;;
      esac
    done
  } > "$BASE/php.ini"
}

echo "=== Every extension loads"
write_ini
env -i "$PHP" -c "$BASE/php.ini" -v
MODULES="$(env -i "$PHP" -c "$BASE/php.ini" -m 2>&1)"
if grep -qiE 'warning|unable to load|error' <<<"$MODULES"; then
  fail "PHP reported a problem while loading extensions"
  grep -iE 'warning|unable to load|error' <<<"$MODULES" | head -20
else
  pass "no warnings from any of $(ls "$EXT" | wc -l | tr -d ' ') extensions"
fi
echo "$MODULES" | tr '\n' ' '
echo

cat > "$BASE/site/index.php" <<'PHP'
<?php
echo 'php=', PHP_VERSION, "\n";
foreach (['mbstring', 'intl', 'gd', 'curl', 'pdo_pgsql', 'pdo_mysql', 'sodium', 'zip', 'xdebug', 'redis', 'imagick', 'mysqli', 'ssh2'] as $name) {
    echo $name, '=', extension_loaded($name) ? 'yes' : 'no', "\n";
}
echo 'opcache=', (function_exists('opcache_get_status') && opcache_get_status(false)) ? 'yes' : 'no', "\n";
if (extension_loaded('intl')) {
    echo 'intl_format=', (new NumberFormatter('fr_FR', NumberFormatter::DECIMAL))->format(1234.5), "\n";
}
if (extension_loaded('gd')) {
    echo 'gd_works=', imagecreatetruecolor(4, 4) ? 'yes' : 'no', "\n";
}
if (extension_loaded('imagick')) {
    $image = new Imagick();
    $image->newImage(8, 8, new ImagickPixel('red'));
    $image->setImageFormat('png');
    echo 'imagick_works=', strlen((string) $image) > 0 ? 'yes' : 'no', "\n";
}
if (extension_loaded('ssh2')) {
    // Fails cleanly on a port with nothing listening, rather than crashing.
    echo 'ssh2_works=', function_exists('ssh2_sftp') && @ssh2_connect('127.0.0.1', 1) === false ? 'yes' : 'no', "\n";
}
echo 'openssl=', strlen(openssl_random_pseudo_bytes(8)) === 8 ? 'yes' : 'no', "\n";
PHP

cat > "$BASE/php-fpm.conf" <<CONF
[global]
pid = "$BASE/run/php-fpm.pid"
error_log = "$BASE/run/php-fpm.log"
daemonize = no
[www]
listen = 127.0.0.1:18770
pm = ondemand
pm.max_children = 4
CONF

cat > "$BASE/nginx.conf" <<CONF
daemon off;
pid "$BASE/run/nginx.pid";
events { worker_connections 64; }
http {
  access_log off;
  client_body_temp_path "$BASE/run/body";
  fastcgi_temp_path "$BASE/run/fastcgi";
  proxy_temp_path "$BASE/run/proxy";
  uwsgi_temp_path "$BASE/run/uwsgi";
  scgi_temp_path "$BASE/run/scgi";
  server {
    listen 127.0.0.1:18771;
    root "$BASE/site";
    location / {
      fastcgi_pass 127.0.0.1:18770;
      fastcgi_param SCRIPT_FILENAME \$document_root/index.php;
      fastcgi_param REQUEST_METHOD \$request_method;
    }
  }
}
CONF

# Only bash, so there's nothing to install in a bare container.
page() {
  local reply="" attempt
  for attempt in $(seq 1 50); do
    if exec 3<>/dev/tcp/127.0.0.1/18771 2>/dev/null; then
      printf 'GET / HTTP/1.0\r\nHost: test\r\n\r\n' >&3
      reply="$(cat <&3)"
      exec 3<&-
      [[ "$reply" == *"php="* ]] && { echo "$reply"; return 0; }
    fi
    sleep 0.2
  done
  echo "$reply"
  cat "$BASE/run/php-fpm.log" 2>/dev/null || true
}

start_fpm() {
  env -i "$FPM" --nodaemonize --fpm-config "$BASE/php-fpm.conf" -c "$BASE/php.ini" &
  FPM_PID=$!
}
stop_fpm() {
  kill "$FPM_PID" 2>/dev/null || true
  wait "$FPM_PID" 2>/dev/null || true
}
expect() {
  if grep -qF "$2" <<<"$1"; then pass "$2"; else fail "expected $2"; fi
}

echo "=== A real site through Nginx"
env -i "$BASE/php/nginx/nginx" -p "$BASE/" -c "$BASE/nginx.conf" -e stderr &
NGINX_PID=$!
trap 'kill "$NGINX_PID" "$FPM_PID" 2>/dev/null || true' EXIT
start_fpm
REPLY_ON="$(page)"
echo "$REPLY_ON"
expect "$REPLY_ON" "php=$EXPECTED_VERSION"
for wanted in xdebug=yes mysqli=yes mbstring=yes intl=yes gd=yes curl=yes pdo_pgsql=yes pdo_mysql=yes sodium=yes zip=yes redis=yes imagick=yes imagick_works=yes ssh2=yes ssh2_works=yes opcache=yes gd_works=yes openssl=yes; do
  expect "$REPLY_ON" "$wanted"
done
# Only ICU's real data formats this the French way, with a comma, and a special space before 234.
expect "$REPLY_ON" "234,5"
stop_fpm

echo "=== Turning an extension off"
write_ini mbstring
start_fpm
REPLY_OFF="$(page)"
expect "$REPLY_OFF" "mbstring=no"
expect "$REPLY_OFF" "intl=yes"
stop_fpm

echo "=== Back on"
write_ini
start_fpm
expect "$(page)" "mbstring=yes"
stop_fpm
kill "$NGINX_PID" 2>/dev/null || true
trap - EXIT

if [[ "$FAILED" != 0 ]]; then
  echo "Some checks failed"
  exit 1
fi
echo "All checks passed on $(grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null || uname -sr)"
