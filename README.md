# craftcms-deploy
Docker &amp; Full server deploy scripts for Craft CMS 5 

# Despliegue Automatizado de Craft CMS 5

Este repositorio contiene scripts de automatización para desplegar **Craft CMS 5** de forma rápida y segura, ofreciendo dos enfoques según tus necesidades de infraestructura:

1. **Docker (Recomendado para entornos modernos y producción):** Orquestación completa con contenedores, base de datos aislada, Redis, Caddy con SSL automático y servidor SFTP integrado.
2. **Servidor Tradicional (Bare-Metal sin Docker):** Instalación nativa optimizada directamente sobre el sistema operativo del servidor.

---

# 1. Despliegue Automatizado de Craft CMS 5 en Docker

Este script es un instalador y orquestador automatizado para desplegar **Craft CMS 5** sobre contenedores Docker en entornos de producción o staging.

> [!NOTE]
> **Aviso de proyecto:** Este script forma parte de un **proyecto de innovación educativa (Proyecto IDHE - 4419824)** de la Universitat de València. Se encuentra en una fase inicial de desarrollo y evaluación, por lo que **no está exento de errores**. Ha sido desarrollado con asistencia de **Inteligencia Artificial**.

> [!TIP]
> **Enfoque:** El diseño de la arquitectura de contenedores, la gestión de entornos, la ejecución separada de colas (`cli`), la configuración de Redis y la integración de las utilidades de consola (`mysqldump` / `pg_dump`) siguen las recomendaciones y buenas prácticas de la documentación oficial de **Pixel & Tonic** para despliegues de **Craft CMS**.

---

## 🏗 Arquitectura y Elección de Imágenes

El script permite elegir interactivamente el motor de base de datos antes de realizar la instalación, ajustando la pila tecnológica de imágenes según el motor seleccionado:

- **Opción PostgreSQL 18 (Alpine):** Utiliza las imágenes `serversideup/php:8.4-fpm-nginx-alpine` y `serversideup/php:8.4-cli-alpine`. Se optó por la distribución Alpine para PostgreSQL debido a su ligereza, bajo consumo de recursos y facilidad de instalación de paquetes nativos como `postgresql-client` (`pg_dump` y `pg_restore`), garantizando compatibilidad total con la herramienta de exportación de bases de datos de Craft CMS.

- **Opción MySQL 8.4 LTS (Debian):** Utiliza las imágenes base basadas en Debian (`serversideup/php:8.4-fpm-nginx` y `serversideup/php:8.4-cli`). En este caso, Debian es imprescindible para poder añadir e instalar oficialmente el paquete `mysql-community-client` desde los repositorios APT de Oracle MySQL. Esto evita incompatibilidades y fallos al usar utilidades de volcado (`mysqldump`) de MariaDB con servidores MySQL 8.4.

---
### ⚡ Optimización con Doble Instancia de Redis

Para asegurar el mejor rendimiento y evitar problemas con los usuarios conectados, el sistema utiliza dos contenedores de Redis separados, cada uno optimizado para una tarea concreta:

- **Redis Cache (`redis_cache`):** Se encarga de guardar temporalmente datos de la web para que cargue mucho más rápido. Funciona exclusivamente en la memoria RAM (no guarda nada en el disco) y, si se llena, borra automáticamente la caché más antigua para seguir funcionando sin interrupciones.
- **Redis Session (`redis_session`):** Gestiona las sesiones activas de los usuarios. A diferencia de la caché, esta instancia sí guarda los datos de forma permanente en un volumen del disco. Esto garantiza que si el contenedor se reinicia o actualiza, ningún administrador o cliente pierda su sesión y sea desconectado.

## 🔄 Filosofía de Trabajo: Arquitectura No Inmutable

A diferencia de los despliegues de contenedores puramente inmutables (donde el código fuente se compila dentro de la imagen e impediría modificaciones en caliente), este proyecto utiliza un modelo **híbrido no inmutable** adaptado a flujos de trabajo de desarrollo web activo:

