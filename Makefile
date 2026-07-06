COMPOSE := docker compose
SHELL := /bin/bash

.DEFAULT_GOAL := help

.PHONY: help
help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: init
init: ## Copy .env and generate app + JWT keys (idempotent)
	@test -f .env || cp .env.example .env
	@$(MAKE) keys
	@$(MAKE) jwt-keys


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
keys: ## Generate Laravel APP_KEYs + TICKET_CODE_SECRET into .env (only if empty/placeholder)
	@set -e; \
	for var in EVENT_APP_KEY BOOKING_APP_KEY USERS_APP_KEY; do \
		cur=$$(grep -E "^$$var=" .env | cut -d= -f2-); \
		if [ -z "$$cur" ]; then \
			key="base64:$$(openssl rand -base64 32)"; \
			if grep -qE "^$$var=" .env; then sed -i.bak "s|^$$var=.*|$$var=$$key|" .env; else echo "$$var=$$key" >> .env; fi; \
			echo "  set $$var"; \
		else echo "  $$var already set"; fi; \
	done; \
	tc=$$(grep -E "^TICKET_CODE_SECRET=" .env | cut -d= -f2-); \
	if [ -z "$$tc" ] || [ "$$tc" = "change-me-ticket-code-secret" ]; then \
		newtc=$$(openssl rand -hex 48); \
		if grep -qE "^TICKET_CODE_SECRET=" .env; then sed -i.bak "s|^TICKET_CODE_SECRET=.*|TICKET_CODE_SECRET=$$newtc|" .env; else echo "TICKET_CODE_SECRET=$$newtc" >> .env; fi; \
		echo "  set TICKET_CODE_SECRET"; \
	else echo "  TICKET_CODE_SECRET already set"; fi; \
	rm -f .env.bak


# Schema/admin commands target the primary for reads too — migrations are writes
# and must not depend on the (possibly lagging or still-bootstrapping) replica.
.PHONY: seed
seed: ## Run all migrations (serial, shared ledger) + event seeders
	$(COMPOSE) exec -e DB_READ_HOST=postgres-primary -T users-service php artisan migrate --force
	$(COMPOSE) exec -e DB_READ_HOST=postgres-primary -T event-service php artisan migrate --seed --force
	$(COMPOSE) exec -e DB_READ_HOST=postgres-primary -T booking-service php artisan migrate --force


.PHONY: jwt-keys
jwt-keys: ## Generate the RS256 signing keypair the Users service uses to issue JWTs
	@mkdir -p infra/keys
	@if [ -d infra/keys/jwt-private.pem ]; then \
		echo "ERROR: infra/keys/jwt-private.pem is a DIRECTORY (the stack was started before the key existed)."; \
		echo "Fix: make down; rm -rf infra/keys/jwt-private.pem; make jwt-keys"; exit 1; fi
	@test -f infra/keys/jwt-private.pem \
		&& echo "infra/keys/jwt-private.pem already exists — refusing to overwrite" \
		|| (openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out infra/keys/jwt-private.pem \
			&& chmod 600 infra/keys/jwt-private.pem \
			&& echo "Wrote infra/keys/jwt-private.pem (kid: set AUTH_JWT_ACTIVE_KID, default k1)")


.PHONY: admin-token
admin-token: ## Mint an admin JWT for an existing admin: make admin-token EMAIL=user@example.com
	$(COMPOSE) exec -e DB_READ_HOST=postgres-primary users-service php artisan auth:issue-token $(EMAIL)

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
register-cdc: ## Register the Debezium Postgres connector (retries until Connect is ready)
	@url="$${DEBEZIUM_CONNECT_URL:-http://localhost:8083}"; \
	for i in $$(seq 1 20); do \
		code=$$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" --data @infra/debezium/register-postgres-connector.json $$url/connectors); \
		if [ "$$code" = "201" ] || [ "$$code" = "409" ]; then echo "CDC connector registered (http $$code)"; exit 0; fi; \
		echo "  Connect not ready (attempt $$i, http $$code); retrying in 5s..."; sleep 5; \
	done; \
	echo "WARNING: CDC connector not registered after retries — search sync may be incomplete. Re-run 'make register-cdc' once debezium-connect is up."


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

