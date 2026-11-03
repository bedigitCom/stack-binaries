#!/usr/bin/env bash
# Builds Redis's server and client, under the AGPL, the one of its three licenses we distribute it
# under. Redis's optional modules aren't included.
source "$(dirname "$0")/lib.sh"
build_key_value_store redis redis-server redis-cli "$REDIS_VERSION" "$REDIS_URL" "$REDIS_SHA256" LICENSE.txt REDISCONTRIBUTIONS.txt
