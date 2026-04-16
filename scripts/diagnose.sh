#!/bin/bash
# Diagnose connectivity issues between Traefik and step-ca

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

FAILED=0
SKIPPED=0

ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    shift
    while [ $# -gt 0 ]; do
        echo -e "       ${YELLOW}→${NC} $1"
        shift
    done
    FAILED=$((FAILED + 1))
}
skip() {
    echo -e "${BLUE}[SKIP]${NC} $1"
    SKIPPED=$((SKIPPED + 1))
}
section() { echo -e "\n${BLUE}── $1${NC}"; }

# ─── 1. Docker ────────────────────────────────────────────────────────────────
section "Docker"

# 1a. Docker installed
if ! command -v docker &>/dev/null; then
    fail "Docker is not installed"
    echo -e "\n${RED}Cannot continue without Docker.${NC}"
    exit 1
fi

# 1b. Docker version >= 20.10 (required for host-gateway in extra_hosts)
DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0.0")
DOCKER_MAJOR=$(echo "$DOCKER_VERSION" | cut -d. -f1)
DOCKER_MINOR=$(echo "$DOCKER_VERSION" | cut -d. -f2)

if [ "$DOCKER_MAJOR" -gt 20 ] || { [ "$DOCKER_MAJOR" -eq 20 ] && [ "$DOCKER_MINOR" -ge 10 ]; }; then
    ok "Docker version $DOCKER_VERSION (>= 20.10, host-gateway supported)"
else
    fail "Docker version $DOCKER_VERSION is too old (need >= 20.10 for host-gateway)" \
        "Upgrade Docker Engine: https://docs.docker.com/engine/install/"
fi

# 1c. Docker daemon running
if docker info &>/dev/null; then
    ok "Docker daemon is running"
else
    fail "Docker daemon is not running" \
        "Try: sudo systemctl start docker"
    echo -e "\n${RED}Cannot continue without Docker daemon.${NC}"
    exit 1
fi

# 1d. Detect Docker Desktop vs Docker Engine
DOCKER_CONTEXT=$(docker context show 2>/dev/null || echo "default")
DOCKER_INFO=$(docker info 2>/dev/null || true)
IS_DOCKER_DESKTOP=false
if echo "$DOCKER_INFO" | grep -q "Docker Desktop"; then
    IS_DOCKER_DESKTOP=true
fi
if [ "$IS_DOCKER_DESKTOP" = true ]; then
    ok "Docker Desktop detected (host.docker.internal is natively available)"
else
    ok "Docker Engine detected (host.docker.internal via extra_hosts host-gateway)"
fi

# ─── 2. Containers ────────────────────────────────────────────────────────────
section "Containers"

STEPCA_STATUS=$(docker inspect --format '{{.State.Status}}' step-ca 2>/dev/null || echo "missing")
STEPCA_HEALTH=$(docker inspect --format '{{.State.Health.Status}}' step-ca 2>/dev/null || echo "none")
TRAEFIK_STATUS=$(docker inspect --format '{{.State.Status}}' traefik 2>/dev/null || echo "missing")

# 2a. step-ca running
if [ "$STEPCA_STATUS" = "running" ]; then
    ok "step-ca container is running"
else
    fail "step-ca container is not running (status: $STEPCA_STATUS)" \
        "Try: make proxy-start" \
        "Check logs: make logs-ca"
fi

# 2b. step-ca healthy
if [ "$STEPCA_HEALTH" = "healthy" ]; then
    ok "step-ca is healthy"
elif [ "$STEPCA_HEALTH" = "starting" ]; then
    warn "step-ca health check is still starting — wait and retry"
elif [ "$STEPCA_HEALTH" = "none" ]; then
    warn "step-ca has no healthcheck configured"
else
    fail "step-ca is not healthy (health: $STEPCA_HEALTH)" \
        "Check logs: make logs-ca"
fi

# 2c. traefik running
if [ "$TRAEFIK_STATUS" = "running" ]; then
    ok "traefik container is running"
else
    fail "traefik container is not running (status: $TRAEFIK_STATUS)" \
        "Try: make proxy-start" \
        "Check logs: make logs"
fi

# Bail if either container is missing — next checks would fail anyway
if [ "$STEPCA_STATUS" != "running" ] || [ "$TRAEFIK_STATUS" != "running" ]; then
    echo -e "\n${RED}Cannot continue: one or more containers are not running.${NC}"
    exit 1
fi

# ─── 3. Port 9000 on host ─────────────────────────────────────────────────────
section "Port 9000 (host)"

if [ "$IS_DOCKER_DESKTOP" = true ]; then
    # On Docker Desktop, network_mode: host binds to the Docker VM, not the user's machine.
    # ss/netstat here would check the user's machine — skip and verify from inside a container instead.
    PORT_OPEN=$(docker run --rm --network host alpine sh -c \
        "nc -z localhost 9000 && echo open || echo closed" 2>/dev/null || echo "error")
    if [ "$PORT_OPEN" = "open" ]; then
        ok "Port 9000 is open inside Docker Desktop VM (step-ca is listening)"
    else
        fail "Port 9000 is not open inside Docker Desktop VM" \
            "step-ca should be listening on this port (network_mode: host)" \
            "Check step-ca logs: make logs-ca"
    fi
