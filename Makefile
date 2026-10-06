INFRA := services/sentinel-x-g4/infra
.PHONY: init update status certs users up down logs ps sim

init:            ## Sous-modules + .env partagé avec l'infra
	git submodule update --init --recursive
	@test -f .env || cp .env.example .env
	@ln -sfn ../../../.env $(INFRA)/.env

update:          ## Met chaque sous-module à jour sur sa branche suivie
	git submodule update --remote --merge

status:          ## Commit et branche de chaque sous-module
	git submodule status
	git submodule foreach 'git status -sb | head -1'

certs:           ## Certificats de DEV, seulement s'ils manquent (sinon : ceux de Baptiste)
	@test -f $(INFRA)/mosquitto/certs/mosquitto.crt || bash $(INFRA)/scripts/gen-dev-certs.sh
	@test -f $(INFRA)/nginx/certs/proxy.crt || ( cd $(INFRA)/nginx/certs && \
	  openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
	    -subj "/CN=dashboard.sentinel.lan" -addext "subjectAltName=DNS:dashboard.sentinel.lan,DNS:localhost" \
	    -keyout proxy.key -out proxy.crt && \
	  openssl dhparam -dsaparam -out dhparam.pem 2048 && echo "OK : certificats DEV du proxy générés" )

users:           ## Comptes MQTT hashés depuis .env
	@# variables exportées ici : `source <(...)` du script ne lit rien avec le bash 3.2 de macOS
	set -a && . ./.env && set +a && bash $(INFRA)/scripts/mqtt-users.sh

up:              ## Construit et démarre la pile
	docker compose up --build -d

down:
	docker compose down

logs:
	docker compose logs -f

ps:
	docker compose ps

sim:             ## Injecte des données simulées
	docker compose --profile sim run --rm simulator
