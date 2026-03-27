#!/bin/bash
# Install step-ca root certificate in browser trust stores

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

CERT_PATH="./certs/root_ca.crt"
CERT_NAME="Local Dev CA Root CA"

# Extract certificate from step-ca if not present
extract_cert() {
    if [ ! -f "$CERT_PATH" ]; then
        echo -e "${YELLOW}Extracting root CA certificate from step-ca...${NC}"
        mkdir -p certs
        docker cp step-ca:/home/step/certs/root_ca.crt "$CERT_PATH" 2>/dev/null || {
            echo -e "${RED}Error: Cannot extract CA certificate. Is step-ca running?${NC}"
            exit 1
        }
    fi
    echo -e "${GREEN}✓ Certificate available: $CERT_PATH${NC}"
}

# Install in Chrome/Chromium NSS database (Linux)
install_chrome_linux() {
    if ! command -v certutil &>/dev/null; then
        echo -e "${YELLOW}certutil not found. Install with: sudo apt-get install libnss3-tools${NC}"
        return 1
    fi

    local nssdb="$HOME/.pki/nssdb"
    if [ ! -d "$nssdb" ]; then
        echo -e "${YELLOW}Creating Chrome NSS database...${NC}"
        mkdir -p "$nssdb"
        certutil -d sql:"$nssdb" -N --empty-password
    fi

    # Remove existing cert if present, then add
    certutil -d sql:"$nssdb" -D -n "$CERT_NAME" 2>/dev/null || true
    certutil -d sql:"$nssdb" -A -t "C,," -n "$CERT_NAME" -i "$CERT_PATH"
    echo -e "${GREEN}✓ Installed in Chrome/Chromium${NC}"
}

# Install in Firefox profiles (Linux)
install_firefox_linux() {
    if ! command -v certutil &>/dev/null; then
        echo -e "${YELLOW}certutil not found. Install with: sudo apt-get install libnss3-tools${NC}"
        return 1
    fi

    local found=0

    # Standard Firefox and Snap Firefox locations
    for firefox_dir in "$HOME/.mozilla/firefox" "$HOME/snap/firefox/common/.mozilla/firefox"; do
        for profile_dir in "$firefox_dir"/*.default*; do
            if [ -d "$profile_dir" ]; then
                certutil -d sql:"$profile_dir" -D -n "$CERT_NAME" 2>/dev/null || true
                certutil -d sql:"$profile_dir" -A -t "C,," -n "$CERT_NAME" -i "$CERT_PATH"
                echo -e "${GREEN}✓ Installed in Firefox: $(basename "$profile_dir")${NC}"
                found=1
            fi
        done
    done

    if [ $found -eq 0 ]; then
        echo -e "${YELLOW}No Firefox profiles found${NC}"
    fi
}

# Install in macOS system keychain (Chrome/Safari)
install_macos_system() {
    echo -e "${YELLOW}Installing in macOS System Keychain (requires sudo)...${NC}"
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CERT_PATH" || {
        echo -e "${RED}Error: Failed to install certificate in macOS Keychain.${NC}"
        echo -e "${YELLOW}You can install it manually: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CERT_PATH${NC}"
        return 1
    }
    echo -e "${GREEN}✓ Installed in macOS System Keychain (Chrome/Safari)${NC}"
}

# Install in Firefox profiles (macOS)
install_firefox_macos() {
    if ! command -v certutil &>/dev/null; then
        echo -e "${YELLOW}certutil not found. Install with: brew install nss${NC}"
        return 1
    fi

    local found=0
    for profile_dir in "$HOME/Library/Application Support/Firefox/Profiles"/*.default*; do
        if [ -d "$profile_dir" ]; then
            certutil -d sql:"$profile_dir" -D -n "$CERT_NAME" 2>/dev/null || true
            certutil -d sql:"$profile_dir" -A -t "C,," -n "$CERT_NAME" -i "$CERT_PATH"
            echo -e "${GREEN}✓ Installed in Firefox: $(basename "$profile_dir")${NC}"
            found=1
        fi
    done

    if [ $found -eq 0 ]; then
        echo -e "${YELLOW}No Firefox profiles found${NC}"
    fi
}

# Show system-wide instructions for Linux
show_linux_system_instructions() {
    echo ""
    echo -e "${YELLOW}For system-wide installation (curl, wget, etc.):${NC}"
    echo "  sudo cp $CERT_PATH /usr/local/share/ca-certificates/step-ca-dev.crt"
    echo "  sudo update-ca-certificates"
}

# Show Windows instructions
show_windows_instructions() {
    echo -e "${YELLOW}Windows - Manual installation required:${NC}"
    echo ""
    echo -e "${GREEN}PowerShell (Run as Administrator):${NC}"
    echo "  Import-Certificate -FilePath \".\\certs\\root_ca.crt\" -CertStoreLocation Cert:\\LocalMachine\\Root"
    echo ""
    echo -e "${GREEN}Firefox:${NC}"
    echo "  Settings → Privacy & Security → Certificates → View Certificates → Import"
}

# Main
main() {
    extract_cert

    case "$(uname -s)" in
        Linux)
            echo -e "${GREEN}Installing on Linux...${NC}"
            install_chrome_linux
            install_firefox_linux
            show_linux_system_instructions
            ;;
        Darwin)
            echo -e "${GREEN}Installing on macOS...${NC}"
            install_macos_system
            install_firefox_macos
            ;;
        MINGW*|MSYS*|CYGWIN*)
            show_windows_instructions
            ;;
        *)
            echo -e "${RED}Unsupported OS: $(uname -s)${NC}"
            echo -e "${YELLOW}Please install $CERT_PATH manually${NC}"
            exit 1
            ;;
    esac

    echo ""
    echo -e "${GREEN}Done! Restart your browser for changes to take effect.${NC}"
}

main "$@"
