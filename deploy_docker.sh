#!/usr/bin/env bash
set -Eeuo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
PROJECT_DIR="$(pwd)"; HOST_UID="$(id -u)"; HOST_GID="$(id -g)"
INSTALL_COMPLETED=false; BOOTSTRAP_DOCKERFILE=""; BOOTSTRAP_IMAGE="craft-composer-bootstrap:php84"

info(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warning(){ echo -e "${YELLOW}[AVISO]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }
cleanup_on_error(){
  local rc=$?
  if [[ "$INSTALL_COMPLETED" != true ]]; then
    error "La instalación se ha interrumpido."
    [[ -n "${BOOTSTRAP_DOCKERFILE:-}" ]] && rm -f "$BOOTSTRAP_DOCKERFILE" || true
    rm -rf "$PROJECT_DIR/.composer-cache" || true
    command -v docker >/dev/null 2>&1 && docker image rm "$BOOTSTRAP_IMAGE" >/dev/null 2>&1 || true
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && [[ -f docker-compose.yml ]]; then
      warning "Eliminando contenedores y volúmenes del despliegue incompleto..."
      docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
  fi
  exit "$rc"
}
trap cleanup_on_error ERR INT TERM

echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE} Craft CMS 5 · PHP 8.4 · MySQL / PostgreSQL${NC}"
echo -e "${BLUE} SFTP restringido · UFW + DOCKER-USER${NC}"
echo -e "${BLUE}====================================================${NC}"

[[ "$EUID" -ne 0 ]] || { error "No ejecutes este script como root."; exit 1; }
[[ -t 0 ]] || { error "El script necesita una terminal interactiva."; exit 1; }

echo -e "¿Qué base de datos deseas usar?"
echo -e "  1) MySQL 8.4 (Debian)"
echo -e "  2) PostgreSQL 18 (Alpine - Optimizado)"
read -r -p "Selecciona una opción [1/2]: " DB_OPTION
if [[ "$DB_OPTION" == "2" ]]; then
  DB_TYPE="pgsql"
  info "Has seleccionado PostgreSQL 18 (Alpine)."
else
  DB_TYPE="mysql"
  info "Has seleccionado MySQL 8.4 (Debian)."
fi

read -r -p "Dominio principal (ej. craft.edresearch.es): " DOMAIN_NAME
read -r -p "Correo para Let's Encrypt y administrador: " ADMIN_EMAIL
DOMAIN_NAME="${DOMAIN_NAME,,}"; DOMAIN_NAME="${DOMAIN_NAME#http://}"; DOMAIN_NAME="${DOMAIN_NAME#https://}"; DOMAIN_NAME="${DOMAIN_NAME%%/*}"; DOMAIN_NAME="${DOMAIN_NAME%.}"
[[ -n "$DOMAIN_NAME" && -n "$ADMIN_EMAIL" ]] || { error "Dominio y correo son obligatorios."; exit 1; }
if [[ "$DOMAIN_NAME" != *.* || "$DOMAIN_NAME" == .* || "$DOMAIN_NAME" == *. || "$DOMAIN_NAME" == *..* || "$DOMAIN_NAME" == -* || "$DOMAIN_NAME" == *- || "$DOMAIN_NAME" == *.-* || "$DOMAIN_NAME" == *-.* || "$DOMAIN_NAME" == *[!a-z0-9.-]* ]]; then error "Dominio no válido: $DOMAIN_NAME"; exit 1; fi
[[ "$ADMIN_EMAIL" == *@*.* && "$ADMIN_EMAIL" != *' '* ]] || { error "Correo no válido: $ADMIN_EMAIL"; exit 1; }
[[ ! -f .env && ! -f docker-compose.yml ]] || { error "Usa un directorio vacío."; exit 1; }
command -v openssl >/dev/null 2>&1 || { error "Falta OpenSSL."; exit 1; }

if ! command -v docker >/dev/null 2>&1; then
  info "Instalando Docker..."
  command -v curl >/dev/null 2>&1 || { sudo apt-get update; sudo apt-get install -y curl ca-certificates; }
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
  warning "Docker instalado. Cierra la sesión SSH, vuelve a entrar y ejecuta de nuevo el script."
  exit 0
fi
docker info >/dev/null 2>&1 || { error "Tu usuario no puede comunicarse con Docker."; exit 1; }
docker compose version >/dev/null 2>&1 || { error "No se encuentra Docker Compose."; exit 1; }

info "Generando credenciales..."
DB_ROOT_PASSWORD="$(openssl rand -hex 24)"; DB_PASSWORD="$(openssl rand -hex 24)"
CRAFT_SECURITY_KEY="$(openssl rand -base64 48 | tr -d '\n')"; ADMIN_PASS="$(openssl rand -hex 12)"
SFTP_USER="craft_sftp"; SFTP_PASSWORD="$(openssl rand -hex 18)"; SFTP_PORT=2222
COMPOSE_PROJECT="craft_${DOMAIN_NAME//./_}"; CRAFT_APP_ID="CraftCMS-${DOMAIN_NAME//./-}"

info "Creando imagen temporal de Composer..."
BOOTSTRAP_DOCKERFILE="$(mktemp)"
if [[ "$DB_TYPE" == "pgsql" ]]; then
  BOOTSTRAP_BASE="serversideup/php:8.4-cli-alpine"
  BOOTSTRAP_EXT="bcmath gd imagick intl soap pdo_pgsql redis"
else
  BOOTSTRAP_BASE="serversideup/php:8.4-cli"
  BOOTSTRAP_EXT="bcmath gd imagick intl soap pdo_mysql redis"
fi

cat > "$BOOTSTRAP_DOCKERFILE" <<DOCKERFILE
FROM $BOOTSTRAP_BASE
USER root
RUN install-php-extensions $BOOTSTRAP_EXT
WORKDIR /var/www/html
DOCKERFILE

docker build --pull -f "$BOOTSTRAP_DOCKERFILE" -t "$BOOTSTRAP_IMAGE" /tmp
rm -f "$BOOTSTRAP_DOCKERFILE"; BOOTSTRAP_DOCKERFILE=""

info "Descargando Craft y dependencias en el host..."
mkdir -p .composer-cache; sudo chown -R "$HOST_UID:$HOST_GID" .composer-cache
docker run --rm --user "$HOST_UID:$HOST_GID" -e HOME=/tmp -e COMPOSER_HOME=/tmp/composer -e COMPOSER_CACHE_DIR=/tmp/composer/cache \
  -v "$PROJECT_DIR:/var/www/html" -v "$PROJECT_DIR/.composer-cache:/tmp/composer/cache" -w /var/www/html "$BOOTSTRAP_IMAGE" sh -lc '
    set -e
    composer create-project --no-interaction --prefer-dist --no-progress craftcms/craft tmp-project
    cp -a tmp-project/. /var/www/html/
    rm -rf tmp-project
    composer require --no-interaction --prefer-dist --no-progress yiisoft/yii2-redis
  '
rm -rf .composer-cache; docker image rm "$BOOTSTRAP_IMAGE" >/dev/null 2>&1 || true
mkdir -p caddy_data caddy_config config/project storage/backups storage/composer/cache web/cpresources templates
touch config/license.key storage/.gitkeep web/cpresources/.gitkeep

cat > config/general.php <<'PHP'
<?php
use craft\config\GeneralConfig;
use craft\helpers\App;
return GeneralConfig::create()
    ->allowAdminChanges(App::env('CRAFT_ALLOW_ADMIN_CHANGES') === true)
    ->allowUpdates(App::env('CRAFT_ALLOW_UPDATES') === true)
    ->runQueueAutomatically(false)
    ->devMode(false)
    ->omitScriptNameInUrls()
    ->preventUserEnumeration()
    ->aliases(['@webroot' => dirname(__DIR__) . '/web']);
PHP
cat > config/app.php <<'PHP'
<?php
use craft\behaviors\SessionBehavior;
use craft\helpers\App;
use yii\redis\Cache;
use yii\redis\Connection;
use yii\redis\Session;
return [
  'id' => App::env('CRAFT_APP_ID') ?: 'craft-production',
  'components' => [
    'redisCache' => ['class'=>Connection::class,'hostname'=>'redis_cache','port'=>6379,'database'=>0],
    'redisSession' => ['class'=>Connection::class,'hostname'=>'redis_session','port'=>6379,'database'=>0],
    'cache' => ['class'=>Cache::class,'redis'=>'redisCache','defaultDuration'=>86400],
    'session' => ['class'=>Session::class,'redis'=>'redisSession','as session'=>['class'=>SessionBehavior::class]],
  ],
];
PHP

if [[ "$DB_TYPE" == "pgsql" ]]; then
  CRAFT_DB_PORT=5432
else
  CRAFT_DB_PORT=3306
fi

cat > .env <<EOF
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT}
DOMAIN_NAME=${DOMAIN_NAME}
ADMIN_EMAIL=${ADMIN_EMAIL}
CRAFT_ENVIRONMENT=production
CRAFT_ALLOW_ADMIN_CHANGES=true
CRAFT_ALLOW_UPDATES=true
CRAFT_APP_ID=${CRAFT_APP_ID}
CRAFT_SECURITY_KEY=${CRAFT_SECURITY_KEY}
PRIMARY_SITE_URL=https://${DOMAIN_NAME}
CRAFT_DB_DRIVER=${DB_TYPE}
CRAFT_DB_SERVER=db
CRAFT_DB_PORT=${CRAFT_DB_PORT}
CRAFT_DB_DATABASE=craft_db
CRAFT_DB_USER=craft_user
CRAFT_DB_PASSWORD=${DB_PASSWORD}
EOF

