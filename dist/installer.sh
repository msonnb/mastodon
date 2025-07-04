#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Disable prompts for apt-get.
export DEBIAN_FRONTEND="noninteractive"

# System info.
PLATFORM="$(uname --hardware-platform || true)"
DISTRIB_CODENAME="$(lsb_release --codename --short || true)"
DISTRIB_ID="$(lsb_release --id --short | tr '[:upper:]' '[:lower:]' || true)"

# Secure generator comands
GENERATE_SECURE_SECRET_CMD="openssl rand --hex 16"
GENERATE_K256_PRIVATE_KEY_CMD="openssl ecparam --name secp256k1 --genkey --noout --outform DER | tail --bytes=+8 | head --bytes=32 | xxd --plain --cols 32"

# The Docker compose file.
PDS_COMPOSE_URL="https://raw.githubusercontent.com/bluesky-social/pds/main/compose.yaml"

# The pdsadmin script.
PDSADMIN_URL="https://raw.githubusercontent.com/bluesky-social/pds/main/pdsadmin.sh"

# System dependencies.
REQUIRED_SYSTEM_PACKAGES="
  ca-certificates
  curl
  gnupg
  jq
  lsb-release
  openssl
  sqlite3
  xxd
  jq
"
# Docker packages.
REQUIRED_DOCKER_PACKAGES="
  containerd.io
  docker-ce
  docker-ce-cli
  docker-compose-plugin
"

PUBLIC_IP=""
METADATA_URLS=()
METADATA_URLS+=("http://169.254.169.254/v1/interfaces/0/ipv4/address") # Vultr
METADATA_URLS+=("http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address") # DigitalOcean
METADATA_URLS+=("http://169.254.169.254/2021-03-23/meta-data/public-ipv4") # AWS
METADATA_URLS+=("http://169.254.169.254/hetzner/v1/metadata/public-ipv4") # Hetzner

PDS_DATADIR="${1:-/pds}"
PDS_HOSTNAME="${2:-}"
PDS_ADMIN_EMAIL="${3:-}"
PDS_DID_PLC_URL="https://plc.directory"
PDS_BSKY_APP_VIEW_URL="https://api.bsky.app"
PDS_BSKY_APP_VIEW_DID="did:web:api.bsky.app"
PDS_REPORT_SERVICE_URL="https://mod.bsky.app"
PDS_REPORT_SERVICE_DID="did:plc:ar7c4by46qjdydhdevvrndac"
PDS_CRAWLERS="https://bsky.network"

function usage {
  local error="${1}"
  cat <<USAGE >&2
ERROR: ${error}
Usage:
sudo bash $0

Please try again.
USAGE
  exit 1
}

# Check that user is root.
if [[ "${EUID}" -ne 0 ]]; then
	usage "This script must be run as root. (e.g. sudo $0)"
fi

# Check for a supported architecture.
# If the platform is unknown (not uncommon) then we assume x86_64
if [[ "${PLATFORM}" == "unknown" ]]; then
	PLATFORM="x86_64"
fi
if [[ "${PLATFORM}" != "x86_64" ]] && [[ "${PLATFORM}" != "aarch64" ]] && [[ "${PLATFORM}" != "arm64" ]]; then
	usage "Sorry, only x86_64 and aarch64/arm64 are supported. Exiting..."
fi

# Check for a supported distribution.
SUPPORTED_OS="false"
if [[ "${DISTRIB_ID}" == "ubuntu" ]]; then
	if [[ "${DISTRIB_CODENAME}" == "focal" ]]; then
		SUPPORTED_OS="true"
		echo "* Detected supported distribution Ubuntu 20.04 LTS"
	elif [[ "${DISTRIB_CODENAME}" == "jammy" ]]; then
		SUPPORTED_OS="true"
		echo "* Detected supported distribution Ubuntu 22.04 LTS"
	elif [[ "${DISTRIB_CODENAME}" == "mantic" ]]; then
		SUPPORTED_OS="true"
		echo "* Detected supported distribution Ubuntu 23.10 LTS"
	fi
