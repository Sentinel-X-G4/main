# Sentinel-X — dépôt principal

Dépôt parent de l'organisation [Sentinel-X-G4](https://github.com/Sentinel-X-G4). Il
regroupe les autres dépôts en sous-modules Git et assemble la pile complète avec un seul
Docker Compose.

## Structure

```
main/
├── docker-compose.yml           # SEUL compose du projet : tous les conteneurs
├── infra/
│   └── install-pki.sh           # PKI de Baptiste (secrets/) → certificats MQTT et proxy
├── .env.example                 # configuration unique (copier en .env, jamais commité)
├── secrets/                     # PKI de Baptiste : ca.crt/key, clés… (jamais commité)
├── Makefile                     # `make help` : dépôts, certificats, pile, base, firmware
└── services/                    # sous-modules
    ├── infrastructure/          # config durcie : Nginx, Mosquitto (MQTTS, ACL), scripts, certs
    ├── backend-api/             # API REST + WebSocket des alertes (Node.js)
    ├── backend-iot-alerts/      # service de détection (MQTT → modèle → résultats)
    ├── human-detection-ia/      # IA vision (détection de personnes)
    ├── software/                # firmware ESP8266 (PlatformIO, branche master)
    ├── frontend-dashboard/      # dashboard web (vide pour l'instant)
    └── backend_db/              # base de données unique : Dockerfile + schéma (db/init/)
```

Un seul `docker-compose.yml`, ici. Les dépôts enfants ne contiennent que leur `Dockerfile`
(construit par ce compose) ou de la configuration (montée par ce compose, ex. `infrastructure`).

| Conteneur | Exposé | Rôle |
|---|---|---|
| `sentinel-reverse-proxy` | `443`, `80` (→ 443) | Seul point d'entrée HTTP(S) : `/api/` → backend |
| `sentinel-mosquitto` | `8883` (MQTTS) | Broker, TLS + comptes + ACL |
| `g4-db` (service `db`) | non (réseau `internal`) | Base unique (`backend_db`) : PostgreSQL 16 + TimescaleDB |
| `sentinel-backend` | via le proxy | API REST + WebSocket, lit la base (pas de MQTT) |
| `sentinel-detection` | `127.0.0.1:8000` (debug) | Détection temps réel |
| `sentinel-human-detection` | `127.0.0.1:8089` (flux annoté) | IA vision : YOLO sur la webcam USB → MQTT `camera` |
| `simulator` (profil `sim`) | — | Faux ESP + caméra |

Les ports sont publiés sur `BIND_IP` uniquement (`192.168.40.1` sur le serveur).

## Flux MQTT

Le broker (TLS, un compte par rôle) n'a qu'un seul abonné côté serveur : le service de
détection (`backend-iot-alerts`). backend-api ne se connecte pas à MQTT.

| Topic | De → vers | Compte |
|---|---|---|
| `sentinelx/{device_id}/telemetry` | ESP → détection | `sentinel_iot` |
| `sentinelx/{device_id}/camera` | IA vision → détection | `vision` |
| `sentinelx/{device_id}/detection` | détection → (publié, informatif) | `detection` |
| `sentinelx/{device_id}/alert` | ESP → détection | `sentinel_iot` |
| `sentinelx/{device_id}/cmd` / `ack` | (réservé, non utilisé) ↔ ESP | `iot-backend` / `sentinel_iot` |

Droits : `services/infrastructure/infra/mosquitto/config/acl`. Formats des messages :
`services/backend-iot-alerts/detection-service/docs/MQTT_CONTRACT.md`.

## Base de données

Une seule base (dépôt `backend_db`, service `db`), un seul endroit pour son schéma :
`services/backend_db/db/init/` (tables communes + schéma `detection` + triggers NOTIFY). Aucun
service ne crée de table.

- Le service de détection écrit les mesures, les prédictions (`detection.predictions` = état de
  chaque appareil) et les alertes (`public.alerts`, à l'activation d'une alerte ou sur
  `sentinelx/+/alert`).
- backend-api lit ces tables, acquitte les alertes, et écoute les `NOTIFY` posés par des triggers
  (`sentinel_alerts`, `sentinel_devices`) pour pousser le temps réel au dashboard en WebSocket. Les scripts ne s'exécutent qu'à la création du volume : en dev,
`docker compose down -v` pour repartir d'une base neuve.

## Démarrage

```bash
git clone --recurse-submodules https://github.com/Sentinel-X-G4/main.git
cd main
make init        # sous-modules + .env (relié à l'infra) → remplir les mots de passe
make certs       # PKI de Baptiste si secrets/ est rempli (make pki), sinon certificats de DEV
make users       # comptes MQTT hashés depuis .env
make up
make sim         # données simulées (MQTT_SIMULATOR_PASSWORD requis dans .env)
```

La webcam USB est lue sur l'hôte macOS (Docker n'a pas accès à l'USB) : lancer
`make setup && make capture` dans `services/human-detection-ia`. Le conteneur
`human-detection` consomme ce flux et publie la présence sur
`sentinelx/${CAMERA_DEVICE_ID}/camera` (même `device_id` que l'ESP de la pièce).

- API : `https://localhost/api/health`, `/api/v1/alerts`, `/api/v1/devices`
- Détection (debug) : `http://localhost:${DETECTION_API_PORT}/health`

## Base de données au quotidien

```bash
make db                      # shell psql
make db-sql F=migration.sql  # appliquer un script (ex. ALTER sur une base existante)
make db-backup               # sauvegarde dans backups/ (non commité)
make db-reset                # efface tout et rejoue backend_db/db/init (confirmation demandée)
```

## Firmware (ESP8266)

`services/software` est un projet PlatformIO (`pio` requis). ESP branché en USB :
`make flash` puis `make monitor`. L'ESP doit embarquer `secrets/ca.crt` (CA de Baptiste) et
se connecter en MQTTS à `192.168.40.1:8883` avec le compte `sentinel_iot`.

## Travailler avec les sous-modules

Chaque dossier de `services/` est un dépôt Git à part entière : on y commit et on y
pousse normalement. Le parent enregistre le commit utilisé de chaque sous-module.

```bash
make pull      # parent + chaque sous-module sur sa branche suivie (fast-forward)
make status    # branche et commit de chaque sous-module
make push      # push de chaque sous-module puis du parent
make update    # derniers commits de chaque sous-module, puis :
git add services && git commit -m "chore: bump submodules"
```

> Après un `git pull` **dans** un sous-module, enregistrer le nouveau commit dans le
> parent (`git add services/<repo>`) avant tout `git submodule update`, sinon ce dernier
> remet le sous-module sur l'ancien commit.

Ajouter un dépôt : `git submodule add -b main https://github.com/Sentinel-X-G4/<repo>.git services/<repo>`.