if [[ "$DB_TYPE" == "mysql" ]]; then
  echo "CRAFT_DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}" >> .env
fi

cat >> .env <<EOF
CRAFT_DB_SCHEMA=public
CRAFT_DB_TABLE_PREFIX=
CRAFT_STREAM_LOG=true
CRAFT_BACKUP_ON_UPDATE=true
SFTP_USER=${SFTP_USER}
SFTP_PASSWORD=${SFTP_PASSWORD}
SFTP_PORT=${SFTP_PORT}
SFTP_UID=${HOST_UID}
SFTP_GID=0
EOF
chmod 600 .env

cat > .dockerignore <<'EOF'
.git
.env
.install-credentials
.composer-cache
caddy_data
caddy_config
storage
web/cpresources
node_modules
EOF
cat >> .gitignore <<'EOF'
.env
.install-credentials
.composer-cache/
/caddy_data/
/caddy_config/
/storage/*
!/storage/.gitkeep
/web/cpresources/*
!/web/cpresources/.gitkeep
/node_modules/
EOF

cat > Caddyfile <<EOF
{
  email ${ADMIN_EMAIL}
}
${DOMAIN_NAME} {
  encode zstd gzip
  reverse_proxy app:8080
  header {
    -Server
    X-Content-Type-Options "nosniff"
    X-Frame-Options "SAMEORIGIN"
    Referrer-Policy "strict-origin-when-cross-origin"
    Permissions-Policy "camera=(), microphone=(), geolocation=()"
  }
  log {
    output stdout
    format json
  }
}
EOF

if [[ "$DB_TYPE" == "pgsql" ]]; then
cat > web.Dockerfile <<'DOCKERFILE'
FROM serversideup/php:8.4-fpm-nginx-alpine
USER root
RUN set -eux; \
 apk update; \
 apk add --no-cache ca-certificates curl gnupg postgresql-client; \
 install-php-extensions bcmath gd imagick intl soap pdo_pgsql redis; \
 pg_dump --version
ENV PHP_OPCACHE_ENABLE=1 PHP_OPCACHE_MEMORY_CONSUMPTION=256 PHP_OPCACHE_INTERNED_STRINGS_BUFFER=32 PHP_OPCACHE_MAX_ACCELERATED_FILES=20000 PHP_OPCACHE_VALIDATE_TIMESTAMPS=1 PHP_OPCACHE_REVALIDATE_FREQ=2 PHP_OPCACHE_SAVE_COMMENTS=1 PHP_MEMORY_LIMIT=512M PHP_MAX_INPUT_VARS=5000 PHP_POST_MAX_SIZE=64M PHP_UPLOAD_MAX_FILE_SIZE=64M NGINX_WEBROOT=/var/www/html/web CRAFT_STREAM_LOG=true
WORKDIR /var/www/html
USER www-data
DOCKERFILE

cat > cli.Dockerfile <<'DOCKERFILE'
FROM serversideup/php:8.4-cli-alpine
USER root
RUN set -eux; \
 apk update; \
 apk add --no-cache ca-certificates curl gnupg postgresql-client; \
 install-php-extensions bcmath gd imagick intl soap pdo_pgsql redis; \
 pg_dump --version
ENV PHP_MEMORY_LIMIT=768M CRAFT_STREAM_LOG=true
WORKDIR /var/www/html
USER www-data
ENTRYPOINT ["php", "/var/www/html/craft"]
CMD ["queue/listen", "--verbose=1"]
DOCKERFILE

cat > docker-compose.yml <<'YAML'
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports: ["80:80", "443:443", "443:443/udp"]
    volumes: ["./Caddyfile:/etc/caddy/Caddyfile:ro", "./caddy_data:/data", "./caddy_config:/config"]
    networks: [craft_net]
    depends_on: {app: {condition: service_started}}
  app:
    build: {context: ., dockerfile: web.Dockerfile}
    restart: unless-stopped
    env_file: [.env]
    environment:
      COMPOSER_HOME: /var/www/html/storage/composer
      COMPOSER_CACHE_DIR: /var/www/html/storage/composer/cache
      PHP_FPM_POOL_NAME: www
      PHP_FPM_PM_CONTROL: dynamic
      PHP_FPM_PM_MAX_CHILDREN: "12"
      PHP_FPM_PM_START_SERVERS: "3"
      PHP_FPM_PM_MIN_SPARE_SERVERS: "2"
      PHP_FPM_PM_MAX_SPARE_SERVERS: "5"
      PHP_FPM_PM_MAX_REQUESTS: "500"
    volumes: ["./:/var/www/html"]
    networks: [craft_net]
    depends_on: {db: {condition: service_healthy}, redis_cache: {condition: service_healthy}, redis_session: {condition: service_healthy}}
  cli:
    build: {context: ., dockerfile: cli.Dockerfile}
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    env_file: [.env]
    environment: {COMPOSER_HOME: /var/www/html/storage/composer, COMPOSER_CACHE_DIR: /var/www/html/storage/composer/cache}
    volumes: ["./:/var/www/html"]
    networks: [craft_net]
    depends_on: {db: {condition: service_healthy}, redis_cache: {condition: service_healthy}, redis_session: {condition: service_healthy}}
    command: ["queue/listen", "--verbose=1"]
  db:
    image: postgres:18-alpine
    restart: unless-stopped
    environment: {POSTGRES_USER: "${CRAFT_DB_USER}", POSTGRES_PASSWORD: "${CRAFT_DB_PASSWORD}", POSTGRES_DB: "${CRAFT_DB_DATABASE}"}
    volumes: [db_data:/var/lib/postgresql]
    networks: [craft_net]
    healthcheck: {test: ["CMD-SHELL", "pg_isready -U \"$${POSTGRES_USER}\" -d \"$${POSTGRES_DB}\""], interval: 10s, timeout: 5s, retries: 12, start_period: 30s}
  redis_cache:
    image: redis:7
    restart: unless-stopped
    command: ["redis-server", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru", "--save", ""]
    networks: [craft_net]
    healthcheck: {test: ["CMD", "redis-cli", "ping"], interval: 10s, timeout: 5s, retries: 5}
  redis_session:
    image: redis:7
    restart: unless-stopped
    command: ["redis-server", "--maxmemory", "256mb", "--maxmemory-policy", "noeviction", "--appendonly", "yes", "--appendfsync", "everysec"]
    volumes: [redis_session_data:/data]
    networks: [craft_net]
    healthcheck: {test: ["CMD", "redis-cli", "ping"], interval: 10s, timeout: 5s, retries: 5}
  sftp:
    image: atmoz/sftp:debian
    restart: unless-stopped
    ports: ["${SFTP_PORT}:22"]
    command: "${SFTP_USER}:${SFTP_PASSWORD}:${SFTP_UID}:${SFTP_GID}:templates,web,project,backups"
    volumes:
      - ./templates:/home/${SFTP_USER}/templates
      - ./web:/home/${SFTP_USER}/web
      - ./config/project:/home/${SFTP_USER}/project
      - ./storage/backups:/home/${SFTP_USER}/backups
    networks: [craft_net]
volumes:
  db_data:
  redis_session_data:
networks:
  craft_net: {driver: bridge}
YAML

else

cat > web.Dockerfile <<'DOCKERFILE'
FROM serversideup/php:8.4-fpm-nginx
USER root
ARG MYSQL_APT_CONFIG_VERSION=0.8.40-1
ARG MYSQL_APT_CONFIG_MD5=981ff0a16aab27a0cd97f4c4ee49e9fd
RUN set -eux; \
 apt-get update; \
 DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl debconf gnupg lsb-release wget; \
 wget -qO /tmp/mysql-apt.deb "https://dev.mysql.com/get/mysql-apt-config_${MYSQL_APT_CONFIG_VERSION}_all.deb"; \
 echo "${MYSQL_APT_CONFIG_MD5}  /tmp/mysql-apt.deb" | md5sum -c -; \
 echo "mysql-apt-config mysql-apt-config/select-server select mysql-8.4-lts" | debconf-set-selections; \
 DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends /tmp/mysql-apt.deb; \
 apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends mysql-community-client; \
 rm -rf /var/lib/apt/lists/* /tmp/mysql-apt.deb; \
 install-php-extensions bcmath gd imagick intl soap pdo_mysql redis; \
 mysqldump --version
ENV PHP_OPCACHE_ENABLE=1 PHP_OPCACHE_MEMORY_CONSUMPTION=256 PHP_OPCACHE_INTERNED_STRINGS_BUFFER=32 PHP_OPCACHE_MAX_ACCELERATED_FILES=20000 PHP_OPCACHE_VALIDATE_TIMESTAMPS=1 PHP_OPCACHE_REVALIDATE_FREQ=2 PHP_OPCACHE_SAVE_COMMENTS=1 PHP_MEMORY_LIMIT=512M PHP_MAX_INPUT_VARS=5000 PHP_POST_MAX_SIZE=64M PHP_UPLOAD_MAX_FILE_SIZE=64M NGINX_WEBROOT=/var/www/html/web CRAFT_STREAM_LOG=true
WORKDIR /var/www/html
USER www-data
DOCKERFILE

cat > cli.Dockerfile <<'DOCKERFILE'
FROM serversideup/php:8.4-cli
USER root
ARG MYSQL_APT_CONFIG_VERSION=0.8.40-1
ARG MYSQL_APT_CONFIG_MD5=981ff0a16aab27a0cd97f4c4ee49e9fd
RUN set -eux; \
 apt-get update; \
 DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl debconf gnupg lsb-release wget; \
 wget -qO /tmp/mysql-apt.deb "https://dev.mysql.com/get/mysql-apt-config_${MYSQL_APT_CONFIG_VERSION}_all.deb"; \
 echo "${MYSQL_APT_CONFIG_MD5}  /tmp/mysql-apt.deb" | md5sum -c -; \
 echo "mysql-apt-config mysql-apt-config/select-server select mysql-8.4-lts" | debconf-set-selections; \
 DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends /tmp/mysql-apt.deb; \
 apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends mysql-community-client; \
 rm -rf /var/lib/apt/lists/* /tmp/mysql-apt.deb; \
 install-php-extensions bcmath gd imagick intl soap pdo_mysql redis; \
 mysqldump --version
ENV PHP_MEMORY_LIMIT=768M CRAFT_STREAM_LOG=true
WORKDIR /var/www/html
USER www-data
ENTRYPOINT ["php", "/var/www/html/craft"]
CMD ["queue/listen", "--verbose=1"]
DOCKERFILE

cat > docker-compose.yml <<'YAML'
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports: ["80:80", "443:443", "443:443/udp"]
    volumes: ["./Caddyfile:/etc/caddy/Caddyfile:ro", "./caddy_data:/data", "./caddy_config:/config"]
    networks: [craft_net]
    depends_on: {app: {condition: service_started}}
  app:
    build: {context: ., dockerfile: web.Dockerfile}
    restart: unless-stopped
    env_file: [.env]
    environment:
      COMPOSER_HOME: /var/www/html/storage/composer
      COMPOSER_CACHE_DIR: /var/www/html/storage/composer/cache
      PHP_FPM_POOL_NAME: www
      PHP_FPM_PM_CONTROL: dynamic
      PHP_FPM_PM_MAX_CHILDREN: "12"
      PHP_FPM_PM_START_SERVERS: "3"
      PHP_FPM_PM_MIN_SPARE_SERVERS: "2"
      PHP_FPM_PM_MAX_SPARE_SERVERS: "5"
      PHP_FPM_PM_MAX_REQUESTS: "500"
    volumes: ["./:/var/www/html"]
    networks: [craft_net]
    depends_on: {db: {condition: service_healthy}, redis_cache: {condition: service_healthy}, redis_session: {condition: service_healthy}}
  cli:
    build: {context: ., dockerfile: cli.Dockerfile}
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    env_file: [.env]
    environment: {COMPOSER_HOME: /var/www/html/storage/composer, COMPOSER_CACHE_DIR: /var/www/html/storage/composer/cache}
    volumes: ["./:/var/www/html"]
    networks: [craft_net]
    depends_on: {db: {condition: service_healthy}, redis_cache: {condition: service_healthy}, redis_session: {condition: service_healthy}}
    command: ["queue/listen", "--verbose=1"]
  db:
    image: mysql:8.4
    restart: unless-stopped
    command: ["--character-set-server=utf8mb4", "--collation-server=utf8mb4_0900_ai_ci", "--skip-name-resolve", "--innodb-buffer-pool-size=2G", "--innodb-redo-log-capacity=1G", "--max-connections=100", "--innodb-flush-log-at-trx-commit=2"]
    environment: {MYSQL_ROOT_PASSWORD: "${CRAFT_DB_ROOT_PASSWORD}", MYSQL_DATABASE: "${CRAFT_DB_DATABASE}", MYSQL_USER: "${CRAFT_DB_USER}", MYSQL_PASSWORD: "${CRAFT_DB_PASSWORD}"}
    volumes: [db_data:/var/lib/mysql]
    networks: [craft_net]
    healthcheck: {test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\"$${MYSQL_ROOT_PASSWORD}\" --silent"], interval: 10s, timeout: 5s, retries: 12, start_period: 30s}
  redis_cache:
    image: redis:7
    restart: unless-stopped
    command: ["redis-server", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru", "--save", ""]
    networks: [craft_net]
    healthcheck: {test: ["CMD", "redis-cli", "ping"], interval: 10s, timeout: 5s, retries: 5}
  redis_session:
    image: redis:7
    restart: unless-stopped
    command: ["redis-server", "--maxmemory", "256mb", "--maxmemory-policy", "noeviction", "--appendonly", "yes", "--appendfsync", "everysec"]
    volumes: [redis_session_data:/data]
    networks: [craft_net]
    healthcheck: {test: ["CMD", "redis-cli", "ping"], interval: 10s, timeout: 5s, retries: 5}
  sftp:
    image: atmoz/sftp:debian
    restart: unless-stopped
    ports: ["${SFTP_PORT}:22"]
    command: "${SFTP_USER}:${SFTP_PASSWORD}:${SFTP_UID}:${SFTP_GID}:templates,web,project,backups"
    volumes:
      - ./templates:/home/${SFTP_USER}/templates
      - ./web:/home/${SFTP_USER}/web
      - ./config/project:/home/${SFTP_USER}/project
      - ./storage/backups:/home/${SFTP_USER}/backups
    networks: [craft_net]
volumes:
  db_data:
  redis_session_data:
networks:
  craft_net: {driver: bridge}
YAML
fi

info "Validando Docker Compose..."
docker compose config --quiet
info "Eliminando recursos anteriores del mismo proyecto..."
docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
info "Construyendo imágenes base..."
docker compose build --pull app cli

if [[ "$DB_TYPE" == "pgsql" ]]; then
  info "Verificando herramientas PostgreSQL..."
  for service in app cli; do
    docker compose run --rm --no-deps --entrypoint sh "$service" -lc 'set -e; command -v pg_dump; version="$(pg_dump --version)"; echo "$version"; echo "$version" | grep -iq "PostgreSQL"'
  done
else
  info "Verificando MySQL Community Client 8.4..."
  for service in app cli; do
    docker compose run --rm --no-deps --entrypoint sh "$service" -lc 'set -e; command -v mysqldump; version="$(mysqldump --version)"; echo "$version"; echo "$version" | grep -Eq "Ver 8\.4\."; ! echo "$version" | grep -qi MariaDB'
  done
fi

CONTAINER_GID="$(docker compose run --rm --no-deps --entrypoint sh app -lc 'id -g www-data')"
[[ -n "$CONTAINER_GID" ]] || { error "No se pudo obtener el GID de www-data."; exit 1; }
sed -i "s/^SFTP_GID=.*/SFTP_GID=${CONTAINER_GID}/" .env

