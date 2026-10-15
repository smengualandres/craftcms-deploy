#!/usr/bin/env bash
set -e
set -o pipefail # Asegura que si falla una tubería (como curl | gpg), el script se detenga

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

read -p "👉 Introduce tu dominio (ej: midominio.com): " DOMAIN
read -p "👉 Introduce tu correo (para SSL Let's Encrypt): " EMAIL

echo -e "${YELLOW}⚠️ RECUERDA: El registro A de ${DOMAIN} debe estar apuntando a la IP de este servidor antes de continuar.${NC}"
read -p "Presiona ENTER para confirmar y empezar la instalación..."

echo -e "${GREEN}🧹 Limpiando instalaciones anteriores...${NC}"
WEB_ROOT="/var/www/html/$DOMAIN"
rm -rf $WEB_ROOT
mysql -e "DROP DATABASE IF EXISTS craft_db;" || true

echo -e "${GREEN}🔑 Generando credenciales...${NC}"
DB_ROOT_PASS=$(openssl rand -hex 16)
DB_PASS=$(openssl rand -hex 16)
ADMIN_PASS=$(openssl rand -hex 8)
SFTP_PASS=$(openssl rand -hex 12)
SECURITY_KEY=$(openssl rand -base64 32 | tr -d '\n')

echo -e "${GREEN}📦 Actualizando sistema e instalando dependencias base...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y software-properties-common curl wget unzip apt-transport-https debian-keyring debian-archive-keyring redis-server ufw openssh-server

# Configurar Firewall
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 22/tcp
ufw --force enable

echo -e "${GREEN}📦 Instalando Caddy...${NC}"
rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update
apt-get install -y caddy

echo -e "${GREEN}📦 Instalando PHP y MySQL...${NC}"
apt-get install -y mysql-server \
    php-fpm php-mysql php-xml \
    php-mbstring php-curl php-zip \
    php-intl php-bcmath php-gd \
    php-imagick php-redis

PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')

echo -e "${GREEN}⚙️ Optimizando PHP para Producción (Memoria y Seguridad)...${NC}"
sed -i "s/^memory_limit = .*/memory_limit = 512M/" /etc/php/${PHP_VER}/fpm/php.ini
sed -i "s/^memory_limit = .*/memory_limit = 512M/" /etc/php/${PHP_VER}/cli/php.ini
sed -i "s/^display_errors = .*/display_errors = Off/" /etc/php/${PHP_VER}/fpm/php.ini
sed -i "s/^display_errors = .*/display_errors = Off/" /etc/php/${PHP_VER}/cli/php.ini
systemctl restart php${PHP_VER}-fpm

echo -e "${GREEN}⚙️ Optimizando MySQL...${NC}"
cat <<EOF > /etc/mysql/mysql.conf.d/mysqld.cnf
[mysqld]
user            = mysql
bind-address    = 127.0.0.1
mysqlx-bind-address = 127.0.0.1
innodb_buffer_pool_size = 2G
EOF
systemctl restart mysql

export MYSQL_PWD="${DB_ROOT_PASS}"
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';"

echo -e "${GREEN}🔒 Aplicando seguridad extra a MySQL (mysql_secure_installation)...${NC}"
mysql -uroot -e "DELETE FROM mysql.user WHERE User='';"
mysql -uroot -e "DROP DATABASE IF EXISTS test;"
mysql -uroot -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -uroot -e "FLUSH PRIVILEGES;"

echo -e "${GREEN}⚙️ Activando Timezones en MySQL...${NC}"
mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -uroot mysql

mysql -uroot -e "CREATE DATABASE IF NOT EXISTS craft_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -uroot -e "CREATE USER IF NOT EXISTS 'craft_user'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -uroot -e "GRANT ALL PRIVILEGES ON craft_db.* TO 'craft_user'@'localhost'; FLUSH PRIVILEGES;"
unset MYSQL_PWD

echo -e "${GREEN}⚙️ Asegurando Redis...${NC}"
sed -i 's/^#*\s*bind .*/bind 127.0.0.1/' /etc/redis/redis.conf
sed -i 's/^#*\s*protected-mode .*/protected-mode yes/' /etc/redis/redis.conf
systemctl restart redis-server

echo -e "${GREEN}📥 Instalando Composer y Craft CMS...${NC}"
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
export COMPOSER_ALLOW_SUPERUSER=1
mkdir -p $WEB_ROOT
composer create-project craftcms/craft $WEB_ROOT --no-scripts
cd $WEB_ROOT
composer require yiisoft/yii2-redis --no-interaction

