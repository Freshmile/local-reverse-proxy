.PHONY: help setup start stop restart logs status install-ca clean

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

# Default target
.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "$(GREEN)Traefik Reverse Proxy with step-ca ACME - Makefile Commands$(NC)"
	@echo ""
	@echo "$(YELLOW)Usage:$(NC) make [target]"
	@echo ""
	@echo "$(YELLOW)Available targets:$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-15s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(YELLOW)Detected OS:$(NC) $(DETECTED_OS)"

setup: ## Complete setup (start containers, install CA)
	@echo "$(GREEN)Starting step-ca and Traefik...$(NC)"
	@$(MAKE) -s check-docker
	@docker compose up -d
	@$(MAKE) -s install-ca
	@echo ""
	@echo "$(GREEN)Setup complete!$(NC)"
	@echo "$(YELLOW)Dashboard:$(NC) http://traefik.localhost:8080/dashboard/"

start: ## Start Traefik and step-ca containers
	@echo "$(GREEN)Starting Traefik with step-ca...$(NC)"
	@$(MAKE) -s check-docker
	@docker compose up -d
	@echo "$(GREEN)Services started successfully!$(NC)"
	@echo ""
	@$(MAKE) -s status

stop: ## Stop all containers
	@echo "$(YELLOW)Stopping containers...$(NC)"
	@docker compose down
	@echo "$(GREEN)Containers stopped$(NC)"

restart: ## Restart all containers
	@echo "$(YELLOW)Restarting containers...$(NC)"
	@docker compose restart
	@echo "$(GREEN)Containers restarted$(NC)"

logs: ## Show Traefik logs (follow mode)
	@docker compose logs -f traefik

logs-ca: ## Show step-ca logs (follow mode)
	@docker compose logs -f step-ca

status: ## Show status of containers
	@echo "$(GREEN)Container Status:$(NC)"
	@docker compose ps
	@echo ""
	@if docker compose ps | grep -q "step-ca.*healthy"; then \
		echo "$(GREEN)✓ step-ca is running and healthy$(NC)"; \
	else \
		echo "$(RED)✗ step-ca is not healthy$(NC)"; \
	fi
	@if docker compose ps | grep -q "traefik.*Up"; then \
		echo "$(GREEN)✓ Traefik is running$(NC)"; \
		echo "$(GREEN)✓ Dashboard: http://traefik.localhost:8080/dashboard/$(NC)"; \
	else \
		echo "$(RED)✗ Traefik is not running$(NC)"; \
		echo "$(YELLOW)Run 'make start' to start Traefik$(NC)"; \
	fi
	@if [ -f certs/root_ca.crt ]; then \
		echo "$(GREEN)✓ Root CA certificate available$(NC)"; \
	else \
		echo "$(YELLOW)! Root CA certificate not extracted (run 'make setup')$(NC)"; \
	fi

install-ca: ## Install CA certificate in browser trust stores
	@./scripts/install-ca.sh

clean: ## Remove all containers, volumes, and certificates
	@echo "$(RED)WARNING: This will remove all containers, volumes, and certificates!$(NC)"
	@echo -n "$(YELLOW)Are you sure? [y/N] $(NC)" && read ans && [ $${ans:-N} = y ]
	@echo "$(YELLOW)Stopping containers...$(NC)"
	@docker compose down -v
	@echo "$(YELLOW)Removing certificates...$(NC)"
	@rm -rf certs/*
	@rm -rf traefik/acme/*
	@echo "$(YELLOW)Removing logs...$(NC)"
	@rm -rf traefik/logs/*
	@echo "$(GREEN)Cleanup complete!$(NC)"

check-docker: ## Check if Docker is installed and running
	@command -v docker >/dev/null 2>&1 || { echo "$(RED)Error: Docker is not installed$(NC)"; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "$(RED)Error: Docker daemon is not running$(NC)"; exit 1; }
