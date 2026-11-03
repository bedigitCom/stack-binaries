#!/usr/bin/env bash
# Builds Valkey's server and client.
source "$(dirname "$0")/lib.sh"
build_key_value_store valkey valkey-server valkey-cli "$VALKEY_VERSION" "$VALKEY_URL" "$VALKEY_SHA256" COPYING