info "Configurando permisos compartidos para Craft y SFTP..."
sudo chown "$HOST_UID:$CONTAINER_GID" .env composer.json composer.lock
sudo chmod 660 .env composer.json composer.lock
sudo chown -R "$HOST_UID:$CONTAINER_GID" vendor storage web templates config/project config/license.key
sudo find vendor storage web templates config/project -type d -exec chmod 2775 {} +
sudo find vendor storage web templates config/project -type f -exec chmod 664 {} +
sudo chmod 664 config/license.key
chmod 700 caddy_data caddy_config

info "Iniciando Base de Datos y Redis..."
docker compose up -d db redis_cache redis_session
DB_READY=false
for _ in $(seq 1 40); do
  if [[ "$DB_TYPE" == "pgsql" ]]; then
    if docker compose exec -T db pg_isready -U "craft_user" -d "craft_db" >/dev/null 2>&1; then DB_READY=true; break; fi
  else
    if docker compose exec -T db mysqladmin ping -h 127.0.0.1 -uroot -p"$DB_ROOT_PASSWORD" --silent >/dev/null 2>&1; then DB_READY=true; break; fi
  fi
  sleep 3
done
[[ "$DB_READY" == true ]] || { error "La base de datos no está disponible."; docker compose logs db; exit 1; }

