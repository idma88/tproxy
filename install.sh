#!/usr/bin/env bash

set -u

# ============================================================
# Amnezia Telegram Web Proxy installer
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
# Colors
# ============================================================

if [ -t 1 ]; then
    RESET='\033[0m'

    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    BLUE='\033[34m'
    MAGENTA='\033[35m'
    CYAN='\033[36m'

    BOLD='\033[1m'
    DIM='\033[2m'
else
    RESET=''
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''

    BOLD=''
    DIM=''
fi


# ============================================================
# Output helpers
# ============================================================

info()
{
    printf "${BLUE}[INFO]${RESET} %s\n" "$1"
}

success()
{
    printf "${GREEN}[ OK ]${RESET} %s\n" "$1"
}

warn()
{
    printf "${YELLOW}[WARN]${RESET} %s\n" "$1"
}

error()
{
    printf "${RED}[ERROR]${RESET} %s\n" "$1" >&2
}

step()
{
    printf "\n${CYAN}${BOLD}==> %s${RESET}\n" "$1"
}

die()
{
    error "$1"
    exit 1
}

command_exists()
{
    command -v "$1" >/dev/null 2>&1
}


# ============================================================
# Header
# ============================================================

clear 2>/dev/null || true

printf "\n"
printf "${MAGENTA}${BOLD}"
printf "============================================================\n"
printf "        Amnezia Telegram Web Proxy installer\n"
printf "============================================================\n"
printf "${RESET}\n"


# ============================================================
# Root check
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    die "Запусти скрипт от root: sudo $0"
fi

success "Скрипт запущен от root"


# ============================================================
# User input
# ============================================================

step "Настройка домена"

while true; do
    read -r -p "$(printf "${CYAN}Введите domain${RESET} (например proxy.example.com): ")" TPROXY_HOSTNAME < /dev/tty

    TPROXY_HOSTNAME="$(printf '%s' "$TPROXY_HOSTNAME" \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [ -n "$TPROXY_HOSTNAME" ]; then
        break
    fi

    warn "Domain не может быть пустым. Повторите ввод."
done

success "Domain: ${TPROXY_HOSTNAME}"


step "Настройка Let's Encrypt"

while true; do
    read -r -p "$(printf "${CYAN}Введите email для Let's Encrypt${RESET} (например admin@example.com): ")" TPROXY_ACME_EMAIL < /dev/tty

    TPROXY_ACME_EMAIL="$(printf '%s' "$TPROXY_ACME_EMAIL" \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [ -n "$TPROXY_ACME_EMAIL" ]; then
        break
    fi

    warn "Email не может быть пустым. Повторите ввод."
done

success "Email: ${TPROXY_ACME_EMAIL}"


# ============================================================
# Dependencies
# ============================================================

step "Проверка зависимостей"

export DEBIAN_FRONTEND=noninteractive

if ! command_exists docker; then
    info "Docker не найден. Устанавливаю docker.io..."

    apt-get update || die "Не удалось выполнить apt-get update"

    apt-get install -y docker.io \
        || die "Не удалось установить Docker"

    systemctl enable --now docker \
        || die "Не удалось запустить Docker"

    success "Docker установлен"
else
    success "Docker уже установлен"
fi


if ! command_exists curl; then
    info "curl не найден. Устанавливаю..."

    apt-get update || die "Не удалось выполнить apt-get update"

    apt-get install -y curl \
        || die "Не удалось установить curl"

    success "curl установлен"
else
    success "curl уже установлен"
fi


if ! command_exists ca-certificates; then
    :
fi

if ! dpkg -s ca-certificates >/dev/null 2>&1; then
    info "Устанавливаю ca-certificates..."

    apt-get update || die "Не удалось выполнить apt-get update"

    apt-get install -y ca-certificates \
        || die "Не удалось установить ca-certificates"

    success "ca-certificates установлен"
else
    success "ca-certificates уже установлен"
fi


# ============================================================
# Docker check
# ============================================================

step "Проверка Docker"

docker info >/dev/null 2>&1 \
    || die "Docker daemon недоступен"

success "Docker daemon работает"


# ============================================================
# Port check
# ============================================================

step "Проверка портов"

