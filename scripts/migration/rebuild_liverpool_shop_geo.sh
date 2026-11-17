#!/bin/sh
set -eu

PROJECT_NAME="${HMDP_COMPOSE_PROJECT:-hm-dianping}"
COMPOSE_FILE="${HMDP_COMPOSE_FILE:-dev/docker-compose.yml}"
MYSQL_PASSWORD="${HMDP_MYSQL_PASSWORD:-hmdp_local_only}"

clear_pattern() {
  pattern="$1"
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" \
    exec -T redis redis-cli --scan --pattern "$pattern" |
  while IFS= read -r key; do
    if [ -n "$key" ]; then
      docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" \
        exec -T redis redis-cli UNLINK "$key" >/dev/null
    fi
  done
}

clear_pattern "cache:shop:*"
clear_pattern "cache:voucher-list:*"

for type_id in 1 2 3 4 5 6 7 8 9 10; do
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" \
    exec -T redis redis-cli DEL "shop:geo:$type_id" >/dev/null
done

docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" \
  exec -T mysql mysql -N -B -uroot -p"$MYSQL_PASSWORD" hmdp \
  -e "SELECT type_id,id,x,y FROM tb_shop WHERE x IS NOT NULL AND y IS NOT NULL ORDER BY type_id,id" |
while IFS="$(printf '\t')" read -r type_id shop_id longitude latitude; do
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" \
    exec -T redis redis-cli GEOADD "shop:geo:$type_id" \
    "$longitude" "$latitude" "$shop_id" >/dev/null
done

echo "Cleared shop catalog caches and rebuilt Redis GEO indexes from tb_shop."