- Los directorios del proyecto (`/templates`, `/web`, `/config/project`, etc.) se montan como **volúmenes de bind directos** desde el servidor host hacia los contenedores.
- **Flujo SFTP:** El script levanta un servidor SFTP restringido (`atmoz/sftp`) con permisos sincronizados (UID/GID `www-data`).
- Esto permite a los desarrolladores y maquetadores editar plantillas Twig, archivos CSS/JS o la configuración de proyecto localmente y subirlos directamente mediante SFTP al servidor. 
- Los cambios se reflejan inmediatamente en la web y la sincronización de campos/estructuras se aplica ejecutando `php craft project-config/apply` directamente dentro del contenedor `cli` o desde el panel de administración.

---

## 💾 Persistencia de Datos y Volúmenes

Para garantizar que los datos persistan a reinicios, reconstrucciones o actualizaciones de contenedores, la información crítica se almacena en el sistema de archivos del servidor host y en volúmenes nombrados de Docker:

| Servicio | Tipo de Almacenamiento | Ubicación en el Host / Volumen Docker | Ruta interna en el Contenedor |
| :--- | :--- | :--- | :--- |
| **PostgreSQL** | Volumen nombrado | `db_data` | `/var/lib/postgresql/data` |
| **MySQL** | Volumen nombrado | `db_data` | `/var/lib/mysql` |
| **Caddy (Certificados SSL)** | Carpeta local | `./caddy_data` | `/data` |
| **Caddy (Configuración)** | Carpeta local | `./caddy_config` | `/config` |
| **Redis (Sesiones)** | Volumen nombrado | `redis_session_data` | `/data` |
| **Redis (Caché)** | Volátil (En memoria) | *Ninguna* | *N/A* |
| **Backups de Craft** | Carpeta local | `./storage/backups` | `/var/www/html/storage/backups` |
| **Archivos Web / Assets** | Carpeta local | `./web` | `/var/www/html/web` |

---

## 🛠 Requisitos Previos e Instalación

> [!WARNING]
> **Requisito indispensable de DNS:** Antes de ejecutar el script, **el dominio principal debe estar previamente configurado apuntando a la dirección IP pública del servidor**. Caddy necesita que el tráfico HTTP/HTTPS llegue al servidor para validar y emitir automáticamente los certificados SSL de Let's Encrypt durante el despliegue.

- **Sistema Operativo Recomendado:** Instalación limpia de **Ubuntu Server 26 LTS**.
- **Entorno de Pruebas:** Probado y verificado en instancias VPS de **OVHcloud**.
- **Usuario:** Debe ejecutarse con un usuario con privilegios `sudo` (no como usuario `root` directo).
- **Docker:** No es necesario tener Docker instalado previamente. Si el script detecta que no existe en el sistema, **instalará Docker y Docker Compose automáticamente** a través del script oficial de Docker.

---

## 🚀 Modo de Uso

