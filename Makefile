include Makefile.proxy
include Makefile.infra

# Colors for output
GREEN := \033[0;32m
YELLOW := \033[1;33m
RED := \033[0;31m
NC := \033[0m # No Color

# Detect OS
UNAME_S := $(shell uname -s 2>/dev/null || echo "Windows")
ifeq ($(OS),Windows_NT)
	DETECTED_OS := Windows
else ifeq ($(UNAME_S),Darwin)
	DETECTED_OS := macOS
else ifeq ($(UNAME_S),Linux)
	DETECTED_OS := Linux
else
	DETECTED_OS := Unknown
endif

.PHONY: start

start: infra-up proxy-start ## Start everything: infrastructure then reverse proxy

# Default target
.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "$(GREEN)Traefik Reverse Proxy with step-ca ACME - Makefile Commands$(NC)"
	@echo ""
	@echo "$(YELLOW)Usage:$(NC) make [target]"
	@echo ""
	@echo "$(YELLOW)[Global]$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-15s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(YELLOW)[Reverse Proxy]$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile.proxy | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-15s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(YELLOW)[Infrastructure]$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile.infra | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-15s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(YELLOW)Detected OS:$(NC) $(DETECTED_OS)"
