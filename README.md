# 3scale Porta Services - Installation Guide

This guide explains how to use the all-in-one installation script to deploy the complete 3scale Porta services setup.

## Quick Install

```bash
./install-3scale-services.sh
```

The script will:
1. Check for required dependencies (podman, podman-compose, openssl)
2. Ask for installation directory (default: ~/3scale-services)
3. Generate all files and certificates (including dual-purpose TLS certificates)
4. Set proper permissions using podman unshare
5. Provide instructions for starting services

## Installation Script Features

### ✓ Dependency Checking
- Verifies `podman` is installed
- Verifies `podman-compose` is installed
- Verifies `openssl` is installed
- Confirms rootless mode (recommended)

### ✓ Complete File Generation
- **podman-compose.yaml** - Main compose file with 22 services
  - 3 databases (MySQL, PostgreSQL, MySQL-SSL)
  - 17 Redis configurations
  - 2 additional services (Memcached, MailHog)
- **README.md** - Quick reference guide
- **All configuration files** - Redis, Twemproxy, Sentinel configs
- **TLS certificates** - CA, server, and client certificates (valid 10 years)
  - Dual-purpose server certificates with serverAuth + clientAuth
  - Separate client certificates for application use
  - All certificates use CN="localhost" for hostname verification

### ✓ Proper Permissions (Automated with podman unshare)
- Sentinel directories writable by containers (755)
- Sentinel configs writable (666) - modified at runtime by Redis
- Certificates with secure permissions (644 for all certs and keys)
- Unix socket directory accessible (777)
- File ownership automatically set for rootless containers:
  - Redis files: UID 999
  - Twemproxy files: UID 65534

### ✓ No Manual Intervention
- Everything automated
- No need to copy files manually
- No need to generate certificates separately
- Permissions automatically set with podman unshare

## Usage

### Default Installation
```bash
./install-3scale-services.sh
```

Installs to `~/3scale-services` (will prompt for confirmation)

### Custom Directory
```bash
./install-3scale-services.sh /path/to/custom/directory
```

Installs to specified directory without prompting

### Non-Interactive Install
```bash
echo "yes" | ./install-3scale-services.sh /path/to/directory
```

## What Gets Created

```
<install-directory>/
├── podman-compose.yaml          # Main compose file (22 services)
├── README.md                    # Quick reference
└── redis-configs/
    ├── certs/                   # TLS certificates (auto-generated)
    │   ├── ca-root-cert.pem     # CA certificate (CN=ca.localhost)
    │   ├── ca-root-key.pem      # CA private key
    │   ├── redis.crt            # Server certificate (serverAuth + clientAuth)
    │   ├── redis.key            # Server private key
    │   ├── redis-client.crt     # Client certificate (for applications)
    │   └── redis-client.key     # Client private key
    ├── redis-ha/               # Standard Redis HA configuration
    │   └── sentinel{1,2,3}/     # Sentinel configs
    │       └── sentinel.conf
    ├── twemproxy/              # Twemproxy configuration
    │   └── twemproxy.yml        # Main config with sharding
    ├── tls-redis/              # TLS Redis configuration
    │   ├── master.conf          # Master config
    │   ├── replica1.conf        # Replica 1 config
    │   ├── replica2.conf        # Replica 2 config
    │   └── sentinel{1,2,3}/     # TLS Sentinel configs
    │       └── sentinel.conf
    └── run/                    # Unix socket directory
```

## After Installation

### 1. Navigate to Installation Directory
```bash
cd ~/3scale-services  # or your custom directory
```

### 2. Start All Services
```bash
podman-compose up -d
```

### 3. Verify Services Are Running
```bash
podman-compose ps
```

Expected output: 22 services running

### 4. Check Logs
```bash
podman-compose logs -f
```

## Starting Specific Service Groups

### Core Services Only
```bash
podman-compose up -d 3scale-mysql 3scale-memcached 3scale-mailhog
```

### Redis High Availability
```bash
podman-compose up -d \
  3scale-redis-master \
  3scale-redis-replica1 \
  3scale-redis-replica2 \
  3scale-redis-sentinel1 \
  3scale-redis-sentinel2 \
  3scale-redis-sentinel3
```

### TLS Redis Cluster
```bash
podman-compose up -d \
  3scale-tls-redis-master \
  3scale-tls-redis-replica1 \
  3scale-tls-redis-replica2 \
  3scale-tls-redis-sentinel1 \
  3scale-tls-redis-sentinel2 \
  3scale-tls-redis-sentinel3
```