if command_exists ss; then

    if ss -ltn "( sport = :${TPROXY_HTTP_PORT} )" 2>/dev/null \
        | grep -q ":${TPROXY_HTTP_PORT}"; then

        die "Порт ${TPROXY_HTTP_PORT} уже занят"
    fi

    if ss -ltn "( sport = :${TPROXY_HTTPS_PORT} )" 2>/dev/null \
        | grep -q ":${TPROXY_HTTPS_PORT}"; then

        die "Порт ${TPROXY_HTTPS_PORT} уже занят"
    fi

    success "Порты ${TPROXY_HTTP_PORT} и ${TPROXY_HTTPS_PORT} свободны"

else
    warn "Команда ss не найдена. Проверка портов пропущена."
fi


# ============================================================
# Prepare directory
# ============================================================

step "Подготовка файлов"

mkdir -p "$SCRIPT_DIR" \
    || die "Не удалось создать ${SCRIPT_DIR}"

success "Каталог создан: ${SCRIPT_DIR}"


# ============================================================
# Download upstream files
# ============================================================

download_file()
{
    local url="$1"
    local destination="$2"
    local name="$3"

    info "Скачиваю ${name}..."

    curl -fsSL "$url" -o "$destination" \
        || die "Не удалось скачать ${name}"

    [ -s "$destination" ] \
        || die "Файл ${name} пустой"

    success "${name} скачан"
}


download_file \
    "${RAW_BASE}/Dockerfile" \
    "${SCRIPT_DIR}/Dockerfile" \
    "Dockerfile"


download_file \
    "${RAW_BASE}/configure_container.sh" \
    "${SCRIPT_DIR}/configure_container.sh" \
    "configure_container.sh"


download_file \
    "${RAW_BASE}/start.sh" \
    "${SCRIPT_DIR}/start.sh" \
    "start.sh"


chmod +x \
    "${SCRIPT_DIR}/configure_container.sh" \
    "${SCRIPT_DIR}/start.sh"


# ============================================================
# Build Docker image
# ============================================================

step "Сборка Docker image"

info "Image: ${IMAGE_NAME}"
info "Это может занять некоторое время..."

docker build \
    --no-cache \
    --pull \
    -t "$IMAGE_NAME" \
    "$SCRIPT_DIR" \
    || die "Не удалось собрать Docker image"

success "Docker image успешно собран"


# ============================================================
# Remove old container
# ============================================================

step "Подготовка контейнера"

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    warn "Существующий контейнер ${CONTAINER_NAME} найден"

    info "Останавливаю контейнер..."

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 \
        || die "Не удалось удалить старый контейнер"

    success "Старый контейнер удалён"
else
    info "Старый контейнер не найден"
fi


# ============================================================
# Create persistent volume
# ============================================================

if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
    success "Docker volume ${VOLUME_NAME} уже существует"
else
    info "Создаю Docker volume ${VOLUME_NAME}..."

    docker volume create "$VOLUME_NAME" >/dev/null \
        || die "Не удалось создать Docker volume"

    success "Docker volume создан"
fi


# ============================================================
# Run container
# ============================================================

step "Запуск контейнера"

info "Container: ${CONTAINER_NAME}"
info "HTTP port:  ${TPROXY_HTTP_PORT}"
info "HTTPS port: ${TPROXY_HTTPS_PORT}"

docker run -d \
    --log-driver none \
    --restart always \
    -p "${TPROXY_HTTP_PORT}:80/tcp" \
    -p "${TPROXY_HTTPS_PORT}:443/tcp" \
    -v "${VOLUME_NAME}:/data" \
    --name "$CONTAINER_NAME" \
    "$IMAGE_NAME" \
    >/dev/null \
    || die "Не удалось запустить контейнер"

success "Контейнер запущен"


# ============================================================
# Copy configure script
# ============================================================

step "Конфигурация Telegram Web Proxy"

info "Копирую configure_container.sh в контейнер..."

docker cp \
    "${SCRIPT_DIR}/configure_container.sh" \
    "${CONTAINER_NAME}:/opt/amnezia/configure_container.sh" \
    || die "Не удалось скопировать configure_container.sh"

success "configure_container.sh скопирован"


# ============================================================
# Configure container
# ============================================================

