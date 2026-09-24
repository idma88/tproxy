#!/usr/bin/env bash

set -u

# ============================================================
# Amnezia Telegram Web Proxy installer
# Based on:
# https://github.com/amnezia-vpn/amnezia-client/tree/dev/client/server_scripts/tproxy
# ============================================================

CONTAINER_NAME="amnezia-tproxy"
IMAGE_NAME="amnezia-tproxy"
VOLUME_NAME="amnezia-tproxy-data"

TPROXY_HTTP_PORT="80"
TPROXY_HTTPS_PORT="443"
TPROXY_CARRIER_MODE="https"
TPROXY_WORKERS="1"

SCRIPT_DIR="/opt/amnezia/${CONTAINER_NAME}"

RAW_BASE="https://raw.githubusercontent.com/amnezia-vpn/amnezia-client/dev/client/server_scripts/tproxy"


# ============================================================
# Helpers
# ============================================================

die()
{
    echo
    echo "[!] ERROR: $*" >&2
    exit 1
}

info()
{
    echo "[*] $*"
}

success()
{
    echo "[+] $*"
}


# ============================================================
# Check root
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    die "Запусти скрипт от root: sudo $0"
fi


# ============================================================
# Ask domain
# ============================================================

while true; do
    read -r -p "Введите domain (например proxy.example.com): " TPROXY_HOSTNAME

    # Убираем пробелы по краям
    TPROXY_HOSTNAME="$(printf '%s' "$TPROXY_HOSTNAME" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [ -n "$TPROXY_HOSTNAME" ]; then
        break
    fi

    echo "[!] Domain не может быть пустым. Повторите ввод."
done


# ============================================================
# Ask email
# ============================================================

while true; do
    read -r -p "Введите email для Let's Encrypt (например admin@example.com): " TPROXY_ACME_EMAIL

    TPROXY_ACME_EMAIL="$(printf '%s' "$TPROXY_ACME_EMAIL" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [ -n "$TPROXY_ACME_EMAIL" ]; then
        break
    fi

    echo "[!] Email не может быть пустым. Повторите ввод."
done


# ============================================================
# Show configuration
# ============================================================

echo
echo "=============================================="
echo " Telegram Web Proxy configuration"
echo "=============================================="
echo "Domain : $TPROXY_HOSTNAME"
echo "Email  : $TPROXY_ACME_EMAIL"
echo "HTTP   : $TPROXY_HTTP_PORT"
echo "HTTPS  : $TPROXY_HTTPS_PORT"
echo "Carrier: $TPROXY_CARRIER_MODE"
echo "Workers: $TPROXY_WORKERS"
echo "=============================================="
echo


# ============================================================
# Check / install Docker
# ============================================================

if ! command -v docker >/dev/null 2>&1; then
    info "Docker не найден. Устанавливаю..."

    apt-get update || die "Не удалось выполнить apt-get update"

    apt-get install -y docker.io curl ca-certificates || \
        die "Не удалось установить docker.io"

    systemctl enable --now docker || \
        die "Не удалось запустить Docker"

    success "Docker установлен"
else
    info "Docker уже установлен"
fi


# ============================================================
# Check Docker daemon
# ============================================================

docker info >/dev/null 2>&1 || {
    info "Docker daemon не запущен. Запускаю..."
    systemctl enable --now docker || \
        die "Не удалось запустить Docker daemon"
}

docker info >/dev/null 2>&1 || \
    die "Docker daemon недоступен"


# ============================================================
# Check ports
# ============================================================

if command -v ss >/dev/null 2>&1; then

    if ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)80$'; then
        die "TCP порт 80 уже занят"
    fi

    if ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)443$'; then
        die "TCP порт 443 уже занят"
    fi

fi


# ============================================================
# Prepare directory
# ============================================================

info "Создаю $SCRIPT_DIR"

mkdir -p "$SCRIPT_DIR" || \
    die "Не удалось создать $SCRIPT_DIR"

cd "$SCRIPT_DIR" || \
    die "Не удалось перейти в $SCRIPT_DIR"


# ============================================================
# Download current Amnezia TProxy files
# ============================================================

info "Загружаю актуальные файлы Amnezia..."

curl -fsSL \
    "${RAW_BASE}/Dockerfile" \
    -o Dockerfile || \
    die "Не удалось скачать Dockerfile"

curl -fsSL \
    "${RAW_BASE}/configure_container.sh" \
    -o configure_container.sh || \
    die "Не удалось скачать configure_container.sh"

curl -fsSL \
    "${RAW_BASE}/start.sh" \
    -o start.sh || \
    die "Не удалось скачать start.sh"

chmod +x configure_container.sh start.sh


# ============================================================
# Build Docker image
# ============================================================

info "Собираю Docker image: $IMAGE_NAME"

docker build \
    --no-cache \
    --pull \
    -t "$IMAGE_NAME" \
    "$SCRIPT_DIR" || \
    die "Не удалось собрать Docker image"

success "Docker image собран"


# ============================================================
# Remove old container if it exists
# ============================================================

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then

    info "Найден существующий контейнер $CONTAINER_NAME"

    info "Останавливаю старый контейнер..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || \
        die "Не удалось удалить старый контейнер"

fi


# ============================================================
# Create volume
# ============================================================

if ! docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
    info "Создаю Docker volume $VOLUME_NAME"

    docker volume create "$VOLUME_NAME" >/dev/null || \
        die "Не удалось создать Docker volume"
else
    info "Docker volume $VOLUME_NAME уже существует"
fi


# ============================================================
# Run container
# ============================================================

info "Запускаю контейнер $CONTAINER_NAME"

docker run -d \
    --log-driver none \
    --restart always \
    -p "${TPROXY_HTTP_PORT}:80/tcp" \
    -p "${TPROXY_HTTPS_PORT}:443/tcp" \
    -v "${VOLUME_NAME}:/data" \
    --name "$CONTAINER_NAME" \
    "$IMAGE_NAME" || \
    die "Не удалось запустить контейнер"

success "Контейнер запущен"


# ============================================================
# Wait until container is running
# ============================================================

info "Жду запуска контейнера..."

for i in $(seq 1 30); do

    STATUS="$(docker inspect \
        -f '{{.State.Running}}' \
        "$CONTAINER_NAME" 2>/dev/null || true)"

    if [ "$STATUS" = "true" ]; then
        break
    fi

    sleep 1

done

STATUS="$(docker inspect \
    -f '{{.State.Running}}' \
    "$CONTAINER_NAME" 2>/dev/null || true)"

[ "$STATUS" = "true" ] || \
    die "Контейнер не запустился"


# ============================================================
# Copy configure script into container
# ============================================================

info "Копирую configure_container.sh в контейнер"

docker cp \
    configure_container.sh \
    "${CONTAINER_NAME}:/opt/amnezia/configure_container.sh" || \
    die "Не удалось скопировать configure_container.sh"

docker exec "$CONTAINER_NAME" \
    chmod +x /opt/amnezia/configure_container.sh || \
    die "Не удалось сделать configure_container.sh исполняемым"


# ============================================================
# Configure TProxy
# ============================================================

info "Настраиваю Telegram Web Proxy..."

docker exec \
    -e TPROXY_SECRET="" \
    -e TPROXY_REGENERATE_SECRET="0" \
    -e TPROXY_HOSTNAME="$TPROXY_HOSTNAME" \
    -e TPROXY_ACME_EMAIL="$TPROXY_ACME_EMAIL" \
    -e TPROXY_HTTPS_PORT="$TPROXY_HTTPS_PORT" \
    -e TPROXY_HTTP_PORT="$TPROXY_HTTP_PORT" \
    -e TPROXY_CARRIER_MODE="$TPROXY_CARRIER_MODE" \
    -e TPROXY_WORKERS="$TPROXY_WORKERS" \
    "$CONTAINER_NAME" \
    /bin/sh /opt/amnezia/configure_container.sh || \
    die "Не удалось сконфигурировать TProxy"


# ============================================================
# Copy actual start.sh
# ============================================================

info "Устанавливаю startup script"

docker cp \
    start.sh \
    "${CONTAINER_NAME}:/opt/amnezia/start.sh" || \
    die "Не удалось скопировать start.sh"

docker exec "$CONTAINER_NAME" \
    chmod +x /opt/amnezia/start.sh || \
    die "Не удалось сделать start.sh исполняемым"


# ============================================================
# Restart container
# ============================================================

info "Перезапускаю контейнер..."

docker restart "$CONTAINER_NAME" >/dev/null || \
    die "Не удалось перезапустить контейнер"


# ============================================================
# Wait
# ============================================================

sleep 3


# ============================================================
# Check status
# ============================================================

STATUS="$(docker inspect \
    -f '{{.State.Running}}' \
    "$CONTAINER_NAME" 2>/dev/null || true)"

if [ "$STATUS" != "true" ]; then

    echo
    echo "[!] Контейнер не работает."
    echo
    echo "Последние логи:"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -100

    exit 1
fi


# ============================================================
# Get secret
# ============================================================

SECRET="$(docker exec "$CONTAINER_NAME" \
    cat /data/secret 2>/dev/null || true)"

if [ -z "$SECRET" ]; then
    die "Не удалось получить /data/secret"
fi


# ============================================================
# Final information
# ============================================================

echo
echo "============================================================"
echo " Telegram Web Proxy успешно установлен"
echo "============================================================"
echo
echo "Container:"
echo "  $CONTAINER_NAME"
echo
echo "Domain:"
echo "  $TPROXY_HOSTNAME"
echo
echo "HTTP:"
echo "  http://${TPROXY_HOSTNAME}:80"
echo
echo "HTTPS:"
echo "  https://${TPROXY_HOSTNAME}:443"
echo
echo "Secret:"
echo "  $SECRET"
echo
echo "Telegram Web Proxy:"
echo
echo "  https://t.me/webproxy?server=${TPROXY_HOSTNAME}&secret=${SECRET}"
echo
echo "  tg://webproxy?server=${TPROXY_HOSTNAME}&secret=${SECRET}"
echo
echo "============================================================"
echo
echo "Проверка контейнера:"
echo "  docker ps --filter name=${CONTAINER_NAME}"
echo
echo "Логи:"
echo "  docker logs ${CONTAINER_NAME}"
echo
echo "Конфигурация:"
echo "  docker exec ${CONTAINER_NAME} cat /data/tproxy-meta"
echo
echo "Secret:"
echo "  docker exec ${CONTAINER_NAME} cat /data/secret"
echo
echo "============================================================"