else
    if command -v ss &>/dev/null; then
        PORT_INFO=$(ss -tlnp 2>/dev/null | grep ':9000 ' || true)
    elif command -v netstat &>/dev/null; then
        PORT_INFO=$(netstat -tlnp 2>/dev/null | grep ':9000 ' || true)
    else
        PORT_INFO=""
    fi

    if [ -z "$PORT_INFO" ]; then
        fail "Nothing is listening on host port 9000" \
            "step-ca should be listening on this port (network_mode: host)" \
            "Check step-ca logs: make logs-ca"
    elif echo "$PORT_INFO" | grep -q "step"; then
        ok "Port 9000 is used by step-ca"
    else
        ok "Port 9000 is in use ($(echo "$PORT_INFO" | head -1 | awk '{print $NF}'))"
    fi
fi

# ─── 4. host.docker.internal resolution from Traefik ─────────────────────────
section "Network (from traefik container)"

# 4a. Resolve host.docker.internal
HDI_IP=$(docker exec traefik getent hosts host.docker.internal 2>/dev/null | awk '{print $1}' || true)

if [ -n "$HDI_IP" ]; then
    ok "host.docker.internal resolves to $HDI_IP"
else
    if [ "$IS_DOCKER_DESKTOP" = true ]; then
        fail "host.docker.internal does not resolve inside traefik container" \
            "On Docker Desktop this should resolve natively — try restarting Docker Desktop" \
            "Check Docker Desktop settings: Resources > Network > 'Enable host networking'"
    else
        fail "host.docker.internal does not resolve inside traefik container" \
            "This requires Docker Engine >= 20.10 with host-gateway support" \
            "On older Docker, extra_hosts host-gateway is not supported" \
            "Workaround: replace 'host-gateway' with the actual host IP in docker-compose.yml extra_hosts"
    fi
    SKIPPED=$((SKIPPED + 2))  # skip next network checks
    HDI_IP=""
fi

# 4b. TCP connectivity to step-ca:9000
if [ -n "$HDI_IP" ]; then
    # Use wget --spider with a short timeout; step-ca uses HTTPS so we expect TLS
    if docker exec traefik wget -q --spider --timeout=5 --no-check-certificate \
        "https://host.docker.internal:9000/health" &>/dev/null; then
        ok "TCP+TLS connection to host.docker.internal:9000 succeeded"
    else
        # Try raw TCP via /dev/tcp as fallback
        if docker exec traefik sh -c "echo '' | timeout 3 nc -z host.docker.internal 9000" &>/dev/null 2>&1; then
            ok "TCP connection to host.docker.internal:9000 succeeded (TLS layer not verified)"
        else
            if [ "$IS_DOCKER_DESKTOP" = true ]; then
                fail "Cannot reach host.docker.internal:9000 from traefik container" \
                    "step-ca runs with network_mode: host inside Docker Desktop VM" \
                    "On Docker Desktop, host.docker.internal points to the VM, not the host machine" \
                    "Try: restart Docker Desktop, or check Docker Desktop settings (Resources > Network)" \
                    "Verify step-ca is healthy: make logs-ca"
            else
                fail "Cannot reach host.docker.internal:9000 from traefik container" \
                    "step-ca is running on the host but traefik cannot reach it" \
                    "Possible cause: firewall blocking container-to-host traffic" \
                    "On Linux with ufw: sudo ufw allow from 172.16.0.0/12 to any port 9000 proto tcp" \
                    "On Linux with iptables: sudo iptables -I INPUT -p tcp --dport 9000 -s 172.16.0.0/12 -j ACCEPT"
            fi
        fi
    fi
fi

# ─── 5. Root CA certificate ───────────────────────────────────────────────────
section "Root CA certificate"

# 5a. Readable inside traefik container
if docker exec traefik test -r /step-ca-certs/certs/root_ca.crt &>/dev/null; then
    ok "Root CA certificate readable at /step-ca-certs/certs/root_ca.crt"
else
    fail "Root CA certificate not readable at /step-ca-certs/certs/root_ca.crt" \
        "The step-ca-data volume may not contain the cert yet (step-ca first run?)" \
        "Check LEGO_CA_CERTIFICATES env var in traefik container" \
        "Try: docker exec traefik ls -la /step-ca-certs/certs/"
fi

# 5b. LEGO_CA_CERTIFICATES env var set correctly
LEGO_ENV=$(docker exec traefik sh -c 'echo $LEGO_CA_CERTIFICATES' 2>/dev/null || true)
if [ "$LEGO_ENV" = "/step-ca-certs/certs/root_ca.crt" ]; then
    ok "LEGO_CA_CERTIFICATES is set correctly ($LEGO_ENV)"