if [[ "$DB_TYPE" == "pgsql" ]]; then
  info "Verificando credenciales de craft_user..."
  docker compose exec -T db psql -U craft_user -d craft_db -c "SELECT 1;" >/dev/null 2>&1 || { error "craft_user no puede autenticarse."; exit 1; }
else
  info "Verificando credenciales de craft_user..."
  docker compose exec -T db mysql -ucraft_user -p"$DB_PASSWORD" -D craft_db -Nse "SELECT 1" | grep -qx 1 || { error "craft_user no puede autenticarse."; exit 1; }
fi

info "Instalando Craft como www-data..."
docker compose run --rm --no-deps --entrypoint php app /var/www/html/craft install/craft \
  --interactive=0 --email="$ADMIN_EMAIL" --username=admin --password="$ADMIN_PASS" \
  --site-name="Craft Producción" --site-url="https://$DOMAIN_NAME" --language=es-ES

if [[ "$DB_TYPE" == "pgsql" ]]; then
  CRAFT_INFO_TABLES="$(docker compose exec -T db psql -U craft_user -d craft_db -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='info';")"
  CRAFT_INFO_TABLES="$(echo "$CRAFT_INFO_TABLES" | tr -d '[:space:]')"
else
  CRAFT_INFO_TABLES="$(docker compose exec -T db mysql -uroot -p"$DB_ROOT_PASSWORD" -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='craft_db' AND table_name='info';")"