info "Запускаю конфигурацию..."

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
    /bin/sh /opt/amnezia/configure_container.sh \
    || die "Не удалось настроить Telegram Web Proxy"

success "Конфигурация успешно создана"


# ============================================================
# Copy start.sh
# ============================================================

info "Копирую start.sh в контейнер..."

docker cp \
    "${SCRIPT_DIR}/start.sh" \
    "${CONTAINER_NAME}:/opt/amnezia/start.sh" \
    || die "Не удалось скопировать start.sh"

docker exec \
    "$CONTAINER_NAME" \
    chmod +x /opt/amnezia/start.sh \
    || die "Не удалось сделать start.sh исполняемым"

success "start.sh установлен"


# ============================================================
# Restart container
# ============================================================

step "Перезапуск контейнера"

docker restart "$CONTAINER_NAME" >/dev/null \
    || die "Не удалось перезапустить контейнер"

success "Контейнер перезапущен"


# ============================================================
# Wait
# ============================================================

info "Ожидаю запуск сервисов..."

sleep 3


# ============================================================
# Container status
# ============================================================

step "Проверка состояния"

if docker inspect \
    -f '{{.State.Running}}' \
    "$CONTAINER_NAME" 2>/dev/null \
    | grep -q "true"; then

    success "Контейнер ${CONTAINER_NAME} работает"

else
    error "Контейнер ${CONTAINER_NAME} не запущен"

    warn "Проверь состояние командой:"
    printf "  ${YELLOW}docker ps -a${RESET}\n"

    exit 1
fi


# ============================================================
# Read secret
# ============================================================

step "Получение Telegram Proxy secret"

TPROXY_SECRET="$(docker exec \
    "$CONTAINER_NAME" \
    /bin/sh -c 'cat /data/secret 2>/dev/null' \
    | tr -d '\r\n' \
    || true)"

if [ -z "$TPROXY_SECRET" ]; then
    warn "Secret пока не найден в /data/secret"
    warn "Контейнер может ещё завершать настройку."

    printf "\n"
    printf "${YELLOW}Проверь через несколько секунд:${RESET}\n"
    printf "  ${CYAN}docker exec %s cat /data/secret${RESET}\n" \
        "$CONTAINER_NAME"

    exit 0
fi

success "Telegram Proxy secret получен"


# ============================================================
# Final information
# ============================================================

printf "\n"

printf "${GREEN}${BOLD}"
printf "============================================================\n"
printf "              Установка завершена\n"
printf "============================================================\n"
printf "${RESET}\n"

printf "${BOLD}Domain:${RESET}       %s\n" "$TPROXY_HOSTNAME"
printf "${BOLD}Email:${RESET}        %s\n" "$TPROXY_ACME_EMAIL"
printf "${BOLD}Container:${RESET}    %s\n" "$CONTAINER_NAME"
printf "${BOLD}HTTP:${RESET}         %s\n" "$TPROXY_HTTP_PORT"
printf "${BOLD}HTTPS:${RESET}        %s\n" "$TPROXY_HTTPS_PORT"

printf "\n"

printf "${BOLD}${CYAN}Telegram Web Proxy:${RESET}\n"
printf "  ${GREEN}https://%s${RESET}\n" "$TPROXY_HOSTNAME"

printf "\n"

printf "${BOLD}${CYAN}Secret:${RESET}\n"
printf "  ${YELLOW}%s${RESET}\n" "$TPROXY_SECRET"

printf "\n"

printf "${BOLD}${CYAN}Telegram proxy links:${RESET}\n"

printf "  ${GREEN}tg://proxy?server=%s&port=%s&secret=%s${RESET}\n" \
    "$TPROXY_HOSTNAME" \
    "$TPROXY_HTTPS_PORT" \
    "$TPROXY_SECRET"

printf "\n"

printf "${DIM}Контейнер автоматически запустится после перезагрузки VPS.${RESET}\n"
printf "${DIM}Docker volume ${VOLUME_NAME} сохраняет данные между перезапусками.${RESET}\n"

printf "\n"

printf "${BOLD}Проверка:${RESET}\n"
printf "  ${CYAN}docker ps${RESET}\n"

printf "\n"
printf "${GREEN}${BOLD}Готово!${RESET}\n"
printf "\n"