else
    fail "LEGO_CA_CERTIFICATES is not set or incorrect (got: '${LEGO_ENV:-<empty>}')" \
        "Expected: /step-ca-certs/certs/root_ca.crt" \
        "Check the environment section of the traefik service in docker-compose.yml"
fi

# ─── 6. ACME directory ────────────────────────────────────────────────────────
section "ACME endpoint"

if [ -n "$HDI_IP" ]; then
    ACME_RESPONSE=$(docker exec traefik wget -q -O- --timeout=5 --no-check-certificate \
        "https://host.docker.internal:9000/acme/acme/directory" 2>/dev/null || true)

    if echo "$ACME_RESPONSE" | grep -q '"newNonce"'; then
        ok "ACME directory endpoint is reachable and returns valid JSON"
    elif [ -n "$ACME_RESPONSE" ]; then
        warn "ACME directory returned unexpected response: $(echo "$ACME_RESPONSE" | head -c 120)"
    else
        fail "ACME directory endpoint did not respond" \
            "URL: https://host.docker.internal:9000/acme/acme/directory" \
            "Check that step-ca was initialized with ACME support (DOCKER_STEPCA_INIT_ACME=true)" \
            "Check step-ca logs: make logs-ca"
    fi
else
    skip "ACME directory check skipped (host.docker.internal not resolvable)"
fi

# ─── 7. TLS challenge: step-ca → Traefik (ACME validation) ───────────────────
section "TLS challenge (step-ca → Traefik)"

# 7a. DNS resolution of *.localhost from step-ca
# step-ca needs to resolve *.localhost to reach Traefik for TLS-ALPN-01 validation
TEST_DOMAIN="test-diagnose.localhost"

STEPCA_RESOLVE=$(docker exec step-ca getent hosts "$TEST_DOMAIN" 2>/dev/null | awk '{print $1}' || true)

if [ -n "$STEPCA_RESOLVE" ]; then
    ok "$TEST_DOMAIN resolves to $STEPCA_RESOLVE from step-ca"
else
    # Try with nslookup/dig as fallback
    STEPCA_RESOLVE=$(docker exec step-ca sh -c "nslookup $TEST_DOMAIN 2>/dev/null | grep -A1 'Name:' | grep 'Address:' | awk '{print \$2}'" 2>/dev/null || true)
    if [ -n "$STEPCA_RESOLVE" ]; then
        ok "$TEST_DOMAIN resolves to $STEPCA_RESOLVE from step-ca (via nslookup)"
    else
        fail "*.localhost does not resolve from step-ca container" \
            "step-ca must resolve *.localhost to validate TLS-ALPN-01 challenges." \
            "This is likely why certificates work for cached domains but fail for new ones." \
            "" \
            "Cause: step-ca uses network_mode: host, and the host DNS does not resolve *.localhost." \
            "On Docker Desktop, the internal VM may lack *.localhost DNS resolution." \
            "" \
            "Fix options:" \
            "  1. Add to the host's /etc/hosts (or Docker Desktop VM):" \
            "       127.0.0.1  my-app.localhost other-app.localhost" \
            "  2. On Linux, ensure systemd-resolved handles .localhost:" \
            "       resolvectl query test.localhost" \
            "  3. Switch from tlsChallenge to httpChallenge in traefik.yml" \
            "       (same DNS requirement, but easier to debug)"
    fi
fi

# 7b. TCP connectivity from step-ca to Traefik on port 443 (TLS challenge callback)
if docker exec step-ca sh -c "echo '' | timeout 3 nc -z localhost 443" &>/dev/null 2>&1; then
    ok "step-ca can reach localhost:443 (Traefik entrypoint for TLS challenge)"
else
    # step-ca is on host network, try via wget
    if docker exec step-ca wget -q --spider --timeout=3 --no-check-certificate \
        "https://localhost:443" &>/dev/null 2>&1; then
        ok "step-ca can reach localhost:443 (Traefik entrypoint for TLS challenge)"
    else
        fail "step-ca cannot reach localhost:443" \
            "For TLS-ALPN-01, step-ca must connect to *.localhost:443 to validate the challenge." \
            "Traefik should be listening on port 443 (mapped from the container)." \
            "Check: docker compose ps traefik — port 443 should be mapped" \
            "On Docker Desktop with host networking, Traefik's port 443 should be accessible from the VM."
    fi
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}────────────────────────────────────────${NC}"
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}All checks passed.${NC} No connectivity issues detected."
    echo -e "If Traefik still fails to get certificates, check: ${YELLOW}make logs${NC}"
else
    echo -e "${RED}$FAILED check(s) failed.${NC} Follow the suggestions above to fix the issue."
fi
[ "$SKIPPED" -gt 0 ] && echo -e "${BLUE}$SKIPPED check(s) skipped.${NC}"
echo ""

exit $((FAILED > 0 ? 1 : 0))