### Twemproxy with Sharding
```bash
podman-compose up -d \
  3scale-twemproxy \
  3scale-twemproxy-shard1 \
  3scale-twemproxy-shard2 \
  3scale-twemproxy-shard3
```

## Service Endpoints

| Service | Port | Access |
|---------|------|--------|
| MySQL | 3306 | `mysql -h 127.0.0.1 -u root` |
| MySQL SSL | 23306 | `mysql -h 127.0.0.1 -P 23306 -u root --ssl-mode=REQUIRED` |
| PostgreSQL 15 | 5432 | `psql -h 127.0.0.1 -U postgres` |
| Memcached | 11211 | `telnet 127.0.0.1 11211` |
| MailHog SMTP | 1025 | Use as SMTP server |
| MailHog Web | 8025 | http://localhost:8025 |
| Redis (pass) | 6385 | `redis-cli -p 6385 -a sup3rS3cre1!` |
| Redis Master | 6379 | `redis-cli` |
| Redis Replicas | 6380-6381 | `redis-cli -p 6380` |
| Sentinels | 26379-26381 | `redis-cli -p 26379` |
| Twemproxy | 22121 | `redis-cli -p 22121` |
| Twemproxy Shards | 6382-6384 | `redis-cli -p 6382` |
| TLS Redis | 46380-46382 | Requires TLS client (see below) |
| TLS Sentinels | 56380-56382 | Requires TLS client (see below) |

## Credentials

### Databases
- **MySQL**: root (no password)
- **PostgreSQL**: postgres (no password, trust auth)

### Redis
- **Password-protected (port 6385)**: `sup3rS3cre1!`
- **TLS Redis users**:
  - porta: `sup3rS3cre1!`
  - apisonator: `secret#Passw0rd`
- **TLS Sentinel**:
  - sentinel: `Passw0rd`

## TLS Configuration for Applications

### Certificate Files Generated

The installation script generates the following certificates (valid for 10 years):

1. **CA Certificate** (`ca-root-cert.pem`)
   - Common Name: `ca.localhost`
   - Used to verify server and client certificates

2. **Server Certificate** (`redis.crt` + `redis.key`)
   - Common Name: `localhost`
   - Extended Key Usage: `serverAuth` + `clientAuth` (dual-purpose)
   - Used by Redis/Sentinel for both accepting and making TLS connections
   - Subject Alternative Names: `DNS:localhost`, `IP:127.0.0.1`, `IP:::1`

3. **Client Certificate** (`redis-client.crt` + `redis-client.key`)
   - Common Name: `localhost`
   - Extended Key Usage: `clientAuth`
   - Used by applications (like Porta) to connect to TLS Redis
   - Subject Alternative Names: `DNS:localhost`, `IP:127.0.0.1`, `IP:::1`

### Environment Variables for Porta

To connect Porta to TLS Redis, configure these environment variables in `.env`:

```bash
# Redis TLS Configuration
REDIS_URL=rediss://redis-master/1
REDIS_SENTINEL_HOSTS=rediss://localhost:56380,rediss://localhost:56381,rediss://localhost:56382
REDIS_SENTINEL_USERNAME=sentinel
REDIS_SENTINEL_PASSWORD=Passw0rd
REDIS_USERNAME=porta
REDIS_PASSWORD=sup3rS3cre1!
REDIS_SSL=1
REDIS_CA_FILE=/path/to/3scale-services/redis-configs/certs/ca-root-cert.pem
REDIS_CLIENT_CERT=/path/to/3scale-services/redis-configs/certs/redis-client.crt
REDIS_PRIVATE_KEY=/path/to/3scale-services/redis-configs/certs/redis-client.key

# Backend Redis TLS Configuration
BACKEND_REDIS_URL=rediss://redis-master/6
BACKEND_REDIS_SENTINEL_HOSTS=rediss://localhost:56380,rediss://localhost:56381,rediss://localhost:56382
BACKEND_REDIS_SENTINEL_USERNAME=sentinel
BACKEND_REDIS_SENTINEL_PASSWORD=Passw0rd
BACKEND_REDIS_USERNAME=porta
BACKEND_REDIS_PASSWORD=sup3rS3cre1!
BACKEND_REDIS_SSL=1
BACKEND_REDIS_CA_FILE=/path/to/3scale-services/redis-configs/certs/ca-root-cert.pem
BACKEND_REDIS_CLIENT_CERT=/path/to/3scale-services/redis-configs/certs/redis-client.crt
BACKEND_REDIS_PRIVATE_KEY=/path/to/3scale-services/redis-configs/certs/redis-client.key
```

