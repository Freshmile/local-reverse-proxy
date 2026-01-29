# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Traefik reverse proxy configuration for local HTTPS development with **automatic certificate generation via step-ca ACME**. When a new service starts, Traefik automatically requests a certificate from the local step-ca Certificate Authority.

**Stack:** Docker Compose, Traefik v3.2, step-ca (Smallstep), Make

## Common Commands

```bash
make setup         # Complete first-time setup (starts containers, installs CA)
make start         # Start Traefik and step-ca containers
make stop          # Stop all containers
make restart       # Restart all containers
make logs          # Stream Traefik logs (follow mode)
make logs-ca       # Stream step-ca logs (follow mode)
make status        # Check container status and CA certificate presence
make install-ca    # Install CA certificate in system trust store
make clean         # Remove containers, volumes, and certificates (prompts for confirmation)
```

## Architecture

**Certificate flow:**
```
Service starts with Traefik labels
    ↓
Traefik detects new domain
    ↓
Traefik requests certificate from step-ca (ACME)
    ↓
step-ca generates and signs certificate
    ↓
Traefik uses the certificate
    ↓
Browser accepts (CA installed in trust store)
```

**Container startup order:**
1. `step-ca` starts on host network and becomes healthy (local ACME CA on port 9000)
2. `traefik` starts after step-ca is healthy (`service_healthy` condition)

**Network architecture:**
- `step-ca` runs with `network_mode: host` so it can reach `*.localhost` for ACME TLS challenge validation
- `traefik` connects to step-ca via `host.docker.internal:9000`
- Services run on `traefik_network` (bridge)

**Service discovery:** Traefik watches the Docker socket and auto-discovers services with appropriate labels. Services must:
- Join the `traefik_network` network
- Have `traefik.enable=true` label
- Use `tls.certresolver=stepca` for automatic certificates
- Define routing rules via labels (see `examples/example-service.yml`)

**Configuration files:**
- `traefik/traefik.yml` - Static config (entrypoints, providers, certificatesResolvers)
- `traefik/dynamic/tls.yml` - Dynamic TLS options (cipher suites, TLS versions)
- `traefik/acme/acme.json` - ACME certificate storage (auto-generated)
- `scripts/install-ca.sh` - Installs CA certificate in browser trust stores (Chrome, Firefox)

**Certificate system:**
- CA cert: `certs/root_ca.crt` (extracted from step-ca, must be installed in browser)
- Certificates: Generated on-demand by step-ca via ACME, stored in `traefik/acme/acme.json`
- Certificates are automatically renewed by Traefik

## Adding Services

Services connect to Traefik via Docker labels with automatic certificate generation:

```yaml
services:
  my-app:
    image: nginx:alpine
    networks:
      - traefik_network
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik_network"
      - "traefik.http.routers.my-app.rule=Host(`my-app.localhost`)"
      - "traefik.http.routers.my-app.entrypoints=websecure"
      - "traefik.http.routers.my-app.tls.certresolver=stepca"
      - "traefik.http.services.my-app.loadbalancer.server.port=80"

networks:
  traefik_network:
    external: true
```

**Key label:** `tls.certresolver=stepca` - this triggers automatic certificate generation.

See `examples/example-service.yml` for advanced patterns (path prefixes, multiple domains, health checks, middlewares).

## Ports

- 80: HTTP (redirects to HTTPS)
- 443: HTTPS
- 8080: Traefik dashboard (http://traefik.localhost:8080/dashboard/)
- 9000: step-ca ACME server (host network, used by Traefik via `host.docker.internal`)