cat <<EOF > $WEB_ROOT/.env
CRAFT_ENVIRONMENT=production
CRAFT_SECURITY_KEY=${SECURITY_KEY}
CRAFT_DB_DRIVER=mysql
CRAFT_DB_SERVER=127.0.0.1
CRAFT_DB_PORT=3306
CRAFT_DB_DATABASE=craft_db
CRAFT_DB_USER=craft_user
CRAFT_DB_PASSWORD=${DB_PASS}
PRIMARY_SITE_URL=https://${DOMAIN}
CRAFT_STREAM_LOG=true
EOF

echo -e "${GREEN}🔒 Aplicando permisos de carpetas (Previo a instalación)...${NC}"
mkdir -p $WEB_ROOT/storage $WEB_ROOT/config/project $WEB_ROOT/web/cpresources
chown -R www-data:www-data $WEB_ROOT
find $WEB_ROOT -type d -exec chmod 2775 {} \;
find $WEB_ROOT -type f -exec chmod 0664 {} \;

echo -e "${GREEN}🚀 Ejecutando instalación de Craft CMS...${NC}"
sudo -u www-data php $WEB_ROOT/craft install/craft \
  --interactive=0 \
  --email="${EMAIL}" \
  --username="admin" \
  --password="${ADMIN_PASS}" \
  --site-name="Craft Produccion" \
  --site-url="https://${DOMAIN}" \
  --language="es-ES"

echo -e "${GREEN}🔐 Configurando SFTP enjaulado (Chroot) y Permisos...${NC}"
useradd -g www-data -d /$DOMAIN -s /usr/sbin/nologin sftp_user || true
echo "sftp_user:${SFTP_PASS}" | chpasswd

chown root:root /var/www/html
chmod 755 /var/www/html

if ! grep -q "Match User sftp_user" /etc/ssh/sshd_config; then
cat <<EOF >> /etc/ssh/sshd_config

# Configuración SFTP Enjaulado para Craft CMS
Match User sftp_user
    ChrootDirectory /var/www/html
    ForceCommand internal-sftp -u 0002
    AllowTcpForwarding no
    X11Forwarding no
EOF
fi
systemctl restart sshd

echo -e "${GREEN}⚙️ Configurando Caddyfile...${NC}"
mkdir -p /etc/caddy
cat <<EOF > /etc/caddy/Caddyfile
{
    email ${EMAIL}
}
${DOMAIN} {
    root * ${WEB_ROOT}/web
    php_fastcgi unix//run/php/php${PHP_VER}-fpm.sock
    file_server
    @sensitive {
        path */.* /config/* /storage/* /vendor/*
    }
    respond @sensitive 404
}
EOF
systemctl enable --now caddy
systemctl restart caddy

echo -e "${GREEN}⚙️ Configurando Queue Worker de Craft...${NC}"
cat <<EOF > /etc/systemd/system/craft-queue.service
[Unit]
Description=Craft CMS Queue Manager
After=network.target mysql.service redis-server.service

[Service]
User=www-data
Group=www-data
ExecStart=/usr/bin/php $WEB_ROOT/craft queue/listen --verbose
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now craft-queue.service

echo -e "${GREEN}💾 Guardando credenciales en /root/credenciales_craft.txt...${NC}"
cat <<EOF > /root/credenciales_craft.txt
=================================================
🌐 URL Pública:   https://${DOMAIN}
🔐 Panel Control: https://${DOMAIN}/admin

👤 Usuario Admin Craft: admin
🔑 Pass Admin Craft:    ${ADMIN_PASS}

🗄️ Usuario BD: craft_user
🔑 Pass BD:    ${DB_PASS}
👑 Pass BD Root (MySQL): ${DB_ROOT_PASS}

📁 Usuario SFTP: sftp_user
🔑 Pass SFTP:    ${SFTP_PASS}
(El usuario SFTP se conecta al puerto 22 y entra directamente a la carpeta web)
=================================================
EOF
chmod 600 /root/credenciales_craft.txt

echo -e "\n${BLUE}====================================================${NC}"
cat /root/credenciales_craft.txt
echo -e "${BLUE}====================================================${NC}"
echo -e "${YELLOW}NOTA: Las contraseñas han sido guardadas de forma segura en /root/credenciales_craft.txt${NC}"