**Important Notes**:
- Use `redis-client.crt` and `redis-client.key` for application connections (NOT `redis.crt`/`redis.key`)
- The server certificate (`redis.crt`) is used by Redis/Sentinel containers only
- All certificates use `CN=localhost` for hostname verification
- The CA certificate path must be absolute
- Use `rediss://` scheme (note the double 's') for TLS connections

### Environment Variables for Apisonator

```bash
CONFIG_REDIS_PROXY=rediss://redis-master/6
CONFIG_REDIS_SENTINEL_HOSTS=rediss://localhost:56380,rediss://localhost:56381,rediss://localhost:56382
CONFIG_REDIS_SENTINEL_USERNAME=sentinel
CONFIG_REDIS_SENTINEL_PASSWORD=Passw0rd
CONFIG_REDIS_SENTINEL_ROLE=master
CONFIG_REDIS_USERNAME=apisonator
CONFIG_REDIS_PASSWORD=secret#Passw0rd
CONFIG_REDIS_SSL=true
CONFIG_REDIS_CA_FILE=/path/to/3scale-services/redis-configs/certs/ca-root-cert.pem
CONFIG_REDIS_CERT=/path/to/3scale-services/redis-configs/certs/redis-client.crt
CONFIG_REDIS_PRIVATE_KEY=/path/to/3scale-services/redis-configs/certs/redis-client.key

CONFIG_QUEUES_MASTER_NAME=rediss://redis-master/6
CONFIG_QUEUES_SENTINEL_HOSTS=rediss://localhost:56380,rediss://localhost:56381,rediss://localhost:56382
CONFIG_QUEUES_SENTINEL_USERNAME=sentinel
CONFIG_QUEUES_SENTINEL_PASSWORD=Passw0rd
CONFIG_QUEUES_SENTINEL_ROLE=master
CONFIG_QUEUES_USERNAME=apisonator
CONFIG_QUEUES_PASSWORD=secret#Passw0rd
CONFIG_QUEUES_SSL=true
CONFIG_QUEUES_CA_FILE=/path/to/3scale-services/redis-configs/certs/ca-root-cert.pem
CONFIG_QUEUES_CERT=/path/to/3scale-services/redis-configs/certs/redis-client.crt
CONFIG_QUEUES_PRIVATE_KEY=/path/to/3scale-services/redis-configs/certs/redis-client.key
```

## Troubleshooting

### Installation Fails - Missing Dependencies
```bash
# Install podman
sudo dnf install podman  # Fedora/RHEL
sudo apt install podman  # Debian/Ubuntu

# Install podman-compose
pip3 install podman-compose

# openssl is usually pre-installed
sudo dnf install openssl
```

### Permission Denied Errors
The script handles permissions automatically using `podman unshare`, but if you encounter issues:
```bash
cd <install-directory>

# Manual permission fix (if needed)
chmod 777 redis-configs/run
chmod 666 redis-configs/redis-ha/sentinel*/sentinel.conf
chmod 666 redis-configs/tls-redis/sentinel*/sentinel.conf

# Fix ownership for rootless containers
podman unshare chown -R 999:999 redis-configs/certs
podman unshare chown -R 999:999 redis-configs/redis-ha
podman unshare chown -R 999:999 redis-configs/tls-redis
podman unshare chown -R 65534:65534 redis-configs/twemproxy
podman unshare chown -R 999:999 redis-configs/run
```

### Services Won't Start
```bash
# Check logs for specific service
podman logs 3scale-mysql

# Verify no port conflicts
podman ps -a | grep -E "3306|6379|6385|11211"

# Restart services
podman-compose restart
```

### TLS Connection Errors
If you encounter TLS certificate verification errors:

1. **Verify certificate files exist**:
```bash
ls -la redis-configs/certs/
# Should show: ca-root-cert.pem, redis.crt, redis.key, redis-client.crt, redis-client.key
```

2. **Check certificate CN (should be "localhost")**:
```bash
openssl x509 -in redis-configs/certs/redis.crt -noout -subject
# Should show: subject=CN = localhost
```

