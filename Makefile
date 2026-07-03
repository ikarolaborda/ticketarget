COMPOSE := docker compose
SHELL := /bin/bash

.DEFAULT_GOAL := help

.PHONY: help
help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: init
init: ## Copy .env and generate app keys
	@test -f .env || cp .env.example .env
	@$(MAKE) keys

.PHONY: build
build: ## Build all images
	$(COMPOSE) build

.PHONY: up
up: ## Build and start the full stack
	$(COMPOSE) up -d --build

.PHONY: down
down: ## Stop the stack
	$(COMPOSE) down

.PHONY: restart
restart: ## Restart every service (also makes Traefik re-scan container labels)
	$(COMPOSE) restart

.PHONY: recreate
recreate: ## Re-apply compose changes and recreate all containers
	$(COMPOSE) up -d --force-recreate

.PHONY: reload-gateway
reload-gateway: ## Recreate just Traefik so it rediscovers routers
	$(COMPOSE) up -d --force-recreate traefik

.PHONY: destroy
destroy: ## Stop the stack and remove volumes
	$(COMPOSE) down -v

.PHONY: ps
ps: ## Show running services
	$(COMPOSE) ps

.PHONY: logs
logs: ## Tail logs (use SVC=event-service to scope)
	$(COMPOSE) logs -f $(SVC)

.PHONY: keys
keys: ## Generate Laravel app keys for each service
	@$(COMPOSE) run --rm event-service php artisan key:generate --show 2>/dev/null || true
	@$(COMPOSE) run --rm booking-service php artisan key:generate --show 2>/dev/null || true

# Schema/admin commands target the primary for reads too — migrations are writes
# and must not depend on the (possibly lagging or still-bootstrapping) replica.
.PHONY: seed
seed: ## Run migrations and seeders
	$(COMPOSE) exec -e DB_READ_HOST=postgres-primary event-service php artisan migrate --seed
	$(COMPOSE) exec -e DB_READ_HOST=postgres-primary booking-service php artisan migrate

.PHONY: admin-token
admin-token: ## Mint an events:write admin API token
	$(COMPOSE) exec -e DB_READ_HOST=postgres-primary event-service php artisan admin:token

.PHONY: replay-dlq
replay-dlq: ## Replay dead-lettered CDC events through the projection pipeline
	$(COMPOSE) exec worker php bin/console ticketarget:cdc:replay-dlq

.PHONY: admin-promote
admin-promote: ## Grant the admin flag to an account: make admin-promote EMAIL=user@example.com
	$(COMPOSE) exec -e DB_READ_HOST=postgres-primary users-service php artisan admin:promote $(EMAIL)

.PHONY: fix-replication
fix-replication: ## Ensure the replicator role + pg_hba rules exist on the running primary
	$(COMPOSE) exec -T postgres-primary bash /docker-entrypoint-initdb.d/10-replication.sh

.PHONY: register-cdc
register-cdc: ## Register the Debezium Postgres connector
	@curl -sS -X POST -H "Content-Type: application/json" \
		--data @infra/debezium/register-postgres-connector.json \
		$${DEBEZIUM_CONNECT_URL:-http://localhost:8083}/connectors | jq . || \
		echo "Connect not ready yet — retry once the stack is up."

.PHONY: es-bootstrap
es-bootstrap: ## Create the Elasticsearch events + app-logs indices
	@cat infra/elasticsearch/events-index.json | $(COMPOSE) exec -T elasticsearch \
		curl -sS -X PUT "http://localhost:9200/events" -H 'Content-Type: application/json' --data @- || true
	@echo
	@cat infra/elasticsearch/app-logs-index.json | $(COMPOSE) exec -T elasticsearch \
		curl -sS -X PUT "http://localhost:9200/app-logs" -H 'Content-Type: application/json' --data @- || true
	@echo

.PHONY: frontend-build
frontend-build: ## Rebuild the Vue SPA assets and recreate the frontend container
	$(COMPOSE) build frontend
	$(COMPOSE) up -d --force-recreate frontend

.PHONY: reindex
reindex: ## Wipe and rebuild the Elasticsearch events index from current Postgres data
	-docker compose exec -T elasticsearch curl -s -X DELETE http://localhost:9200/events >/dev/null
	@$(MAKE) es-bootstrap
	-curl -s -X DELETE $${DEBEZIUM_CONNECT_URL:-http://localhost:8083}/connectors/ticketarget-postgres-connector >/dev/null
	@sleep 3
	@$(MAKE) register-cdc

.PHONY: lint
lint: ## Run static analysis + style checks across PHP services
	$(COMPOSE) run --rm event-service composer lint
	$(COMPOSE) run --rm booking-service composer lint
	$(COMPOSE) run --rm search-service composer lint
	$(COMPOSE) run --rm worker composer lint

.PHONY: test
test: ## Run test suites
	$(COMPOSE) run --rm event-service composer test
	$(COMPOSE) run --rm booking-service composer test
	$(COMPOSE) run --rm users-service composer test
	$(COMPOSE) run --rm search-service composer test
	$(COMPOSE) run --rm worker composer test

.PHONY: test-concurrency
test-concurrency: ## Opt-in: parallel same-seat reserve race against the RUNNING stack (holds one seat ~10min)
	bash scripts/concurrency-smoke.sh
