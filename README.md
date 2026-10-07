# Sentinel-X — Dépôt Principal & Guide Complet

Dépôt parent officiel de l'organisation [Sentinel-X-G4](https://github.com/Sentinel-X-G4).
Il regroupe l'ensemble des composants du projet en sous-modules Git et orchestre l'ensemble de la pile applicative, de l'infrastructure et de la sécurité via un unique **Docker Compose**.

---

## Sommaire

1. [Architecture Globale & Flux](#architecture-globale--flux)
2. [Prérequis](#prérequis)
3. [Structure du Projet](#structure-du-projet)
4. [Guide d'Installation Pas-à-Pas](#guide-dinstallation-pas-à-pas)
5. [Configuration & Flash du Firmware ESP8266](#configuration--flash-du-firmware-esp8266)
6. [Guide de Test et Validation (Vérifier que tout fonctionne)](#guide-de-test-et-validation)
7. [Commandes Utiles (Makefile)](#commandes-utiles-makefile)
8. [Résolution des Problèmes Courants (Troubleshooting)](#résolution-des-problèmes-courants-troubleshooting)

---

## Architecture Globale & Flux

```
                        ┌────────────────────────────────────────────────────────┐
                        │                     SENTINEL-X                         │
                        └────────────────────────────────────────────────────────┘
                                                    │
                 [MQTTS : 8883 (TLS)]               │             [HTTPS : 443]
       ┌───────────────────────────────────────┐    │    ┌───────────────────────────────┐
       │                                       │    │    │                               │
       ▼                                       ▼    │    ▼                               ▼
┌─────────────┐                        ┌──────────────┐  │ ┌───────────────┐      ┌─────────────┐
│   ESP8266   │                        │  Mosquitto   │  │ │ Nginx Reverse │ ───► │  Dashboard  │
│  (Capteurs) │                        │ Broker MQTTS │  │ │     Proxy     │      │   (React)   │
└─────────────┘                        └──────────────┘  │ └───────────────┘      └─────────────┘
       │                                       │         │         │
       │                                       │         │         ▼
       │                                       ▼         │ ┌───────────────┐
       │ (JSON Telemetry)            ┌──────────────────┐│ │  Backend API  │ (WebSocket
       └───────────────────────────► │Detection Service ││ │   (Node.js)   │  & REST)
                                     │   (ML & Règles)  ││ └───────────────┘
                                     └──────────────────┘│         │
                                               │         │         │
                                               ▼         │         ▼
                                     ┌─────────────────────────────────────┐
                                     │   PostgreSQL / TimescaleDB (g4-db)  │
                                     └─────────────────────────────────────┘
```

### Rôles des Conteneurs

| Conteneur | Port Hôte (via BIND_IP) | Rôle & Description |
|---|---|---|
| `sentinel-mosquitto` | `8883` (MQTTS) | Broker MQTT sécurisé (TLS v1.2+, comptes dédiés, ACL strictes). |
| `sentinel-reverse-proxy`| `80` (redirection), `443` | Point d'entrée HTTPS unique (Dashboard + API REST/WebSocket). |
| `sentinel-detection` | `127.0.0.1:18000` (debug) | Service Python d'ingestion et d'analyse temps réel des alertes/mesures. |
| `sentinel-backend` | Interne (via proxy) | API REST & serveur WebSocket relayant les alertes vers le dashboard. |
| `sentinel-frontend` | Interne (via proxy) | Dashboard React de supervision. |
| `sentinel-human-detection`| `127.0.0.1:8089` (aperçu) | Détection IA vision par flux caméra USB (modèle YOLO). |
| `g4-db` (service `db`)| Aucun (isolé) | Base de données PostgreSQL 16 + TimescaleDB. |
| `simulator` (profil `sim`)| Aucun | Injection de données de test et simulation de scénarios. |

### Matrice des Droits MQTT (ACL)

| Utilisateur | Topic(s) | Droits | Rôle |
|---|---|---|---|
| `sentinel_iot` | `sentinelx/esp01/telemetry`, `sentinelx/esp01/alert`, `sentinelx/esp01/ack` | Écriture | Envoi des mesures et alertes matérielles de l'ESP |
| `sentinel_iot` | `sentinelx/esp01/cmd` | Lecture | Réception d'ordres (buzzer, reset) |
| `detection` | `sentinelx/+/telemetry`, `sentinelx/+/camera`, `sentinelx/+/alert` | Lecture | Ingestion de toutes les données capteurs |
| `detection` | `sentinelx/+/detection` | Écriture | Publication des détections calculées |
| `vision` | `sentinelx/+/camera` | Écriture | Publication des détections de présence humaine |
| `simulator` | `sentinelx/+/telemetry`, `sentinelx/+/camera` | Écriture | Injection de fausses données (DEV) |

---

## Prérequis

- **Docker** (v24+) & **Docker Compose** (v2.20+)
- **Git** (avec support sous-modules)
- **Make** (présent nativement sur Linux/macOS ; via Git Bash, WSL ou MinGW sous Windows)
- **PlatformIO CLI / VSCode Extension** (pour la compilation et le flash de l'ESP8266)
- **OpenSSL** (utilisé pour la PKI, ou exécuté automatiquement via conteneur Docker si absent)

---

## Structure du Projet

```text
main/
├── docker-compose.yml           # Unique fichier Compose orchestrant la totalité de la stack
├── Makefile                     # Commandes simplifiées multiplateformes
├── .env.example                 # Modèle de variables d'environnement
├── .env                         # Configuration locale active (ignoré par Git)
├── scripts/
│   └── install-pki.sh           # Installation PKI, signature des certificats serveur avec SAN IP
├── secrets/                     # Clés privées et autorité de certification (ca.crt, ca.key, etc.)
└── services/                    # Sous-modules Git
    ├── infrastructure/          # Configurations Nginx, Mosquitto, scripts de gestion des utilisateurs
    ├── backend-api/             # API Node.js / Express / WebSocket
    ├── backend-iot-alerts/      # Moteur d'analyse IA et règles (Python / FastAPI)
    ├── database/                # Scripts d'initialisation PostgreSQL / TimescaleDB
    ├── frontend-dashboard/      # Interface graphique React
    ├── human-detection-ia/      # Détecteur YOLO caméra USB
    └── software/                # Firmware ESP8266 (PlatformIO C++)
```

---

## Guide d'Installation Pas-à-Pas

Suivez ces étapes dans l'ordre. Les commandes sont exécutables sous **Linux**, **macOS** et **Windows** (dans un terminal Bash tel que **Git Bash** ou **WSL**).

### Étape 1 : Cloner le dépôt et ses sous-modules

```bash
git clone --recurse-submodules https://github.com/Sentinel-X-G4/main.git
cd main
```

*(Si vous avez déjà cloné sans les sous-modules : `make init` ou `git submodule update --init --recursive`)*.

---

### Étape 2 : Configurer les variables d'environnement (`.env`)

Copiez le fichier d'exemple si `.env` n'existe pas :
```bash
cp .env.example .env
```

Éditez le fichier `.env` :
1. **`BIND_IP`** : Définissez l'adresse IP sur laquelle les ports réseau (MQTTS 8883 et HTTPS 443) seront exposés :
   - En local pur : `BIND_IP=127.0.0.1` ou `BIND_IP=0.0.0.0`
   - Sur un réseau Wi-Fi / LAN avec l'ESP8266 : mettez l'IP locale de votre machine (ex: `BIND_IP=<VOTRE_IP_LOCALE>`).
   > **Attention :** Ne mettez pas d'espace après le signe `=`, ex: `BIND_IP=192.168.1.50`.
2. **`POSTGRES_PASSWORD`** : Mot de passe de la base de données.
3. **Mots de passe MQTT** :
   - `MQTT_ESP_PASSWORD` (mot de passe pour l'utilisateur `sentinel_iot`)
   - `MQTT_DETECTION_PASSWORD`
   - `MQTT_BACKEND_PASSWORD`
   - `MQTT_VISION_PASSWORD`
   - `MQTT_SIMULATOR_PASSWORD`
4. **Clé API backend** : Générée automatiquement via `make init` ou `make backend-api-key`.

---

### Étape 3 : Installer la PKI et générer les certificats TLS

Les certificats du broker MQTT et du reverse proxy Nginx doivent être signés par l'autorité racine située dans le dossier des secrets (`secrets/ca.crt` et `secrets/ca.key`).
De plus, le certificat du broker doit impérativement inclure votre adresse IP (`${BIND_IP}`) dans ses **Subject Alternative Names (SAN)** pour que la vérification TLS réussisse.

Exécutez :
```bash
make certs
```
*(Équivalent direct sans make : `bash scripts/install-pki.sh`)*

**Ce que fait cette étape :**
- Vérifie la validité de la CA dans le dossier `secrets/`.
- Génère `services/infrastructure/mosquitto/certs/mosquitto.crt` avec le nom de domaine `mqtt.sentinel.lan`, `localhost` et l'adresse IP définie dans la variable `${BIND_IP}` de votre `.env`.
- Génère `services/infrastructure/nginx/certs/proxy.crt` pour le reverse proxy.
- Copie la CA du dossier des secrets vers les dossiers de certificats requis.

---

### Étape 4 : Créer les comptes et mots de passe Mosquitto

Pour que Mosquitto accepte les connexions, il lui faut un fichier `password.txt` contenant les hashs des mots de passe définis dans le `.env` pour chaque rôle :

Exécutez :
```bash
make users
```
*(Équivalent direct sans make : `bash services/infrastructure/scripts/mqtt-users.sh`)*

Le fichier `services/infrastructure/mosquitto/config/password.txt` est alors généré de façon sécurisée via un conteneur Mosquitto éphémère à partir des variables `MQTT_*_PASSWORD`.

---

### Étape 5 : Démarrer la stack Docker

Démarrez l'ensemble des conteneurs :
```bash
make up
```
*(Ou : `docker compose up --build -d`)*

Vérifiez que tous les services sont en cours d'exécution :
```bash
make ps
```

Tous les conteneurs doivent être `Up` et `healthy`.

---

## Configuration & Flash du Firmware ESP8266

Le firmware se trouve dans le sous-module `services/software`.

### 1. Configuration des paramètres (`Config.h`)

Ouvrez le fichier [`services/software/include/Config.h`](file:///c:/Users/aurel/OneDrive/Documents/M1/Workshop/main/services/software/include/Config.h) :

```cpp
// --- NETWORK & SERVER ---
static const char *WIFI_SSID = "NOM_DE_VOTRE_BOX_OU_PARTAGE";
static const char *WIFI_PASSWORD = "MOT_DE_PASSE_WIFI";

static const char *SERVER_HOST = "<BIND_IP>"; // IP de votre machine (variable BIND_IP du .env)
constexpr int WEBSOCKET_PORT = 8080;

// MQTTS broker (Port 8883 sécurisé par TLS)
static const char *MQTT_HOST = "<BIND_IP>";   // Même IP que BIND_IP dans .env
constexpr uint16_t MQTT_PORT = 8883;
static const char *MQTT_USERNAME = "sentinel_iot";
static const char *MQTT_PASSWORD = "<MQTT_ESP_PASSWORD>"; // Doit correspondre à MQTT_ESP_PASSWORD dans .env
```

### 2. Certificat CA embarqué automatique

Lors de la compilation, PlatformIO exécute automatiquement le script `services/software/scripts/embed_ca.py` qui lit la CA racine dans le dossier des secrets (`secrets/ca.crt`) et génère `services/software/include/MqttCa.h`. L'ESP vérifie ainsi la chaîne cryptographique du serveur sans altération possible.

### 3. Compilation et Flash

Branchez l'ESP8266 en USB à votre ordinateur :

- **Compiler le code :**
  ```bash
  cd services/software
  pio run
  ```
- **Téléverser vers l'ESP8266 :**
  ```bash
  pio run -t upload
  # Ou depuis la racine du projet :
  make flash
  ```
- **Ouvrir le moniteur série :**
  ```bash
  pio device monitor
  # Ou depuis la racine du projet :
  make monitor
  ```

Dès le démarrage, l'ESP se connecte au Wi-Fi, synchronise l'heure via NTP (nécessaire pour la validation des dates de certificats TLS) puis se connecte au broker Mosquitto en MQTTS :
```text
[MQTT] connected
```

---

## Guide de Test et Validation

Voici comment vérifier méthodiquement que chaque brique fonctionne de manière autonome :

### Test 1 : Vérifier l'état global des conteneurs

```bash
docker compose ps
```
**Résultat attendu :**
- `sentinel-mosquitto` : `Up` (port 8883)
- `sentinel-detection` : `Up (healthy)`
- `sentinel-backend` : `Up (healthy)`
- `sentinel-reverse-proxy` : `Up` (ports 80 et 443)
- `g4-db` : `Up (healthy)`

---

### Test 2 : Tester la connectivité TCP du port 8883

Sous Linux / macOS / Git Bash :
```bash
curl -v telnet://${BIND_IP}:8883 --connect-timeout 3
# Ou avec netcat :
nc -zv ${BIND_IP} 8883
```
Sous Windows PowerShell :
```powershell
Test-NetConnection -ComputerName $env:BIND_IP -Port 8883
```
**Résultat attendu :** Connexion réussie (`TcpTestSucceeded : True` ou `Connected`).

---

### Test 3 : Tester la connexion MQTTS (TLS 8883) avec le compte ESP

Vous pouvez simuler l'envoi d'une trame télémétrique identique à celle de l'ESP8266 en utilisant le client Mosquitto dans un conteneur éphémère :

```bash
echo '{"ts":1728289070000,"temp":22.5,"hum":45.0,"pir":0,"gas_raw":120,"gas_do":1,"warmup":false}' | \
docker run --rm -i -v "${PWD}/secrets/ca.crt:/certs/ca.crt:ro" eclipse-mosquitto:2 \
  mosquitto_pub -h ${BIND_IP} -p 8883 --cafile /certs/ca.crt \
  -u sentinel_iot -P ${MQTT_ESP_PASSWORD} -t "sentinelx/esp01/telemetry" -l
```

**Résultat attendu :** La commande s'exécute sans erreur et se termine avec le code 0.

---

### Test 4 : Vérifier l'ingestion par le service de détection

Consultez les logs récents du service de détection :
```bash
docker logs --tail 20 sentinel-detection
```
**Résultat attendu :**
```text
INFO detection_service.mqtt_client: MQTT connecté host=mqtt.sentinel.lan port=8883
INFO detection_service.engine: nouvel appareil device_id=esp01
INFO detection_service.engine: changement d'état device_id=esp01 status=aucune device_state=warming_up
```

Vous pouvez également interroger l'API de diagnostic :
```bash
curl -s http://127.0.0.1:18000/health
```
La réponse JSON doit afficher `"mqtt":{"connected":true}` et `"database":{"reachable":true}`.

---

### Test 5 : Tester le Reverse Proxy et l'API Backend

Testez le point d'entrée sécurisé HTTP(S) :
```bash
curl -sk https://${BIND_IP}/api/health
```
**Résultat attendu :**
```json
{"status":"OK","uptime":759.27}
```

---

### Test 6 : Injecter des données simulées complètes

Pour valider le calcul des alertes (fumée, fuite de gaz, incendie) sans matériel physique :
```bash
make sim
```
Le conteneur injecte une séquence temporelle prédéfinie visible en direct dans les logs de `sentinel-detection`.

---

## Commandes Utiles (Makefile)

| Commande | Action |
|---|---|
| `make help` | Affiche l'aide de toutes les commandes disponibles. |
| `make init` | Initialise les sous-modules Git et crée le fichier `.env`. |
| `make certs` | Génère et installe les certificats TLS de la PKI. |
| `make users` | Génère les comptes MQTT hashés dans `password.txt`. |
| `make up` | Démarre toute la pile en arrière-plan. |
| `make down` | Arrête la pile Docker (conserve les volumes et données). |
| `make logs` | Affiche les logs en direct de tous les services (`Ctrl+C` pour quitter). |
| `make ps` | Affiche l'état détaillé de chaque conteneur. |
| `make sim` | Lance la simulation d'un faux ESP + caméra. |
| `make db` | Ouvre un terminal SQL interactif dans la base de données. |
| `make db-backup`| Exécute un backup PostgreSQL dans `backups/`. |
| `make flash` | Compile et téléverse le firmware ESP8266 branché en USB. |
| `make monitor` | Ouvre le moniteur série de l'ESP8266 (115200 bauds). |

---

## Résolution des Problèmes Courants (Troubleshooting)

### 1. Erreur : `password-file: Error: Unable to open pwfile "/mosquitto/config/password.txt"`
- **Cause :** Les comptes Mosquitto n'ont pas été générés avant le démarrage.
- **Solution :** Lancez `make users` puis redémarrez Mosquitto : `docker compose restart sentinel-mosquitto`.

### 2. Dossier fantôme `ca.crt` dans `services/infrastructure/mosquitto/certs/`
- **Cause :** Docker a créé un répertoire `ca.crt` car `docker compose up` a été lancé alors que le fichier de certificat n'existait pas encore.
- **Solution :**
  ```bash
  make down
  rm -rf services/infrastructure/mosquitto/certs/ca.crt
  make certs
  make up
  ```

### 3. Échec de vérification TLS côté ESP (`connection failed, state=-2`)
- **Cause 1 (Horloge non synchronisée) :** Le client TLS (BearSSL) refuse le certificat si la date locale de l'ESP est en 1970. Vérifiez que la connexion Wi-Fi de l'ESP a accès à Internet pour joindre le serveur NTP (`pool.ntp.org`).
- **Cause 2 (Adresse IP non présente dans le SAN) :** Le certificat du broker n'a pas été généré avec l'IP actuelle. Vérifiez `BIND_IP` dans `.env`, puis relancez `make certs` et `docker compose restart sentinel-mosquitto`.

### 4. Erreur d'exécution de script sur Windows (`pipefail` ou chemins MSYS)
- Les scripts `scripts/install-pki.sh` et `services/infrastructure/scripts/mqtt-users.sh` intègrent `export MSYS_NO_PATHCONV=1` et utilisent un dossier temporaire local. Exécutez-les toujours via **Git Bash**, **WSL** ou via `make`. Si OpenSSL n'est pas présent sur l'hôte, le script bascule automatiquement dans un conteneur Docker Alpine.