3. **Verify extended key usage** (server cert should have both serverAuth and clientAuth):
```bash
openssl x509 -in redis-configs/certs/redis.crt -noout -text | grep -A1 "Extended Key Usage"
# Should show: TLS Web Server Authentication, TLS Web Client Authentication
```

4. **Test TLS connection**:
```bash
redis-cli --tls \
  --cert redis-configs/certs/redis-client.crt \
  --key redis-configs/certs/redis-client.key \
  --cacert redis-configs/certs/ca-root-cert.pem \
  -h localhost -p 46380 \
  -a sup3rS3cre1! \
  --user porta \
  PING
```

### Sentinel Configuration Warnings
This is normal! Sentinel files are modified at runtime by Redis:
- Lines starting with "# Generated by CONFIG REWRITE" are added automatically
- Sentinel IDs, epochs, and topology info are managed by Redis
- Don't edit these sections manually

## Clean Up

### Stop All Services
```bash
cd <install-directory>
podman-compose down
```

### Remove All Data (WARNING: Irreversible!)
```bash
cd <install-directory>
podman-compose down -v  # Removes volumes too
```

### Complete Removal
```bash
cd <install-directory>
podman-compose down -v
cd ..
rm -rf <install-directory>
```

## Advanced Usage

### Reinstall with Same Directory
```bash
./install-3scale-services.sh /existing/directory
# Answer "yes" or "y" when prompted to overwrite
```

### Generate Multiple Independent Environments
```bash
./install-3scale-services.sh ~/3scale-services-dev
./install-3scale-services.sh ~/3scale-services-test
./install-3scale-services.sh ~/3scale-services-staging
```

### Use Different Ports
Edit `podman-compose.yaml` after installation to change port mappings.

## Migration to Another Machine

### Export
```bash
cd ~
tar -czf 3scale-services.tar.gz 3scale-services/
scp 3scale-services.tar.gz user@target-machine:~
```

### Import
```bash
cd ~
tar -xzf 3scale-services.tar.gz
cd 3scale-services
podman-compose up -d
```

## Script Details

- **Location**: `./install-3scale-services.sh`
- **Size**: ~35KB
- **Version**: 1.0.0
- **Language**: Bash
- **Requirements**:
  - Bash 4.0+
  - podman (rootless mode recommended)
  - podman-compose
  - openssl (for certificate generation)

## What the Script Does NOT Do

- ❌ Start services automatically (you must run `podman-compose up -d`)
- ❌ Modify system-wide settings
- ❌ Require root/sudo privileges (runs in rootless mode)
- ❌ Download container images (happens when you start services)
- ❌ Connect to external services
- ❌ Modify existing containers

## Support

For issues or questions:
1. Check the generated `README.md` in your installation directory
2. Review logs: `podman-compose logs -f`
3. Verify installation: `podman-compose ps`

## Key Features and Improvements

### Version Updates
- **PostgreSQL**: Upgraded from 14 to **15**
- **Redis**: Upgraded from 6.2 to **7.2-alpine**

### Certificate Improvements
- **10-year validity** instead of 100 years (more realistic)
- **Dual-purpose server certificates** with both `serverAuth` and `clientAuth`
- **Separate client certificates** for application use
- **Correct CN values** (`ca.localhost` for CA, `localhost` for server/client)
- **Subject Alternative Names** for all certificates
- **Proper extended key usage** for mutual TLS authentication

### Permission Management
- **Automated podman unshare** for file ownership
- **Correct UIDs** for rootless containers (999 for Redis, 65534 for Twemproxy)
- **Proper permissions** for all config files and certificates

### Port Changes
- **Redis password-protected**: Moved from 6379 to **6385** (avoids conflicts)

### User Experience
- **Accepts y/n** in addition to yes/no for prompts
- **Better path handling** for installation directory
- **Colored output** with working ANSI codes
- **Clear service categorization** in output messages

### TLS Configuration
- **tls-auth-clients: optional** - allows flexible mutual TLS
- **Hostname verification** works out of the box
- **Inter-sentinel communication** over TLS
- **Master-replica replication** over TLS
- **Application connections** properly separated with client certs

## Additional Resources

- **Podman Documentation**: https://docs.podman.io
- **Redis Documentation**: https://redis.io/documentation
- **Redis TLS Documentation**: https://redis.io/docs/management/security/encryption/
- **3scale Documentation**: https://access.redhat.com/documentation/en-us/red_hat_3scale_api_management