1. **Clonar o descargar el repositorio** en el directorio donde desees alojar la instalación de Craft CMS (el directorio debe estar vacío):

   ```bash
   git clone <URL_DEL_REPOSITORIO> .

2. **Otorgar permisos de ejecución** al script:
 
   ```bash
   chmod +x deploy-craft.sh
   ```
3. **Ejecutar el script** en una terminal interactiva:
 
   ```bash
   ./deploy-craft.sh
   ```
4. **Sigue las instrucciones en pantalla:**
 
- Selecciona el motor de base de datos (`1` para MySQL 8.4 o `2` para PostgreSQL 18).
- Introduce el dominio principal previamente apuntado (ej. `craft.midominio.com`).
- Introduce el correo electrónico para la generación automática de certificados SSL con Let's Encrypt y la cuenta del administrador de Craft.
 
Al finalizar el proceso, el script generará un archivo llamado `.install-credentials` (protegido con permisos `600`) con todas las contraseñas, usuarios de base de datos, credenciales del panel de Craft CMS y accesos SFTP generados aleatoriamente.
 
## 🛡 Seguridad e Integración con Firewall
 
El script no solo levanta los contenedores, sino que aplica una capa de seguridad en la máquina host:
 
- Configura UFW abriendo únicamente los puertos **22 (SSH)**, **80 (HTTP)**, **443 (HTTPS/HTTP3)** y **2222 (SFTP restringido para Craft)**.
- Despliega un servicio en systemd (`craft-docker-firewall.service`) que aplica reglas en la cadena `DOCKER-USER` de iptables. Esto evita que el motor interno de Docker ignore las reglas del firewall del host y exponga la base de datos o Redis públicamente.

---
---

# 2. Despliegue Automatizado de Craft CMS 5 en Servidor Tradicional (Bare-Metal)

Este script proporciona una instalación nativa, automatizada y optimizada de **Craft CMS 5** directamente sobre el sistema operativo base del servidor (Bare-Metal) sin utilizar contenedores. Está diseñado para entornos donde se prefiere el máximo rendimiento directo del hardware y una gestión de servicios a nivel de sistema.

> [!NOTE]
> **Aviso de proyecto:** Este script forma parte de un **proyecto de innovación educativa (Proyecto IDHE - 4419824)** de la Universitat de València. Se encuentra en una fase inicial de desarrollo y evaluación, por lo que **no está exento de errores**. Ha sido desarrollado con asistencia de **Inteligencia Artificial**.

> [!TIP]
> **Enfoque:** La configuración de los servicios (PHP-FPM, MySQL, Redis y Caddy) ha sido optimizada aplicando configuraciones de producción, límites de memoria ampliados y bloqueos de seguridad recomendados para aplicaciones web modernas y las exigencias de **Craft CMS 5**.

---

## 🏗 Pila Tecnológica y Arquitectura Nativa

El despliegue instala y orquesta los siguientes componentes directamente a través del gestor de paquetes del sistema (APT):

- **Servidor Web y SSL Automático (Caddy):** Sustituye a Nginx/Apache. Se encarga de servir la web a través de PHP-FPM y de la gestión totalmente automática de certificados SSL con Let's Encrypt. Incluye reglas de seguridad nativas en su `Caddyfile` para bloquear accesos a rutas críticas (`/.env`, `/config/`, `/storage/`, `/vendor/`).
- **Base de Datos (MySQL 8):** Instalación directa en el sistema. El script optimiza el rendimiento asignando 2GB a `innodb_buffer_pool_size` en su archivo de configuración, limpia usuarios por defecto y bases de datos de prueba, y carga las zonas horarias del sistema (`timezones`), un requisito esencial para Craft CMS.
- **Procesamiento PHP (PHP-FPM 8.x):** Se instala la versión nativa de PHP con todas las extensiones requeridas (`mbstring`, `imagick`, `redis`, `bcmath`, etc.). Se aplica un *hardening* básico ocultando errores en pantalla (`display_errors = Off`) y se aumenta la memoria a `512M`.
- **Caché y Sesiones (Redis):** Se despliega una instancia local de Redis para agilizar el rendimiento de Craft. Por seguridad, se fuerza a escuchar exclusivamente en `127.0.0.1` y se activa el `protected-mode`.

---

## ⚡ Procesamiento en Segundo Plano (Colas)

A diferencia del entorno de Docker, que utiliza un contenedor aislado para ejecutar tareas, este despliegue garantiza la ejecución de trabajos en segundo plano creando un servicio nativo en Systemd:

- Se genera el demonio `craft-queue.service`, ejecutado por el usuario web del sistema (`www-data`).
- Mantiene el comando `php craft queue/listen` corriendo de manera persistente en segundo plano.
- Cuenta con políticas de reinicio automático para asegurar que las sincronizaciones, envíos de correo y actualizaciones de caché nunca se detengan.

---

## 🔄 Filosofía de Trabajo: Acceso Directo y SFTP Enjaulado

Al no existir volúmenes ni contenedores efímeros, todos los archivos residen físicamente en `/var/www/html/tu-dominio.com`. Para mantener un flujo de trabajo seguro:

- **Usuario SFTP Dedicado:** El script crea el usuario `sftp_user` de forma automática.
- **Chroot (Enjaulamiento):** Se modifica la configuración de SSH (`/etc/ssh/sshd_config`) para restringir al usuario. Al conectarse, este entra directamente a la carpeta web y no puede navegar hacia directorios superiores del servidor Linux ni ejecutar comandos de terminal.

---

## 🛠 Requisitos Previos e Instalación

> [!WARNING]
> **Requisito indispensable de DNS:** Antes de ejecutar el script, **el registro DNS (Tipo A) de tu dominio debe estar apuntando a la dirección IP del servidor**. El instalador lo necesita para que Caddy valide el dominio y emita el certificado SSL al instante.

- **Sistema Operativo:** Instalación limpia **Ubuntu Server 26 LTS**.
- **Permisos:** El script debe ejecutarse directamente como el superusuario **`root`** (no sirve solo con `sudo`), ya que manipula servicios a nivel del sistema operativo.
- **Directorio de trabajo:** El servidor debe estar completamente virgen, sin otras instalaciones previas de MySQL o Nginx/Apache que puedan generar conflictos de puertos.

---

## 🚀 Modo de Uso

1. **Inicia sesión como root o usuario** en tu servidor.
2. **Descarga y otorga permisos de ejecución** al script:

   ```bash
   chmod +x deploy-baremetal.sh

