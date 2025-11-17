#!/bin/bash
#
# 3scale Porta Services Installation Script
# ==========================================
# This script creates a complete podman-compose setup for 3scale Porta services
# including all required configuration files and TLS certificates.
#
# Usage: ./install-3scale-services.sh [target_directory]
#

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_VERSION="1.0.0"
DEFAULT_INSTALL_DIR="$HOME/3scale-services"

# Print functions
print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Function to check dependencies
check_dependencies() {
    print_header "Checking Required Tools"

    local missing_deps=()

    # Check for podman
    if ! command -v podman &> /dev/null; then
        missing_deps+=("podman")
        print_error "podman not found"
    else
        print_success "podman found: $(podman --version | head -1)"
    fi

    # Check for podman-compose
    if ! command -v podman-compose &> /dev/null; then
        missing_deps+=("podman-compose")
        print_error "podman-compose not found"
    else
        print_success "podman-compose found: $(podman-compose --version 2>&1 | head -1)"
    fi

    # Check for openssl (for certificate generation)
    if ! command -v openssl &> /dev/null; then
        missing_deps+=("openssl")
        print_error "openssl not found"
    else
        print_success "openssl found: $(openssl version)"
    fi

    # Check if running in rootless mode
    if [ "$EUID" -eq 0 ]; then
        print_warning "Running as root - containers will run in root mode"
    else
        print_success "Running in rootless mode (recommended)"
    fi

    echo ""

    # Exit if missing dependencies
    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing_deps[*]}"
        echo ""
        echo "Please install missing tools:"
        echo "  - podman: https://podman.io/getting-started/installation"
        echo "  - podman-compose: pip3 install podman-compose"
        echo "  - openssl: usually pre-installed or via package manager"
        echo ""
        exit 1
    fi

    print_success "All required tools available"
    echo ""
}

