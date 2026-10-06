INFRA    := services/sentinel-x-g4/infra
FIRMWARE := services/software
.PHONY: help init backend-api-key pull update push status certs pki users up down logs ps sim \
        db db-sql db-backup db-reset flash monitor

help:            ## Liste des commandes
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | expand -t 18

# --- Dépôts ----------------------------------------------------------------------

init:            ## Sous-modules (sur leur branche) + .env partagé avec l'infra
	git submodule update --init --recursive
	@git submodule foreach -q 'git checkout -q $$(git config -f $$toplevel/.gitmodules submodule.$$name.branch)'
	@test -f .env || cp .env.example .env
	@ln -sfn ../../../.env $(INFRA)/.env
	@$(MAKE) --no-print-directory backend-api-key

backend-api-key: ## Génère BACKEND_API_KEY dans .env si elle est vide ou vaut change-me
	@v=$$(sed -n 's/^BACKEND_API_KEY=//p' .env); 	if [ -z "$$v" ] || [ "$$v" = change-me ]; then 	  k=$$(openssl rand -hex 32) && 	  { grep -v '^BACKEND_API_KEY=' .env; echo "BACKEND_API_KEY=$$k"; } > .env.tmp && mv .env.tmp .env && 	  echo "OK : BACKEND_API_KEY générée dans .env"; 	fi

pull:            ## Pull du parent puis de chaque sous-module sur sa branche (fast-forward)
	git pull --ff-only
	git submodule update --init --recursive
	git submodule foreach 'b=$$(git config -f $$toplevel/.gitmodules submodule.$$name.branch); git checkout -q $$b && git pull --ff-only origin $$b'

update:          ## Met chaque sous-module à jour sur sa branche suivie
	git submodule update --remote --merge

push:            ## Push des sous-modules (branche courante) puis du parent
	git submodule foreach 'git push origin HEAD'
	git push

status:          ## Commit et branche de chaque sous-module
	git submodule status
	git submodule foreach 'git status -sb | head -1'

# --- Certificats et comptes -------------------------------------------------------

certs:           ## PKI de Baptiste si secrets/ est présent, sinon certificats de DEV manquants
	@if [ -f secrets/ca.key ]; then $(MAKE) --no-print-directory pki; else \
	  test -f $(INFRA)/mosquitto/certs/mosquitto.crt || bash $(INFRA)/scripts/gen-dev-certs.sh; \
	  test -f $(INFRA)/nginx/certs/proxy.crt || ( cd $(INFRA)/nginx/certs && \
	    openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
	      -subj "/CN=dashboard.sentinel.lan" -addext "subjectAltName=DNS:dashboard.sentinel.lan,DNS:localhost" \
	      -keyout proxy.key -out proxy.crt && \
	    openssl dhparam -dsaparam -out dhparam.pem 2048 && echo "OK : certificats DEV du proxy générés" ); fi

pki:             ## Installe la PKI de Baptiste (secrets/) et signe les certificats serveur
	bash infra/install-pki.sh

users:           ## Comptes MQTT hashés depuis .env
	@# variables exportées ici : `source <(...)` du script ne lit rien avec le bash 3.2 de macOS
	set -a && . ./.env && set +a && bash $(INFRA)/scripts/mqtt-users.sh

# --- Pile -------------------------------------------------------------------------

up:              ## Construit et démarre la pile
	docker compose up --build -d

down:            ## Arrête la pile (les données sont conservées)
	docker compose down

logs:            ## Logs de tous les conteneurs
	docker compose logs -f

ps:              ## État des conteneurs
	docker compose ps

sim:             ## Injecte des données simulées
	docker compose --profile sim run --rm simulator

# --- Base de données (sentinel-db) ------------------------------------------------

db:              ## Shell psql dans la base
	docker compose exec sentinel-db sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

db-sql:          ## Exécute un fichier SQL sur la base : make db-sql F=chemin.sql
	@test -n "$(F)" || { echo "Usage : make db-sql F=chemin.sql"; exit 1; }
	docker compose exec -T sentinel-db sh -c 'psql -v ON_ERROR_STOP=1 -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"' < $(F)

db-backup:       ## Sauvegarde dans backups/ (format pg_dump custom)
	@mkdir -p backups
	docker compose exec -T sentinel-db sh -c 'pg_dump -Fc -U "$$POSTGRES_USER" "$$POSTGRES_DB"' > backups/sentinel-$$(date +%Y%m%d-%H%M%S).dump
	@ls -t backups | head -1

db-reset:        ## Efface la base et la recrée depuis postgres/init (DESTRUCTIF)
	@read -p "Effacer toutes les données de sentinel-db ? [o/N] " a && [ "$$a" = o ]
	docker compose rm -sf sentinel-db
	docker volume rm sentinel-x_pg-data
	docker compose up -d

# --- Firmware ESP8266 (services/software, PlatformIO) ---------------------------------

flash:           ## Compile et flashe l'ESP branché en USB
	cd $(FIRMWARE) && pio run -t upload

monitor:         ## Moniteur série de l'ESP (115200 bauds)
	cd $(FIRMWARE) && pio device monitor