.PHONY: first-run
first-run: ## First-time bring-up on a new machine (idempotent, non-destructive)
	@test -f .env || cp .env.example .env
	@$(MAKE) keys
	@$(MAKE) jwt-keys
	@# Fresh volumes: start the primary alone, then apply the (idempotent) replication
	@# setup on the live server BEFORE the read-replica joins — otherwise the replica
	@# crash-loops on pg_basebackup (no pg_hba entry) and compose aborts the bring-up.
	$(COMPOSE) up -d --build postgres-primary
	@$(MAKE) wait-db
	@$(MAKE) fix-replication
	$(COMPOSE) up -d --build
	@$(MAKE) wait-healthy
	@$(MAKE) seed
	@$(MAKE) es-bootstrap
	@$(MAKE) register-cdc
	@$(MAKE) seed-admin
	@$(MAKE) smoke
	@echo ""
	@echo "Stack is up. SPA: http://app.ticketarget.localhost  API: http://api.ticketarget.localhost"
	@echo "Mint an admin JWT any time with: make admin-token EMAIL=$(ADMIN_EMAIL)"

.PHONY: bootstrap
bootstrap: first-run ## Alias for first-run

.PHONY: wait-db
wait-db: ## Block until postgres-primary is healthy (bounded)
	@echo "Waiting for postgres-primary..."
	@elapsed=0; limit=120; \
	until $(COMPOSE) ps postgres-primary --format '{{.Status}}' | grep -q healthy; do \
		if [ $$elapsed -ge $$limit ]; then echo "postgres-primary not healthy after $${limit}s"; $(COMPOSE) ps postgres-primary; exit 1; fi; \
		sleep 3; elapsed=$$((elapsed+3)); \
	done; \
	echo "  postgres-primary healthy"

.PHONY: wait-healthy
wait-healthy: ## Block until the core services report healthy (bounded)
	@echo "Waiting for core services to become healthy..."
	@elapsed=0; limit=240; \
	until [ "$$($(COMPOSE) ps --format '{{.Name}} {{.Status}}' | grep -cE '(postgres-primary|postgres-replica|kafka|elasticsearch|event-service|booking-service|users-service|search-service).*healthy')" -ge 8 ]; do \
		if [ $$elapsed -ge $$limit ]; then echo "Timed out after $${limit}s waiting for health:"; $(COMPOSE) ps; exit 1; fi; \
		sleep 3; elapsed=$$((elapsed+3)); \
	done; \
	echo "  core services healthy (postgres primary+replica, kafka, elasticsearch, event, booking, users, search)"

ADMIN_EMAIL ?= admin@ticketarget.local

.PHONY: seed-admin
seed-admin: ## Seed an admin account (ADMIN_EMAIL/ADMIN_PASSWORD override; generates a password if unset)
	@pw="$${ADMIN_PASSWORD:-$$(openssl rand -base64 12)}"; \
	$(COMPOSE) exec -e DB_READ_HOST=postgres-primary -T users-service php artisan admin:create $(ADMIN_EMAIL) --password="$$pw" --name="Admin"; \
	echo "  Admin email: $(ADMIN_EMAIL)"; \
	echo "  If the account was just created, its password is: $$pw"; \
	echo "  (an already-existing account keeps its current password — set ADMIN_PASSWORD to force one on creation)"

.PHONY: smoke
smoke: ## Quick gateway smoke checks (informational)
	@echo "Smoke checks (http entrypoint):"
	@curl -s -o /dev/null -w '  gateway /events        -> HTTP %{http_code}\n' http://api.ticketarget.localhost/events || true
	@curl -s -o /dev/null -w '  gateway JWKS           -> HTTP %{http_code}\n' http://api.ticketarget.localhost/auth/.well-known/jwks.json || true
	@curl -s -o /dev/null -w '  SPA (app host)         -> HTTP %{http_code}\n' http://app.ticketarget.localhost/ || true