elif [[ "${DISTRIB_ID}" == "debian" ]]; then
	if [[ "${DISTRIB_CODENAME}" == "bullseye" ]]; then
		SUPPORTED_OS="true"
		echo "* Detected supported distribution Debian 11"
	elif [[ "${DISTRIB_CODENAME}" == "bookworm" ]]; then
		SUPPORTED_OS="true"
		echo "* Detected supported distribution Debian 12"
	fi
fi

if [[ "${SUPPORTED_OS}" != "true" ]]; then
	echo "Sorry, only Ubuntu 20.04, 22.04, Debian 11 and Debian 12 are supported by this installer. Exiting..."
	exit 1
fi

cat <<WELCOME_MESSAGE
========================================================================
Welcome to the Combined Bluesky PDS + Mastodon Installer
========================================================================

This installer will set up both services on your server:

🦋 Bluesky Personal Data Server (PDS)
🐘 Mastodon Social Media Server

What this installer will do:
------------------------------------------------------------------------
✓ Install Docker and required system dependencies
✓ Set up Bluesky PDS
✓ Set up Mastodon
✓ Create systemd services for both platforms

Requirements:
------------------------------------------------------------------------
• Root access (you're running with sudo ✓)
• Valid domain names with DNS pointing to this server
• SMTP server credentials for email notifications
• Ports 80 and 443 accessible from the internet

========================================================================

WELCOME_MESSAGE

# Enforce that the data directory is /pds since we're assuming it for now.
# Later we can make this actually configurable.
if [[ "${PDS_DATADIR}" != "/pds" ]]; then
	usage "The data directory must be /pds. Exiting..."
fi

# Check if PDS is already installed.
if [[ -e "${PDS_DATADIR}/pds.sqlite" ]]; then
	echo
	echo "ERROR: pds is already configured in ${PDS_DATADIR}"
	echo
	echo "To do a clean re-install:"
	echo "------------------------------------"
	echo "1. Stop the service"
	echo
	echo "  sudo systemctl stop pds"
	echo
	echo "2. Delete the data directory"
	echo
	echo "  sudo rm -rf ${PDS_DATADIR}"
	echo
	echo "3. Re-run this installation script"
		echo
	echo "  sudo bash ${0}"
	echo
	echo "For assistance, check https://github.com/bluesky-social/pds"
	exit 1
fi

#
# Attempt to determine server's public IP.
#

# First try using the hostname command, which usually works.
if [[ -z "${PUBLIC_IP}" ]]; then
	PUBLIC_IP=$(hostname --all-ip-addresses | awk '{ print $1 }')
fi

# Prevent any private IP address from being used, since it won't work.
if [[ "${PUBLIC_IP}" =~ ^(127\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.) ]]; then
	PUBLIC_IP=""
fi

# Check the various metadata URLs.
if [[ -z "${PUBLIC_IP}" ]]; then
	for METADATA_URL in "${METADATA_URLS[@]}"; do
		METADATA_IP="$(timeout 2 curl --silent --show-error "${METADATA_URL}" | head --lines=1 || true)"
		if [[ "${METADATA_IP}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
			PUBLIC_IP="${METADATA_IP}"
			break
		fi
	done
fi

if [[ -z "${PUBLIC_IP}" ]]; then
	PUBLIC_IP="Server's IP"
fi

#
# Prompt user for required variables.
#
if [[ -z "${PDS_HOSTNAME}" ]]; then
	read -p "[PDS] Enter your public DNS address (e.g. example.com): " PDS_HOSTNAME
fi

if [[ -z "${PDS_HOSTNAME}" ]]; then
	usage "No public DNS address specified"
fi

if [[ "${PDS_HOSTNAME}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
	usage "Invalid public DNS address (must not be an IP address)"
fi

# Admin email
if [[ -z "${PDS_ADMIN_EMAIL}" ]]; then
	read -p "[PDS] Enter an admin email address (e.g. you@example.com): " PDS_ADMIN_EMAIL
fi
if [[ -z "${PDS_ADMIN_EMAIL}" ]]; then
	usage "No admin email specified"
fi

#
# Install system packages.
#
if lsof -v >/dev/null 2>&1; then
	while true; do
		apt_process_count="$(lsof -n -t /var/cache/apt/archives/lock /var/lib/apt/lists/lock /var/lib/dpkg/lock | wc --lines || true)"
		if (( apt_process_count == 0 )); then
			break
		fi
		echo "* Waiting for other apt process to complete..."
		sleep 2
	done
fi

apt-get update
apt-get install --yes ${REQUIRED_SYSTEM_PACKAGES}

#
# Install Docker
#
if ! docker version >/dev/null 2>&1; then
	echo "* Installing Docker"
	mkdir --parents /etc/apt/keyrings

	# Remove the existing file, if it exists,
	# so there's no prompt on a second run.
	rm --force /etc/apt/keyrings/docker.gpg
	curl --fail --silent --show-error --location "https://download.docker.com/linux/${DISTRIB_ID}/gpg" | \
		gpg --dearmor --output /etc/apt/keyrings/docker.gpg

	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRIB_ID} ${DISTRIB_CODENAME} stable" >/etc/apt/sources.list.d/docker.list

	apt-get update
	apt-get install --yes ${REQUIRED_DOCKER_PACKAGES}
fi

#
# Configure the Docker daemon so that logs don't fill up the disk.
#
if ! [[ -e /etc/docker/daemon.json ]]; then
	echo "* Configuring Docker daemon"
	cat <<'DOCKERD_CONFIG' >/etc/docker/daemon.json
{
"log-driver": "json-file",
"log-opts": {
	"max-size": "500m",
	"max-file": "4"
}
}
DOCKERD_CONFIG
	systemctl restart docker
else
	echo "* Docker daemon already configured! Ensure log rotation is enabled."
fi

#
# Create data directory.
#
if ! [[ -d "${PDS_DATADIR}" ]]; then
	echo "* Creating data directory ${PDS_DATADIR}"
	mkdir --parents "${PDS_DATADIR}"
fi
chmod 700 "${PDS_DATADIR}"

#
# Configure Caddy
#
if ! [[ -d "${PDS_DATADIR}/caddy/data" ]]; then
	echo "* Creating Caddy data directory"
	mkdir --parents "${PDS_DATADIR}/caddy/data"
fi
if ! [[ -d "${PDS_DATADIR}/caddy/etc/caddy" ]]; then
	echo "* Creating Caddy config directory"
	mkdir --parents "${PDS_DATADIR}/caddy/etc/caddy"
fi

echo "* Creating Caddy config file"
cat <<CADDYFILE >"${PDS_DATADIR}/caddy/etc/caddy/Caddyfile"
{
email ${PDS_ADMIN_EMAIL}
on_demand_tls {
	ask http://localhost:3000/tls-check
}
}

${PDS_HOSTNAME} {
tls {
	on_demand
}

@pds {
	path /xrpc/*
	path /oauth/*
	path /.well-known/oauth-protected-resource
	path /.well-known/oauth-authorization-server
	path /@atproto/*
	path /gate
	path /.well-known/atproto-did
}

reverse_proxy @pds http://localhost:3000
reverse_proxy http://localhost:8080
}

*.${PDS_HOSTNAME} {
tls {
	on_demand
}
reverse_proxy http://localhost:3000
}
CADDYFILE

#
# Create the PDS env config
#
# Created here so that we can use it later in multiple places.
PDS_ADMIN_PASSWORD=$(eval "${GENERATE_SECURE_SECRET_CMD}")
cat <<PDS_CONFIG >"${PDS_DATADIR}/pds.env"
PDS_HOSTNAME=${PDS_HOSTNAME}
PDS_JWT_SECRET=$(eval "${GENERATE_SECURE_SECRET_CMD}")
PDS_ADMIN_PASSWORD=${PDS_ADMIN_PASSWORD}
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=$(eval "${GENERATE_K256_PRIVATE_KEY_CMD}")
PDS_DATA_DIRECTORY=${PDS_DATADIR}
PDS_BLOBSTORE_DISK_LOCATION=${PDS_DATADIR}/blocks
PDS_BLOB_UPLOAD_LIMIT=52428800
PDS_DID_PLC_URL=${PDS_DID_PLC_URL}
PDS_BSKY_APP_VIEW_URL=${PDS_BSKY_APP_VIEW_URL}
PDS_BSKY_APP_VIEW_DID=${PDS_BSKY_APP_VIEW_DID}
PDS_REPORT_SERVICE_URL=${PDS_REPORT_SERVICE_URL}
PDS_REPORT_SERVICE_DID=${PDS_REPORT_SERVICE_DID}
PDS_CRAWLERS=${PDS_CRAWLERS}
LOG_ENABLED=true
PDS_CONFIG

#
# Download and install pds launcher.
#
echo "* Downloading PDS compose file"
curl \
	--silent \
	--show-error \
	--fail \
	--output "${PDS_DATADIR}/compose.yaml" \
	"${PDS_COMPOSE_URL}"

# Replace the /pds paths with the ${PDS_DATADIR} path.
sed --in-place "s|/pds|${PDS_DATADIR}|g" "${PDS_DATADIR}/compose.yaml"

#
# Create the systemd service.
#
echo "* Starting the pds systemd service"
cat <<SYSTEMD_UNIT_FILE >/etc/systemd/system/pds.service
[Unit]
Description=Bluesky PDS Service
Documentation=https://github.com/bluesky-social/pds
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${PDS_DATADIR}
ExecStart=/usr/bin/docker compose --file ${PDS_DATADIR}/compose.yaml up --detach
ExecStop=/usr/bin/docker compose --file ${PDS_DATADIR}/compose.yaml down

[Install]
WantedBy=default.target
SYSTEMD_UNIT_FILE

systemctl daemon-reload
systemctl enable pds
systemctl restart pds

# Enable firewall access if ufw is in use.
if ufw status >/dev/null 2>&1; then
	if ! ufw status | grep --quiet '^80[/ ]'; then
		echo "* Enabling access on TCP port 80 using ufw"
		ufw allow 80/tcp >/dev/null
	fi
	if ! ufw status | grep --quiet '^443[/ ]'; then
		echo "* Enabling access on TCP port 443 using ufw"
		ufw allow 443/tcp >/dev/null
	fi
fi

#
# Download and install pdadmin.
#
echo "* Downloading pdsadmin"
curl \
	--silent \
	--show-error \
	--fail \
	--output "/usr/local/bin/pdsadmin" \
	"${PDSADMIN_URL}"
chmod +x /usr/local/bin/pdsadmin


# MASTODON INSTALLER

#
# Create dedicated mastodon user for security
#
echo "* Creating mastodon user for secure installation"
if ! id mastodon >/dev/null 2>&1; then
	useradd --create-home --shell /bin/bash --groups docker mastodon
	echo "* Created mastodon user and added to docker group"
else
	echo "* mastodon user already exists"
	# Ensure user is in docker group
	usermod -a -G docker mastodon
fi

COMPOSE_URL="https://raw.githubusercontent.com/msonnb/mastodon/refs/heads/main/docker-compose.yml"
NGINX_CONFIG_URL="https://raw.githubusercontent.com/msonnb/mastodon/refs/heads/main/dist/nginx.conf"

function prompt_for_input {
  local prompt="$1"
  local var_name="$2"
	local empty_var_error="$3"
  local input_value=""

  while true; do
    read -p "$prompt" input_value
    if [ -n "$input_value" ]; then
      # Assign the input value to the variable specified by var_name
      # Using 'eval' to dynamically set the variable
      eval "$var_name=\"\$input_value\""
      break
    else
      echo "$empty_var_error"
    fi
  done
}

prompt_for_input "[Mastodon] Enter admin user name: " admin_user "Admin name cannot be empty. Please enter admin name."
prompt_for_input "[Mastodon] Enter admin email: " admin_email "Admin email cannot be empty. Please enter admin email."
prompt_for_input "[Mastodon] Enter valid domain name: " domain_name "Domain cannot be empty. Please enter domain."
prompt_for_input "[Mastodon] Enter SMTP SERVER: " smtp_server "SMTP SERVER cannot be empty. Please enter smtp server."
prompt_for_input "[Mastodon] Enter SMTP PORT: " smtp_port "SMTP PORT cannot be empty. Please enter smtp port."
prompt_for_input "[Mastodon] Enter SMTP LOGIN: " smtp_login "SMTP LOGIN cannot be empty. Please enter smtp_login."
prompt_for_input "[Mastodon] Enter SMTP_PASSWORD: " smtp_password "SMTP_PASSWORD cannot be empty. Please enter smtp password."
prompt_for_input "[Mastodon] Enter SMTP FROM ADDRESS: " smtp_from_address "SMTP FROM ADDRESS cannot be empty. Please enter smtp from address."

work_dir=/home/mastodon/mastodon

echo "* Setting up Mastodon work directory"
sudo rm -rf ${work_dir}
sudo -u mastodon mkdir -p ${work_dir}

echo "* Creating Mastodon environment file"
sudo -u mastodon touch ${work_dir}/.env.production
chmod 600 ${work_dir}/.env.production

echo "* Downloading docker-compose.yml file"
sudo -u mastodon curl \
	--silent \
	--show-error \
	--fail \
	--output ${work_dir}/docker-compose.yml \
	"${COMPOSE_URL}"

sudo -u mastodon mkdir -p ${work_dir}/public/system
sudo chown -R 991:991 ${work_dir}/public/system
sudo chmod -R 755 ${work_dir}/public/system

echo "* Generating secret keys"
secret1=$(sudo -u mastodon docker compose -f ${work_dir}/docker-compose.yml run --rm web bundle exec rails secret)
secret2=$(sudo -u mastodon docker compose -f ${work_dir}/docker-compose.yml run --rm web bundle exec rails secret)
active_record_encryption_keys=$(sudo -u mastodon docker compose -f ${work_dir}/docker-compose.yml run --rm web bin/rails db:encryption:init | tail -n 3)
vapid_keys=$(sudo -u mastodon docker compose -f ${work_dir}/docker-compose.yml run --rm web bundle exec rake mastodon:webpush:generate_vapid_key)

echo "* Creating .env.production file"
sudo -u mastodon cat <<mastodon_env >> ${work_dir}/.env.production
LOCAL_DOMAIN=${domain_name}
REDIS_HOST=redis
REDIS_PORT=6379
DB_HOST=db
DB_USER=postgres
DB_NAME=mastodon_production
DB_PASS=
DB_PORT=5432
ES_ENABLED=false
ES_HOST=es
ES_PORT=9200
ES_USER=elastic
ES_PASS=password
SECRET_KEY_BASE=${secret1}
OTP_SECRET=${secret2}
${active_record_encryption_keys}
${vapid_keys}
SMTP_SERVER=${smtp_server}
SMTP_PORT=${smtp_port}
SMTP_LOGIN=${smtp_login}
SMTP_PASSWORD=${smtp_password}
SMTP_FROM_ADDRESS=${smtp_from_address}
S3_ENABLED=false
S3_BUCKET=files.example.com
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
S3_ALIAS_HOST=files.example.com
IP_RETENTION_PERIOD=31556952
SESSION_RETENTION_PERIOD=31556952
RAIL_LOG_LEVEL=warn
ATPROTO_PDS_DOMAIN=${PDS_HOSTNAME}
ATPROTO_PDS_ADMIN_PASS=${PDS_ADMIN_PASSWORD}
GITHUB_REPOSITORY=msonnb/mastodon
mastodon_env

# Ensure proper permissions on the environment file
chmod 600 ${work_dir}/.env.production

echo "* Setting up database"
sudo -u mastodon docker compose -f ${work_dir}/docker-compose.yml run --rm web bundle exec rails db:setup

echo "* Starting Mastodon application"
sudo -u mastodon docker compose -f ${work_dir}/docker-compose.yml up -d

if nginx -v &>/dev/null; then
  echo "* Nginx is already installed"
  rm -f /etc/nginx/sites-available/mastodon
  rm -f /etc/nginx/sites-enabled/mastodon
else
	echo "* Installing Nginx"
  apt-get update
  apt-get install -y nginx
fi

rm -f /etc/nginx/sites-enabled/default

echo "* Downloading Nginx configuration file"
curl \
	--silent \
	--show-error \
	--fail \
	--output /etc/nginx/sites-available/mastodon \
	"${NGINX_CONFIG_URL}"

chmod 644 /etc/nginx/sites-available/mastodon

ln -s /etc/nginx/sites-available/mastodon /etc/nginx/sites-enabled/

systemctl restart nginx

echo "* Creating admin user"
admin_password=$(sudo -u mastodon docker compose -f ${work_dir}/docker-compose.yml run --rm web bin/tootctl accounts create ${admin_user} --email ${admin_email} --confirmed --role Owner | awk '/password:/{print }')

echo "* Approving admin user"
sudo -u mastodon docker compose -f ${work_dir}/docker-compose.yml run --rm web bin/tootctl accounts approve ${admin_user}

echo "* Creating Mastodon systemd service"
cat <<MASTODON_SYSTEMD_UNIT_FILE >/etc/systemd/system/mastodon.service
[Unit]
Description=Mastodon Social Media Service
Documentation=https://github.com/msonnb/mastodon
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=mastodon
Group=mastodon
WorkingDirectory=${work_dir}
ExecStart=/usr/bin/docker compose --file ${work_dir}/docker-compose.yml up --detach
ExecStop=/usr/bin/docker compose --file ${work_dir}/docker-compose.yml down

[Install]
WantedBy=default.target
MASTODON_SYSTEMD_UNIT_FILE

systemctl daemon-reload
systemctl enable mastodon

cat <<INSTALLER_MESSAGE
========================================================================
Installation completed successfully!
========================================================================

PDS and Mastodon services have been installed and configured.

Service Management
------------------------------------------------------------------------
PDS Service (running as root):
  Status: sudo systemctl status pds
  Logs:   sudo docker logs -f pds
  Data:   ${PDS_DATADIR}

Mastodon Service (running as mastodon user):
  Status: sudo systemctl status mastodon
  Logs:   sudo -u mastodon docker compose -f ${work_dir}/docker-compose.yml logs -f
  Data:   ${work_dir}

Access Information
------------------------------------------------------------------------
Mastodon Web Interface: https://${domain_name}
PDS Server:            https://${PDS_HOSTNAME}

Mastodon Admin Credentials:
  Email:    ${admin_email}
  Password: ${admin_password}

Administrative Commands
------------------------------------------------------------------------
PDS Admin:             pdsadmin help
Backup PDS data:       ${PDS_DATADIR}
Backup Mastodon data:  ${work_dir}

Required Firewall Ports
------------------------------------------------------------------------
Service                Direction  Port   Protocol  Source
-------                ---------  ----   --------  ----------------------
HTTP TLS verification  Inbound    80     TCP       Any
HTTPS Web Interface    Inbound    443    TCP       Any

Required DNS Entries
------------------------------------------------------------------------
Name                         Type       Value
-------                      ---------  ---------------
${PDS_HOSTNAME}              A          ${PUBLIC_IP}
*.${PDS_HOSTNAME}            A          ${PUBLIC_IP}
${domain_name}               A          ${PUBLIC_IP}

Detected public IP of this server: ${PUBLIC_IP}

Next Steps
------------------------------------------------------------------------
1. Verify DNS records are propagated (may take 3-5 minutes)
2. Access Mastodon at https://${domain_name} and log in with admin credentials
3. Configure Mastodon settings as needed
4. Test PDS functionality with pdsadmin commands

========================================================================
INSTALLER_MESSAGE