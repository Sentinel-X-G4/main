# Sentinel-X — dépôt principal

Dépôt parent de l'organisation [Sentinel-X-G4](https://github.com/Sentinel-X-G4). Il
regroupe les autres dépôts en sous-modules Git et assemble la pile complète avec un seul
Docker Compose.

## Structure

```
main/
├── docker-compose.yml           # pile complète : inclut l'infra + services des sous-modules
├── infra/
│   └── sentinel-x-g4.override.yml   # seul ajout à l'infra : alias TLS mqtt.sentinel.lan
├── .env.example                 # configuration unique (copier en .env, jamais commité)
├── Makefile                     # init, certs, users, up, sim, update…
└── services/                    # sous-modules
    ├── sentinel-x-g4/           # infra durcie (MQTTS, ACL, TimescaleDB, proxy Nginx)
    ├── backend-api/             # API REST + WebSocket des alertes (Node.js)
    ├── backend-iot-alerts/      # service de détection (MQTT → modèle → résultats)
    └── human-detection-ia/      # IA vision (détection de personnes)
```

L'infra n'est **pas copiée** ici : `docker-compose.yml` inclut
`services/sentinel-x-g4/infra/docker-compose.yml`. Toute évolution de l'infra se fait dans
`sentinel-x-g4`.

| Conteneur | Exposé | Rôle |
|---|---|---|
| `sentinel-reverse-proxy` | `443`, `80` (→ 443) | Seul point d'entrée HTTP(S) : `/api/` → backend |
| `sentinel-mosquitto` | `8883` (MQTTS) | Broker, TLS + comptes + ACL |
| `sentinel-db` | non (réseau `internal`) | PostgreSQL/TimescaleDB |
| `sentinel-backend` | via le proxy | API REST + WebSocket, abonnée en MQTT |
| `sentinel-detection` | `127.0.0.1:8000` (debug) | Détection temps réel |
| `simulator` (profil `sim`) | — | Faux ESP + caméra |

Les ports sont publiés sur `BIND_IP` uniquement (`192.168.40.1` sur le serveur).

## Flux MQTT

Tous les échanges entre services passent par le broker, en TLS, avec un compte par rôle.

| Topic | De → vers | Compte |
|---|---|---|
| `sentinelx/{device_id}/telemetry` | ESP → détection | `sentinel_iot` |
| `sentinelx/{device_id}/camera` | IA vision → détection | `vision` |
| `sentinelx/{device_id}/detection` | détection → backend-api | `detection` |
| `sentinelx/{device_id}/alert` | ESP → backend-api | `sentinel_iot` |
| `sentinelx/{device_id}/cmd` / `ack` | backend-api ↔ ESP | `iot-backend` / `sentinel_iot` |

Droits : `services/sentinel-x-g4/infra/mosquitto/config/acl`. Formats des messages :
`services/backend-iot-alerts/detection-service/docs/MQTT_CONTRACT.md`.

## Base de données

Une seule base (`sentinel-db`), un seul endroit pour son schéma :
`services/sentinel-x-g4/infra/postgres/init/` (tables communes + schéma `detection`). Aucun
service ne crée de table. Les scripts ne s'exécutent qu'à la création du volume : en dev,
`docker compose down -v` pour repartir d'une base neuve.

## Démarrage

```bash
git clone --recurse-submodules https://github.com/Sentinel-X-G4/main.git
cd main
make init        # sous-modules + .env (relié à l'infra) → remplir les mots de passe
make certs       # certificats de DEV, seulement si ceux de Baptiste sont absents
make users       # comptes MQTT hashés depuis .env
make up
make sim         # données simulées (MQTT_SIMULATOR_PASSWORD requis dans .env)
```

- API : `https://localhost/api/health`, `/api/v1/alerts`, `/api/v1/devices`
- Détection (debug) : `http://localhost:8000/health`

## Travailler avec les sous-modules

Chaque dossier de `services/` est un dépôt Git à part entière : on y commit et on y
pousse normalement. Le parent enregistre le commit utilisé de chaque sous-module.

```bash
make update                                  # derniers commits de chaque sous-module (main)
git add services && git commit -m "chore: bump submodules"

git pull && git submodule update --init      # après un pull du parent
```

> Après un `git pull` **dans** un sous-module, enregistrer le nouveau commit dans le
> parent (`git add services/<repo>`) avant tout `git submodule update`, sinon ce dernier
> remet le sous-module sur l'ancien commit.

Ajouter un dépôt : `git submodule add -b main https://github.com/Sentinel-X-G4/<repo>.git services/<repo>`
(le dépôt `software`, encore vide, pourra l'être dès son premier commit).
