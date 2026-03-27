#!/bin/bash
# Generate Traefik Docker Compose labels interactively

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# 1. Service name (required, non-empty)
while true; do
    read -p "Service name: " service_name
    if [ -n "$service_name" ]; then
        break
    fi
    echo -e "${RED}Error: Service name is required${NC}"
done

# 2. Domain (required, must end with .localhost)
while true; do
    read -p "Domain (e.g., my-app.localhost): " domain
    if [ -z "$domain" ]; then
        echo -e "${RED}Error: Domain is required${NC}"
        continue
    fi
    if [[ "$domain" != *.localhost ]]; then
        echo -e "${RED}Error: Domain must end with .localhost${NC}"
        continue
    fi
    break
done

# 3. Port (optional, default 80, must be a positive integer)
while true; do
    read -p "Port [80]: " port
    port=${port:-80}
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 0 ] && [ "$port" -le 65535 ]; then
        break
    fi
    echo -e "${RED}Error: Port must be a number between 1 and 65535${NC}"
done

# Output YAML
echo ""
echo -e "${GREEN}Generated Docker Compose snippet:${NC}"
echo ""
cat <<EOF
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik_network"
      - "traefik.http.routers.${service_name}.rule=Host(\`${domain}\`)"
      - "traefik.http.routers.${service_name}.entrypoints=websecure"
      - "traefik.http.routers.${service_name}.tls.certresolver=stepca"
      - "traefik.http.services.${service_name}.loadbalancer.server.port=${port}"
    networks:
      - traefik_network
EOF
echo ""
echo -e "${YELLOW}Don't forget to add the external network at the top level of your compose file:${NC}"
echo ""
cat <<'EOF'
networks:
  traefik_network:
    external: true
EOF
