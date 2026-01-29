#!/bin/bash
# Generate Traefik Docker Compose labels interactively

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

# 3. Port (optional, default 80)
read -p "Port [80]: " port
port=${port:-80}

# Output YAML
echo ""
echo -e "${GREEN}Generated labels:${NC}"
echo ""
cat <<EOF
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=traefik_network"
  - "traefik.http.routers.${service_name}.rule=Host(\`${domain}\`)"
  - "traefik.http.routers.${service_name}.entrypoints=websecure"
  - "traefik.http.routers.${service_name}.tls.certresolver=stepca"
  - "traefik.http.services.${service_name}.loadbalancer.server.port=${port}"
EOF
