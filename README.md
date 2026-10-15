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
| **Backups de Craft** | Carpeta local | `./storage/backups` | `/var/www/html/storage/backups` |
| **Archivos Web / Assets** | Carpeta local | `./web` | `/var/www/html/web` |

---

## 🛠 Requisitos Previos e Instalación

> [!WARNING]
> **Requisito indispensable de DNS:** Antes de ejecutar el script, **el dominio principal debe estar previamente configurado apuntando a la dirección IP pública del servidor**. Caddy necesita que el tráfico HTTP/HTTPS llegue al servidor para validar y emitir automáticamente los certificados SSL de Let's Encrypt durante el despliegue.

- **Sistema Operativo Recomendado:** Instalación limpia de **Ubuntu 26 LTS**.
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

## 🔒 Aviso de Seguridad Adicional

> [!CAUTION]
> Este script implementa medidas automatizadas básicas de endurecimiento (*hardening*), pero **no sustituye una auditoría de seguridad completa**. 
> 
> Es responsabilidad del administrador revisar y asegurar los siguientes aspectos antes de llevar el entorno a producción:
> - **Puertos y cortafuegos de infraestructura:** Verifica el firewall externo de tu proveedor de Cloud/VPS (como las reglas de seguridad de OVH, AWS, DigitalOcean, etc.) para asegurarte de que no haya puertos innecesarios expuestos a Internet.
> - **Acceso SSH:** Desactiva la autenticación por contraseña en SSH y utiliza exclusivamente pares de claves públicas (*SSH keys*), además de considerar cambiar el puerto por defecto o instalar herramientas como Fail2ban.
> - **Actualizaciones y parches:** Mantén el sistema operativo del servidor host, Docker y los paquetes del sistema permanentemente actualizados.
> - **Credenciales y Secretos:** Aunque el archivo `.install-credentials` se genera con permisos restringidos, asegúrate de respaldarlo de forma segura y no dejar copias expuestas en directorios públicos.