fi

[[ "$CRAFT_INFO_TABLES" == 1 ]] || { error "Craft no terminó la instalación."; exit 1; }
sudo chmod 640 .env

info "Configurando UFW para 22, 80, 443 y 2222..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ufw iptables
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw allow 443/udp comment 'HTTP3'
sudo ufw allow 2222/tcp comment 'Craft SFTP'
sudo ufw --force enable

info "Configurando DOCKER-USER para que Docker no eluda el firewall..."
PUBLIC_INTERFACE="$(ip route show default | awk '/default/ {print $5; exit}')"
[[ -n "$PUBLIC_INTERFACE" ]] || { error "No se pudo detectar la interfaz pública."; exit 1; }
sudo tee /usr/local/sbin/craft-docker-firewall >/dev/null <<'FIREWALL'
#!/usr/bin/env bash
set -Eeuo pipefail
IFACE="${1:?Falta interfaz pública}"
apply_rules(){
  local cmd="$1"
  "$cmd" -N CRAFT-DOCKER-FW 2>/dev/null || true
  "$cmd" -F CRAFT-DOCKER-FW
  "$cmd" -C DOCKER-USER -j CRAFT-DOCKER-FW 2>/dev/null || "$cmd" -I DOCKER-USER 1 -j CRAFT-DOCKER-FW
  "$cmd" -A CRAFT-DOCKER-FW -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
  "$cmd" -A CRAFT-DOCKER-FW -i "$IFACE" -p tcp -m conntrack --ctorigdstport 80 -j RETURN
  "$cmd" -A CRAFT-DOCKER-FW -i "$IFACE" -p tcp -m conntrack --ctorigdstport 443 -j RETURN
  "$cmd" -A CRAFT-DOCKER-FW -i "$IFACE" -p udp -m conntrack --ctorigdstport 443 -j RETURN
  "$cmd" -A CRAFT-DOCKER-FW -i "$IFACE" -p tcp -m conntrack --ctorigdstport 2222 -j RETURN
  "$cmd" -A CRAFT-DOCKER-FW -i "$IFACE" -j DROP
  "$cmd" -A CRAFT-DOCKER-FW -j RETURN
}
apply_rules iptables
if ip6tables -nL DOCKER-USER >/dev/null 2>&1; then apply_rules ip6tables; fi
FIREWALL
sudo chmod 755 /usr/local/sbin/craft-docker-firewall
sudo tee /etc/systemd/system/craft-docker-firewall.service >/dev/null <<EOF
[Unit]
Description=Firewall de puertos publicados por Docker para Craft
After=docker.service ufw.service
Requires=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/craft-docker-firewall ${PUBLIC_INTERFACE}
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable craft-docker-firewall.service >/dev/null