3. **Ejecuta el script:**

   ```bash
   sudo ./deploy-baremetal.sh
   ```

4. **Sigue las instrucciones interactivas:**

   - Introduce tu dominio principal (ej. `craft.midominio.com`).
   - Introduce un correo electrónico válido para Let's Encrypt y la creación del primer administrador de Craft.

Al finalizar, el script volcará todas las contraseñas generadas (Administrador de Craft, Base de Datos, SFTP) en un archivo seguro ubicado en `/root/credenciales_craft.txt`.

## 🛡 Seguridad e Integración con Firewall

A nivel de red y sistema, se implementan las siguientes políticas:

- **UFW (Uncomplicated Firewall):** El script fuerza el reinicio del firewall y lo configura para permitir **exclusivamente** tráfico web (puertos 80 y 443) y el puerto de administración remota y SFTP (puerto 22). Todo el resto del tráfico externo queda bloqueado por defecto.

- **Aislamiento de servicios:** Tanto MySQL como Redis están forzados a no aceptar conexiones externas (`bind-address = 127.0.0.1`), siendo accesibles solo por el propio servidor.   

## 🔒 Aviso de Seguridad Adicional

> [!CAUTION]
> Estos scripts implementan medidas automatizadas básicas de endurecimiento (*hardening*), pero **no sustituye una auditoría de seguridad completa**. 
> 
> Es responsabilidad del administrador revisar y asegurar los siguientes aspectos antes de llevar el entorno a producción:
> - **Puertos y cortafuegos de infraestructura:** Verifica el firewall externo de tu proveedor de Cloud/VPS (como las reglas de seguridad de OVH, AWS, DigitalOcean, etc.) para asegurarte de que no haya puertos innecesarios expuestos a Internet.
> - **Acceso SSH:** Desactiva la autenticación por contraseña en SSH y utiliza exclusivamente pares de claves públicas (*SSH keys*), además de considerar cambiar el puerto por defecto o instalar herramientas como Fail2ban.
> - **Actualizaciones y parches:** Mantén el sistema operativo del servidor host, Docker y los paquetes del sistema permanentemente actualizados.
> - **Credenciales y Secretos:** Aunque el archivo `.install-credentials` se genera con permisos restringidos, asegúrate de respaldarlo de forma segura y no dejar copias expuestas en directorios públicos.