# Function to get installation directory
get_install_directory() {
    local target_dir="$1"

    if [ -z "$target_dir" ]; then
        echo "" >&2
        print_info "Installation directory selection" >&2
        echo "" >&2
        read -p "Enter installation directory [${DEFAULT_INSTALL_DIR}]: " target_dir
        target_dir="${target_dir:-$DEFAULT_INSTALL_DIR}"
    fi

    # Expand ~ to home directory
    target_dir="${target_dir/#\~/$HOME}"

    # Convert to absolute path if not already
    if [[ ! "$target_dir" = /* ]]; then
        target_dir="$(pwd)/$target_dir"
    fi

    # Normalize path (remove /. and /..)
    target_dir="$(realpath -m "$target_dir" 2>/dev/null || echo "$target_dir")"

    echo "$target_dir"
}

# Function to confirm installation
confirm_installation() {
    local install_dir="$1"

    echo ""
    print_header "Installation Summary"
    echo "Installation directory: $install_dir"
    echo "Services to be created: 22 containers"
    echo "  - 3 databases (MySQL, PostgreSQL, MySQL-SSL)"
    echo "  - 17 Redis configurations"
    echo "  - 2 additional services (Memcached, MailHog)"
    echo ""

    if [ -d "$install_dir" ]; then
        print_warning "Directory already exists: $install_dir"
        read -p "Do you want to overwrite it? (yes/no/y/n): " overwrite
        if [[ ! "$overwrite" =~ ^(yes|y)$ ]]; then
            print_info "Installation cancelled"
            exit 0
        fi
    fi

    read -p "Proceed with installation? (yes/no/y/n): " confirm
    if [[ ! "$confirm" =~ ^(yes|y)$ ]]; then
        print_info "Installation cancelled"
        exit 0
    fi
    echo ""
}

# Function to create directory structure
create_directory_structure() {
    local install_dir="$1"

    print_header "Creating Directory Structure"

    mkdir -p "$install_dir"
    mkdir -p "$install_dir/redis-configs/certs"
    mkdir -p "$install_dir/redis-configs/redis-ha/sentinel"{1,2,3}
    mkdir -p "$install_dir/redis-configs/twemproxy"
    mkdir -p "$install_dir/redis-configs/tls-redis/sentinel"{1,2,3}
    mkdir -p "$install_dir/redis-configs/run"

    print_success "Directory structure created"
    echo ""
}

# Function to generate TLS certificates
generate_certificates() {
    local install_dir="$1"
    local certs_dir="$install_dir/redis-configs/certs"

    print_header "Generating TLS Certificates"

    # Generate CA certificate
    print_info "Generating CA certificate..."
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "$certs_dir/ca-root-key.pem" \
        -out "$certs_dir/ca-root-cert.pem" \
        -subj "/CN=ca.localhost" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        2>/dev/null

    print_success "CA certificate generated (valid for 10 years)"

    # Generate server certificate
    print_info "Generating server certificate..."
    openssl req -newkey rsa:4096 -nodes \
        -keyout "$certs_dir/redis.key" \
        -out "$certs_dir/redis.csr" \
        -subj "/CN=localhost" \
        2>/dev/null

    # Sign server certificate with CA
    # Include both serverAuth and clientAuth so Redis/Sentinel can use it for both purposes
    openssl x509 -req -in "$certs_dir/redis.csr" -days 3650 \
        -CA "$certs_dir/ca-root-cert.pem" \
        -CAkey "$certs_dir/ca-root-key.pem" \
        -CAcreateserial \
        -out "$certs_dir/redis.crt" \
        -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth") \
        2>/dev/null

    # Clean up CSR
    rm -f "$certs_dir/redis.csr"

    print_success "Server certificate generated (valid for 10 years)"

    # Generate client certificate for mutual TLS
    print_info "Generating client certificate..."
    openssl req -newkey rsa:4096 -nodes \
        -keyout "$certs_dir/redis-client.key" \
        -out "$certs_dir/redis-client.csr" \
        -subj "/CN=localhost" \
        2>/dev/null

    # Sign client certificate with CA
    openssl x509 -req -in "$certs_dir/redis-client.csr" -days 3650 \
        -CA "$certs_dir/ca-root-cert.pem" \
        -CAkey "$certs_dir/ca-root-key.pem" \
        -CAcreateserial \
        -out "$certs_dir/redis-client.crt" \
        -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth") \
        2>/dev/null

    # Clean up CSR
    rm -f "$certs_dir/redis-client.csr"

    print_success "Client certificate generated (valid for 10 years)"

    # Set proper permissions
    chmod 644 "$certs_dir"/*.{pem,crt}
    chmod 644 "$certs_dir"/*.key  # Changed from 600 to 644 so Redis can read it

    print_success "Certificate permissions set"
    echo ""
}

# Function to create Twemproxy configuration
create_twemproxy_config() {
    local install_dir="$1"

    cat > "$install_dir/redis-configs/twemproxy/twemproxy.yml" << 'TWEMPROXY_EOF'
alpha:
  listen: 127.0.0.1:22121
  hash: fnv1a_64
  hash_tag: "{}"
  distribution: ketama
  auto_eject_hosts: true
  redis: true
  server_retry_timeout: 2000
  server_failure_limit: 1
  servers:
   - 127.0.0.1:6382:1 shard1
   - 127.0.0.1:6383:1 shard2
   - 127.0.0.1:6384:1 shard3
TWEMPROXY_EOF
}

# Function to create standard sentinel configs
create_standard_sentinel_configs() {
    local install_dir="$1"

    # Sentinel 1
    cat > "$install_dir/redis-configs/redis-ha/sentinel1/sentinel.conf" << 'SENTINEL1_EOF'
port 26379
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel monitor redis-master ::1 6379 2
sentinel down-after-milliseconds redis-master 5000
sentinel failover-timeout redis-master 60000
SENTINEL1_EOF

    # Sentinel 2
    cat > "$install_dir/redis-configs/redis-ha/sentinel2/sentinel.conf" << 'SENTINEL2_EOF'
port 26380
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel monitor redis-master ::1 6379 2
sentinel down-after-milliseconds redis-master 5000
sentinel failover-timeout redis-master 60000
SENTINEL2_EOF

    # Sentinel 3
    cat > "$install_dir/redis-configs/redis-ha/sentinel3/sentinel.conf" << 'SENTINEL3_EOF'
port 26381
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel monitor redis-master ::1 6379 2
sentinel down-after-milliseconds redis-master 5000
sentinel failover-timeout redis-master 60000
SENTINEL3_EOF
}

# Function to create TLS sentinel configs
create_tls_sentinel_configs() {
    local install_dir="$1"

    # TLS Sentinel 1
    cat > "$install_dir/redis-configs/tls-redis/sentinel1/sentinel.conf" << 'TLSSENTINEL1_EOF'
port 0
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel monitor redis-master localhost 46380 2
sentinel down-after-milliseconds redis-master 5000
sentinel failover-timeout redis-master 60000
tls-port 56380
tls-cert-file "/etc/redis.crt"
tls-key-file "/etc/redis.key"
tls-ca-cert-file "/etc/ca-root-cert.pem"
tls-auth-clients optional
tls-replication yes
user default off sanitize-payload &* -@all
user sentinel on #ab38eadaeb746599f2c1ee90f8267f31f467347462764a24d71ac1843ee77fe3 ~* &* +@all
sentinel auth-user redis-master apisonator
sentinel auth-pass redis-master secret#Passw0rd
sentinel sentinel-user sentinel
sentinel sentinel-pass Passw0rd
TLSSENTINEL1_EOF

    # TLS Sentinel 2
    cat > "$install_dir/redis-configs/tls-redis/sentinel2/sentinel.conf" << 'TLSSENTINEL2_EOF'
port 0
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel monitor redis-master localhost 46380 2
sentinel down-after-milliseconds redis-master 5000
sentinel failover-timeout redis-master 60000
tls-port 56381
tls-cert-file "/etc/redis.crt"
tls-key-file "/etc/redis.key"
tls-ca-cert-file "/etc/ca-root-cert.pem"
tls-auth-clients optional
tls-replication yes
user default off sanitize-payload &* -@all
user sentinel on #ab38eadaeb746599f2c1ee90f8267f31f467347462764a24d71ac1843ee77fe3 ~* &* +@all
sentinel auth-user redis-master apisonator
sentinel auth-pass redis-master secret#Passw0rd
sentinel sentinel-user sentinel
sentinel sentinel-pass Passw0rd
TLSSENTINEL2_EOF

    # TLS Sentinel 3
    cat > "$install_dir/redis-configs/tls-redis/sentinel3/sentinel.conf" << 'TLSSENTINEL3_EOF'
port 0
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel monitor redis-master localhost 46380 2
sentinel down-after-milliseconds redis-master 5000
sentinel failover-timeout redis-master 60000
tls-port 56382
tls-cert-file "/etc/redis.crt"
tls-key-file "/etc/redis.key"
tls-ca-cert-file "/etc/ca-root-cert.pem"
tls-auth-clients optional
tls-replication yes
user default off sanitize-payload &* -@all
user sentinel on #ab38eadaeb746599f2c1ee90f8267f31f467347462764a24d71ac1843ee77fe3 ~* &* +@all
sentinel auth-user redis-master apisonator
sentinel auth-pass redis-master secret#Passw0rd
sentinel sentinel-user sentinel
sentinel sentinel-pass Passw0rd
TLSSENTINEL3_EOF
}

# Function to create TLS Redis configs
create_tls_redis_configs() {
    local install_dir="$1"

    # Master config
    cat > "$install_dir/redis-configs/tls-redis/master.conf" << 'MASTER_EOF'
port 0
tls-port 46380
unixsocket /var/run/redis/tls-redis-master.sock
unixsocketperm 777
tls-cert-file /etc/redis.crt
tls-key-file /etc/redis.key
tls-ca-cert-file /etc/ca-root-cert.pem
tls-auth-clients optional
tls-replication yes
user default off
user porta on >sup3rS3cre1! ~* &* +@all
user apisonator on >secret#Passw0rd ~* &* +blpop +llen +lpop +lpush +lrange +ltrim +rpush +sadd +scan +scard +sismember +smembers +srem +sscan +del +exists +expire +get +mget +set +setex +zadd +zcard +zremrangebyscore +zrevrange +hset +incr +incrby +select +role +lindex +lrem +lset +brpoplpush +flushdb +keys +ping +ttl
MASTER_EOF

    # Replica 1 config
    cat > "$install_dir/redis-configs/tls-redis/replica1.conf" << 'REPLICA1_EOF'
port 0
tls-port 46381
tls-cert-file /etc/redis.crt
tls-key-file /etc/redis.key
tls-ca-cert-file /etc/ca-root-cert.pem
tls-auth-clients optional
tls-replication yes
user default off
user porta on >sup3rS3cre1! ~* &* +@all
masteruser porta
masterauth sup3rS3cre1!
user apisonator on >secret#Passw0rd ~* &* +blpop +llen +lpop +lpush +lrange +ltrim +rpush +sadd +scan +scard +sismember +smembers +srem +sscan +del +exists +expire +get +mget +set +setex +zadd +zcard +zremrangebyscore +zrevrange +hset +incr +incrby +select +role +lindex +lrem +lset +brpoplpush +flushdb +keys +ping +ttl
REPLICA1_EOF

    # Replica 2 config
    cat > "$install_dir/redis-configs/tls-redis/replica2.conf" << 'REPLICA2_EOF'
port 0
tls-port 46382
tls-cert-file /etc/redis.crt
tls-key-file /etc/redis.key
tls-ca-cert-file /etc/ca-root-cert.pem
tls-auth-clients optional
tls-replication yes
user default off
user porta on >sup3rS3cre1! ~* &* +@all
masteruser porta
masterauth sup3rS3cre1!
user apisonator on >secret#Passw0rd ~* &* +blpop +llen +lpop +lpush +lrange +ltrim +rpush +sadd +scan +scard +sismember +smembers +srem +sscan +del +exists +expire +get +mget +set +setex +zadd +zcard +zremrangebyscore +zrevrange +hset +incr +incrby +select +role +lindex +lrem +lset +brpoplpush +flushdb +keys +ping +ttl
REPLICA2_EOF
}

# Function to create configuration files
create_configuration_files() {
    local install_dir="$1"

    print_header "Creating Configuration Files"

    create_twemproxy_config "$install_dir"
    print_success "Twemproxy configuration created"

    create_standard_sentinel_configs "$install_dir"
    print_success "Standard sentinel configurations created"

    create_tls_sentinel_configs "$install_dir"
    print_success "TLS sentinel configurations created"

    create_tls_redis_configs "$install_dir"
    print_success "TLS Redis configurations created"

    echo ""
}

# Function to create podman-compose.yaml
create_compose_file() {
    local install_dir="$1"

    print_header "Creating Podman Compose File"

    cat > "$install_dir/podman-compose.yaml" << 'COMPOSE_EOF'
# Unified Podman Compose Configuration for 3scale Porta Services
# This file consolidates all the containers needed for local Porta development and testing
#
# Generated by install-3scale-services.sh
#
# Services included:
# - Core Porta services: MySQL, Memcached, MailHog, PostgreSQL
# - Redis configurations: Password-protected, Master-Replica with Sentinels, Twemproxy sharding, TLS-enabled
# - SSL-enabled databases for testing secure connections

version: '3.8'

services:
  # ============================================================================
  # Core Porta Services
  # ============================================================================

  3scale-mysql:
    image: mysql:8.0
    container_name: 3scale-mysql
    ports:
      - "3306:3306"
    environment:
      - MYSQL_ALLOW_EMPTY_PASSWORD=true
    healthcheck:
      test: "mysql --user=root --execute 'SHOW DATABASES;'"
      timeout: 20s
      retries: 10
    volumes:
      - mysql-data:/var/lib/mysql
    networks:
      - porta_default

  3scale-memcached:
    image: memcached:latest
    container_name: 3scale-memcached
    ports:
      - "11211:11211"
    networks:
      - porta_default

  3scale-mailhog:
    image: mailhog/mailhog:latest
    container_name: 3scale-mailhog
    ports:
      - "1025:1025"  # SMTP
      - "8025:8025"  # Web UI
    networks:
      - porta_default

  # ============================================================================
  # Standalone Databases
  # ============================================================================

  3scale-postgres:
    image: postgres:15
    container_name: 3scale-postgres
    ports:
      - "5432:5432"
    environment:
      - POSTGRES_PASSWORD=
      - POSTGRES_HOST_AUTH_METHOD=trust
    volumes:
      - pgdata:/var/lib/postgresql/data

  # ============================================================================
  # SSL-Enabled Databases (for testing secure connections)
  # ============================================================================

  3scale-mysql-ssl:
    image: mysql:8.0
    container_name: 3scale-mysql-ssl
    ports:
      - "23306:3306"
    environment:
      - MYSQL_ALLOW_EMPTY_PASSWORD=true
    healthcheck:
      test: "mysql --user=root --execute 'SHOW DATABASES;'"
      timeout: 20s
      retries: 10
    volumes:
      - mysql-data-ssl:/var/lib/mysql
      - ./redis-configs/certs/redis.crt:/etc/certs/server.crt:z
      - ./redis-configs/certs/redis.key:/etc/certs/server.key:z
      - ./redis-configs/certs/ca-root-cert.pem:/etc/certs/ca-root-cert.pem:z
    command:
      - mysqld
      - --require_secure_transport=ON
      - --ssl-ca=/etc/certs/ca-root-cert.pem
      - --ssl-cert=/etc/certs/server.crt
      - --ssl-key=/etc/certs/server.key
    networks:
      - ssl_default

  # ============================================================================
  # Password-Protected Redis
  # ============================================================================

  3scale-redis-pass:
    image: redis:7.2-alpine
    container_name: 3scale-redis-pass
    network_mode: host
    volumes:
      - redis-pass-data:/data
      - ./redis-configs/run:/var/run/redis:z
    command:
      - redis-server
      - --port
      - "6385"
      - --requirepass
      - "sup3rS3cre1!"

  # ============================================================================
  # Redis Master-Replica with Sentinels (Twemproxy setup)
  # Standard Redis replication with three sentinels for high availability
  # ============================================================================

  3scale-redis-master:
    image: redis:7.2-alpine
    container_name: 3scale-redis-master
    network_mode: host
    volumes:
      - redis-master-data:/data
      - ./redis-configs/run:/var/run/redis:z
    command:
      - redis-server
      - --port
      - "6379"
      - --unixsocket
      - /var/run/redis/redis.sock
      - --unixsocketperm
      - "777"

  3scale-redis-replica1:
    image: redis:7.2-alpine
    container_name: 3scale-redis-replica1
    network_mode: host
    volumes:
      - redis-replica1-data:/data
    command:
      - redis-server
      - --slaveof
      - localhost
      - "6379"
      - --port
      - "6380"
    depends_on:
      - 3scale-redis-master

  3scale-redis-replica2:
    image: redis:7.2-alpine
    container_name: 3scale-redis-replica2
    network_mode: host
    volumes:
      - redis-replica2-data:/data
    command:
      - redis-server
      - --slaveof
      - localhost
      - "6379"
      - --port
      - "6381"
    depends_on:
      - 3scale-redis-master

  3scale-redis-sentinel1:
    image: redis:7.2-alpine
    container_name: 3scale-redis-sentinel1
    network_mode: host
    volumes:
      - ./redis-configs/redis-ha/sentinel1:/data:Z
    command:
      - redis-server
      - /data/sentinel.conf
      - --sentinel
      - --port
      - "26379"
    depends_on:
      - 3scale-redis-master

  3scale-redis-sentinel2:
    image: redis:7.2-alpine
    container_name: 3scale-redis-sentinel2
    network_mode: host
    volumes:
      - ./redis-configs/redis-ha/sentinel2:/data:Z
    command:
      - redis-server
      - /data/sentinel.conf
      - --sentinel
      - --port
      - "26380"
    depends_on:
      - 3scale-redis-master

  3scale-redis-sentinel3:
    image: redis:7.2-alpine
    container_name: 3scale-redis-sentinel3
    network_mode: host
    volumes:
      - ./redis-configs/redis-ha/sentinel3:/data:Z
    command:
      - redis-server
      - /data/sentinel.conf
      - --sentinel
      - --port
      - "26381"
    depends_on:
      - 3scale-redis-master

  # ============================================================================
  # Twemproxy (Redis Proxy with Sharding)
  # Provides connection pooling and sharding across multiple Redis instances
  # ============================================================================

  3scale-twemproxy:
    image: quay.io/3scale/twemproxy:v0.5.0
    container_name: 3scale-twemproxy
    network_mode: host
    environment:
      - TWEMPROXY_CONFIG_FILE=/etc/twemproxy/nutcracker.yml
    volumes:
      - ./redis-configs/twemproxy/twemproxy.yml:/etc/twemproxy/nutcracker.yml:Z
    depends_on:
      - 3scale-twemproxy-shard1
      - 3scale-twemproxy-shard2
      - 3scale-twemproxy-shard3

  3scale-twemproxy-shard1:
    image: redis:7.2-alpine
    container_name: 3scale-twemproxy-shard1
    network_mode: host
    volumes:
      - twemproxy-shard1-data:/data
    command:
      - redis-server
      - --port
      - "6382"

  3scale-twemproxy-shard2:
    image: redis:7.2-alpine
    container_name: 3scale-twemproxy-shard2
    network_mode: host
    volumes:
      - twemproxy-shard2-data:/data
    command:
      - redis-server
      - --port
      - "6383"

  3scale-twemproxy-shard3:
    image: redis:7.2-alpine
    container_name: 3scale-twemproxy-shard3
    network_mode: host
    volumes:
      - twemproxy-shard3-data:/data
    command:
      - redis-server
      - --port
      - "6384"

  # ============================================================================
  # TLS-Enabled Redis Master-Replica with Sentinels
  # Secure Redis setup with TLS encryption for all connections
  # ============================================================================

  3scale-tls-redis-master:
    image: redis:7.2-alpine
    container_name: 3scale-tls-redis-master
    network_mode: host
    ports:
      - "46380:46380"
    volumes:
      - tls-redis-master-data:/data
      - ./redis-configs/tls-redis/master.conf:/etc/redis.conf:z
      - ./redis-configs/certs/redis.crt:/etc/redis.crt:z
      - ./redis-configs/certs/redis.key:/etc/redis.key:z
      - ./redis-configs/certs/ca-root-cert.pem:/etc/ca-root-cert.pem:z
      - ./redis-configs/run:/var/run/redis:z
    command:
      - redis-server
      - /etc/redis.conf

  3scale-tls-redis-replica1:
    image: redis:7.2-alpine
    container_name: 3scale-tls-redis-replica1
    network_mode: host
    ports:
      - "46381:46381"
    volumes:
      - tls-redis-replica1-data:/data
      - ./redis-configs/tls-redis/replica1.conf:/etc/redis.conf:z
      - ./redis-configs/certs/redis.crt:/etc/redis.crt:z
      - ./redis-configs/certs/redis.key:/etc/redis.key:z
      - ./redis-configs/certs/ca-root-cert.pem:/etc/ca-root-cert.pem:z
    command:
      - redis-server
      - /etc/redis.conf
      - --slaveof
      - localhost
      - "46380"
    depends_on:
      - 3scale-tls-redis-master

  3scale-tls-redis-replica2:
    image: redis:7.2-alpine
    container_name: 3scale-tls-redis-replica2
    network_mode: host
    ports:
      - "46382:46382"
    volumes:
      - tls-redis-replica2-data:/data
      - ./redis-configs/tls-redis/replica2.conf:/etc/redis.conf:z
      - ./redis-configs/certs/redis.crt:/etc/redis.crt:z
      - ./redis-configs/certs/redis.key:/etc/redis.key:z
      - ./redis-configs/certs/ca-root-cert.pem:/etc/ca-root-cert.pem:z
    command:
      - redis-server
      - /etc/redis.conf
      - --slaveof
      - localhost
      - "46380"
    depends_on:
      - 3scale-tls-redis-master

  3scale-tls-redis-sentinel1:
    image: redis:7.2-alpine
    container_name: 3scale-tls-redis-sentinel1
    network_mode: host
    ports:
      - "56380:56380"
    volumes:
      - ./redis-configs/tls-redis/sentinel1:/data:Z
      - ./redis-configs/certs/redis.crt:/etc/redis.crt:z
      - ./redis-configs/certs/redis.key:/etc/redis.key:z
      - ./redis-configs/certs/ca-root-cert.pem:/etc/ca-root-cert.pem:z
    command:
      - redis-server
      - /data/sentinel.conf
      - --sentinel
    depends_on:
      - 3scale-tls-redis-master

  3scale-tls-redis-sentinel2:
    image: redis:7.2-alpine
    container_name: 3scale-tls-redis-sentinel2
    network_mode: host
    ports:
      - "56381:56381"
    volumes:
      - ./redis-configs/tls-redis/sentinel2:/data:Z
      - ./redis-configs/certs/redis.crt:/etc/redis.crt:z
      - ./redis-configs/certs/redis.key:/etc/redis.key:z
      - ./redis-configs/certs/ca-root-cert.pem:/etc/ca-root-cert.pem:z
    command:
      - redis-server
      - /data/sentinel.conf
      - --sentinel
    depends_on:
      - 3scale-tls-redis-master

  3scale-tls-redis-sentinel3:
    image: redis:7.2-alpine
    container_name: 3scale-tls-redis-sentinel3
    network_mode: host
    ports:
      - "56382:56382"
    volumes:
      - ./redis-configs/tls-redis/sentinel3:/data:Z
      - ./redis-configs/certs/redis.crt:/etc/redis.crt:z
      - ./redis-configs/certs/redis.key:/etc/redis.key:z
      - ./redis-configs/certs/ca-root-cert.pem:/etc/ca-root-cert.pem:z
    command:
      - redis-server
      - /data/sentinel.conf
      - --sentinel
    depends_on:
      - 3scale-tls-redis-master

# ============================================================================
# Networks
# ============================================================================

networks:
  porta_default:
    driver: bridge
  ssl_default:
    driver: bridge

# ============================================================================
# Volumes
# ============================================================================

volumes:
  # Core services
  mysql-data:
  pgdata:

  # SSL databases
  mysql-data-ssl:

  # Redis instances
  redis-pass-data:
  redis-master-data:
  redis-replica1-data:
  redis-replica2-data:

  # Twemproxy shards
  twemproxy-shard1-data:
  twemproxy-shard2-data:
  twemproxy-shard3-data:

  # TLS Redis
  tls-redis-master-data:
  tls-redis-replica1-data:
  tls-redis-replica2-data:
COMPOSE_EOF

    print_success "Podman compose file created"
    echo ""
}

# Function to set proper permissions
set_permissions() {
    local install_dir="$1"

    print_header "Setting Permissions"

    # Set permissions for sentinel directories (need to be writable by containers)
    chmod 777 "$install_dir/redis-configs/run"
    chmod -R 755 "$install_dir/redis-configs/redis-ha/sentinel"{1,2,3}
    chmod -R 755 "$install_dir/redis-configs/tls-redis/sentinel"{1,2,3}

    # Sentinel conf files need to be writable
    chmod 666 "$install_dir/redis-configs/redis-ha/sentinel"{1,2,3}"/sentinel.conf"
    chmod 666 "$install_dir/redis-configs/tls-redis/sentinel"{1,2,3}"/sentinel.conf"

    # Configuration files readable
    chmod 644 "$install_dir/redis-configs/twemproxy/twemproxy.yml"
    chmod 644 "$install_dir/redis-configs/tls-redis"/*.conf

    print_success "File permissions set"

    # Set ownership for files accessed by containers using podman unshare
    # This maps the host user to the container's user namespace
    print_info "Setting ownership for container access..."

    if command -v podman &> /dev/null && [ "$EUID" -ne 0 ]; then
        # In rootless mode, use podman unshare to set ownership
        # Redis containers typically run as UID 999 inside the container
        # Twemproxy container runs as UID 65534 (nobody)
        # We need to chown files in the user namespace

        # Certificates (Redis UID 999)
        podman unshare chown -R 999:999 "$install_dir/redis-configs/certs" 2>/dev/null || \
            print_warning "Could not set certificate ownership (podman unshare failed)"

        # TLS Redis configs (Redis UID 999)
        podman unshare chown -R 999:999 "$install_dir/redis-configs/tls-redis" 2>/dev/null || \
            print_warning "Could not set TLS Redis config ownership (podman unshare failed)"

        # Standard Redis HA sentinel configs (Redis UID 999)
        podman unshare chown -R 999:999 "$install_dir/redis-configs/redis-ha" 2>/dev/null || \
            print_warning "Could not set Redis HA sentinel ownership (podman unshare failed)"

        # Twemproxy config (nobody UID 65534)
        podman unshare chown -R 65534:65534 "$install_dir/redis-configs/twemproxy" 2>/dev/null || \
            print_warning "Could not set Twemproxy config ownership (podman unshare failed)"

        # Run directory for sockets (needs to be accessible by Redis UID 999)
        podman unshare chown -R 999:999 "$install_dir/redis-configs/run" 2>/dev/null || \
            print_warning "Could not set run directory ownership (podman unshare failed)"

        print_success "Container ownership set"
    else
        print_warning "Skipping ownership setting (running as root or podman not available)"
    fi

    echo ""
}

# Function to create README
create_readme() {
    local install_dir="$1"

    cat > "$install_dir/README.md" << 'README_EOF'
# 3scale Porta Services

This directory contains a complete podman-compose setup for 3scale Porta services.

## Quick Start

### Start all services
```bash
cd $(pwd)
podman-compose up -d
```

### Check service status
```bash
podman-compose ps
```

### View logs
```bash
podman-compose logs -f
```

### Stop all services
```bash
podman-compose down
```

## Services

### Core Services (ports 3306, 11211, 1025, 8025, 5432)
- **3scale-mysql** - MySQL 8.0 database
- **3scale-memcached** - Memcached cache
- **3scale-mailhog** - Email testing (SMTP: 1025, Web: 8025)
- **3scale-postgres** - PostgreSQL 15

### SSL Services (port 23306)
- **3scale-mysql-ssl** - MySQL with TLS

### Redis Services
- **3scale-redis-pass** - Password-protected Redis (port 6385, password: sup3rS3cre1!)
- **Redis HA** - Master + 2 replicas + 3 sentinels (ports 6379-6381, 26379-26381)
- **Twemproxy** - Sharded Redis (3 shards on ports 6382-6384)
- **TLS Redis** - Encrypted Redis + replicas + sentinels (ports 46380-46382, 56380-56382)

## Connection Examples

### MySQL
```bash
mysql -h 127.0.0.1 -P 3306 -u root
```

### MySQL with SSL
```bash
mysql -h 127.0.0.1 -P 23306 -u root --ssl-mode=REQUIRED
```

### PostgreSQL
```bash
psql -h 127.0.0.1 -U postgres
```

### Redis (password-protected)
```bash
redis-cli -p 6385 -a sup3rS3cre1!
```

### MailHog Web UI
```
http://localhost:8025
```

## Starting Specific Services

### Core services only
```bash
podman-compose up -d 3scale-mysql 3scale-memcached 3scale-mailhog
```

### Redis HA cluster
```bash
podman-compose up -d 3scale-redis-master 3scale-redis-replica1 3scale-redis-replica2 3scale-redis-sentinel1 3scale-redis-sentinel2 3scale-redis-sentinel3
```

### TLS Redis cluster
```bash
podman-compose up -d 3scale-tls-redis-master 3scale-tls-redis-replica1 3scale-tls-redis-replica2 3scale-tls-redis-sentinel1 3scale-tls-redis-sentinel2 3scale-tls-redis-sentinel3
```

## File Structure

```
.
├── podman-compose.yaml          # Main compose file
├── README.md                    # This file
└── redis-configs/
    ├── certs/                   # TLS certificates
    │   ├── ca-root-cert.pem     # CA certificate
    │   ├── ca-root-key.pem      # CA private key
    │   ├── redis.crt            # Server certificate
    │   ├── redis.key            # Server private key
    │   ├── redis-client.crt     # Client certificate
    │   └── redis-client.key     # Client private key
    ├── redis-ha/               # Standard Redis HA configs
    │   └── sentinel{1,2,3}/
    │       └── sentinel.conf
    ├── twemproxy/              # Twemproxy config (sharding only)
    │   └── twemproxy.yml
    ├── tls-redis/              # TLS Redis configs
    │   ├── master.conf
    │   ├── replica1.conf
    │   ├── replica2.conf
    │   └── sentinel{1,2,3}/
    │       └── sentinel.conf
    └── run/                    # Unix sockets
```

## Troubleshooting

### View container logs
```bash
podman logs 3scale-mysql
```

### Restart a service
```bash
podman-compose restart 3scale-mysql
```

### Clean up everything
```bash
podman-compose down -v  # Warning: deletes all data!
```

## Credentials

- MySQL: root (no password)
- PostgreSQL: postgres (no password, trust auth)
- Redis (password-protected): sup3rS3cre1!
- TLS Redis users:
  - porta: sup3rS3cre1!
  - apisonator: secret#Passw0rd

## Notes

- Sentinel configuration files will be modified by Redis at runtime (this is normal)
- TLS certificates are valid for 10 years
- Most Redis services use host networking for inter-service communication
README_EOF
}

# Function to print success summary
print_success_summary() {
    local install_dir="$1"

    print_header "Installation Complete!"

    echo ""
    print_success "Installation directory: $install_dir"
    print_success "22 services configured"
    print_success "TLS certificates generated (valid for 10 years)"
    print_success "All configuration files created"
    echo ""

    print_header "Next Steps"
    echo ""
    echo "1. Navigate to the installation directory:"
    echo -e "   ${GREEN}cd $install_dir${NC}"
    echo ""
    echo "2. Start all services:"
    echo -e "   ${GREEN}podman-compose up -d${NC}"
    echo ""
    echo "3. Check service status:"
    echo -e "   ${GREEN}podman-compose ps${NC}"
    echo ""
    echo "4. View logs:"
    echo -e "   ${GREEN}podman-compose logs -f${NC}"
    echo ""
    echo "For more information, see:"
    echo -e "   ${BLUE}$install_dir/README.md${NC}"
    echo ""
}

# Main installation function
main() {
    print_header "3scale Porta Services Installer v${SCRIPT_VERSION}"
    echo ""

    # Check dependencies
    check_dependencies

    # Get installation directory
    install_dir=$(get_install_directory "$1")

    # Confirm installation
    confirm_installation "$install_dir"

    # Create directory structure
    create_directory_structure "$install_dir"

    # Generate certificates
    generate_certificates "$install_dir"

    # Create configuration files
    create_configuration_files "$install_dir"

    # Create compose file
    create_compose_file "$install_dir"

    # Set permissions
    set_permissions "$install_dir"

    # Create README
    create_readme "$install_dir"

    # Print success summary
    print_success_summary "$install_dir"
}

# Run main function
main "$@"