info "Levantando todos los servicios..."
docker compose up -d --remove-orphans
sudo systemctl restart craft-docker-firewall.service
sleep 5
docker compose ps
for service in app cli caddy sftp; do
  docker compose ps --status running --services | grep -qx "$service" || { error "$service no está ejecutándose."; docker compose logs "$service"; exit 1; }
done

info "Probando una copia de seguridad desde Craft..."
docker compose exec -T app php craft db/backup /var/www/html/storage/backups/

cat > .install-credentials <<EOF
URL: https://${DOMAIN_NAME}
Panel: https://${DOMAIN_NAME}/admin
Usuario Craft: admin
Contraseña Craft: ${ADMIN_PASS}
Motor BD: ${DB_TYPE}
Base de datos: craft_db
Usuario BD: craft_user
Contraseña BD: ${DB_PASSWORD}
EOF
if [[ "$DB_TYPE" == "mysql" ]]; then
  echo "Contraseña root MySQL: ${DB_ROOT_PASSWORD}" >> .install-credentials
fi
cat >> .install-credentials <<EOF
SFTP host: ${DOMAIN_NAME}
SFTP puerto: ${SFTP_PORT}
SFTP usuario: ${SFTP_USER}
SFTP contraseña: ${SFTP_PASSWORD}
EOF

chmod 600 .install-credentials
INSTALL_COMPLETED=true
trap - ERR INT TERM

echo -e "${BLUE}====================================================${NC}"
echo -e "${GREEN}Despliegue completado correctamente${NC}"
echo -e "URL: ${YELLOW}https://${DOMAIN_NAME}${NC}"
echo -e "Panel: ${YELLOW}https://${DOMAIN_NAME}/admin${NC}"
echo -e "SFTP: ${YELLOW}${SFTP_USER}@${DOMAIN_NAME}:${SFTP_PORT}${NC}"
echo -e "Carpetas SFTP: ${YELLOW}templates, web, project, backups${NC}"
echo -e "Credenciales: ${YELLOW}${PROJECT_DIR}/.install-credentials${NC}"
echo -e "${BLUE}====================================================${NC}"
