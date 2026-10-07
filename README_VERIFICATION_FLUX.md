# Guide de Vérification du Flux : ESP8266 ➔ Mosquitto ➔ Détection ➔ Base de Données

Ce document décrit et détaille comment tester et vérifier de bout en bout que les données envoyées par l'ESP8266 transitent correctement par le broker Mosquitto (MQTTS), sont traitées par le service de détection et sont bien enregistrées dans la base de données PostgreSQL (`g4-db`).

---

## 1. Schéma du Flux de Données

```
┌──────────────┐          MQTTS (8883, TLS)          ┌──────────────────┐
│   ESP8266    │ ──────────────────────────────────> │    Mosquitto     │
│  (Hardware)  │  sentinelx/{device_id}/telemetry    │  (Broker MQTTS)  │
└──────────────┘  sentinelx/{device_id}/alert        └─────────┬────────┘
                                                               │ (Topics souscrits)
                                                               ▼
                                                     ┌──────────────────┐
                                                     │ sentinel-detection│
                                                     │ (FastAPI/Python) │
                                                     └─────────┬────────┘
                                                               │ (Batch SQL Async)
                                                               ▼
                                                     ┌──────────────────┐
                                                     │    PostgreSQL    │
                                                     │     (g4-db)      │
                                                     └──────────────────┘
                                                       • detection.sensor_readings
                                                       • detection.predictions
                                                       • public.alerts
```

---

## 2. Tables de Stockage dans PostgreSQL

| Table | Schéma | Description |
|---|---|---|
| `detection.sensor_readings` | `detection` | Relevés bruts des capteurs : température (`temp`), humidité (`hum`), présence (`pir`), gaz analogique (`gas_raw`), gaz seuil digital (`gas_do`), préchauffage (`warmup`). |
| `detection.predictions` | `detection` | États et décisions calculés par le service (état de l'appareil, alertes détectées, baseline gaz). |
| `public.alerts` | `public` | Alertes actives transmises au dashboard (alertes seuil local ou alertes émises par le modèle). |

---

## 3. Procédure de Test et Vérification Pas-à-Pas

Les commandes ci-dessous utilisent les variables d'environnement définies dans votre `.env` (`${BIND_IP}`, `${MQTT_ESP_PASSWORD}`) et fonctionnent sur **Linux**, **macOS** et **Windows** (Git Bash, WSL ou PowerShell).

### Étape 1 : Vérifier que les services sont actifs

Assurez-vous que les 3 conteneurs clés sont démarrés :
```bash
docker compose ps sentinel-mosquitto sentinel-detection db
```
Les statuts doivent indiquer `Up` (avec `healthy` pour `db` et `sentinel-detection`).

---

### Étape 2 : Envoyer une trame télémétrique (Simulation ESP)

Cette commande injecte une trame MQTTS identique à celle envoyée par le firmware de l'ESP8266 :

```bash
echo '{"ts":1728289500000,"temp":24.1,"hum":52.3,"pir":1,"gas_raw":185,"gas_do":0,"warmup":false}' | \
docker run --rm -i -v "${PWD}/secrets/ca.crt:/certs/ca.crt:ro" eclipse-mosquitto:2 \
  mosquitto_pub -h ${BIND_IP} -p 8883 --cafile /certs/ca.crt \
  -u sentinel_iot -P ${MQTT_ESP_PASSWORD} -t "sentinelx/esp01/telemetry" -l
```

#### Vérifier dans les logs de détection :
```bash
docker logs --tail 10 sentinel-detection
```
**Sortie attendue :**
```text
INFO detection_service.engine: nouvel appareil device_id=esp01
INFO detection_service.engine: changement d'état device_id=esp01 status=aucune device_state=warming_up
```

#### Vérifier l'insertion dans la base de données :
```bash
docker exec g4-db psql -U sentinel -d sentinel -c \
  "SELECT id, device_id, received_at, temp, hum, pir, gas_raw, gas_do, warmup FROM detection.sensor_readings ORDER BY id DESC LIMIT 5;"
```
**Exemple de résultat :**
```text
 id | device_id |          received_at          | temp | hum  | pir | gas_raw | gas_do | warmup 
----+-----------+-------------------------------+------+------+-----+---------+--------+--------
  2 | esp01     | 2026-10-07 09:05:19.416567+00 | 24.1 | 52.3 | t   |     185 | t      | f
```

---

### Étape 3 : Envoyer une alerte seuil (Simulation ESP)

Lorsqu'un seuil critique de gaz ou température est franchi, l'ESP émet sur `sentinelx/{device_id}/alert` :

```bash
echo '{"type": "local_threshold", "value": true}' | \
docker run --rm -i -v "${PWD}/secrets/ca.crt:/certs/ca.crt:ro" eclipse-mosquitto:2 \
  mosquitto_pub -h ${BIND_IP} -p 8883 --cafile /certs/ca.crt \
  -u sentinel_iot -P ${MQTT_ESP_PASSWORD} -t "sentinelx/esp01/alert" -l
```

#### Vérifier l'alerte dans la base de données (`public.alerts`) :
```bash
docker exec g4-db psql -U sentinel -d sentinel -c \
  "SELECT id, time, device_id, severity, title, acknowledged FROM public.alerts ORDER BY time DESC LIMIT 5;"
```
**Exemple de résultat :**
```text
                  id                  |             time              | device_id | severity |                 title                  | acknowledged 
--------------------------------------+-------------------------------+-----------+----------+----------------------------------------+--------------
 6c675af3-a2cc-4b2f-a16b-cb938d2f1334 | 2026-10-07 09:04:45.596997+00 | esp01     | medium   | Alerte capteur local_threshold (esp01) | f
```

---

### Étape 4 : Suivre l'arrivée des données en direct

Pour surveiller le flux en temps réel pendant que votre ESP physique fonctionne :

1. **Observer les réceptions MQTT et traitements :**
   ```bash
   docker logs -f sentinel-detection
   ```

2. **Surveiller l'incrément des mesures dans PostgreSQL :**
   ```bash
   docker exec -it g4-db psql -U sentinel -d sentinel -c \
     "SELECT COUNT(*) AS total_mesures FROM detection.sensor_readings;"
   ```

3. **Consulter l'état de l'appareil via l'API de diagnostic :**
   ```bash
   curl -s http://127.0.0.1:18000/health
   ```
   Ce endpoint confirme :
   - `"mqtt":{"connected":true}`
   - `"database":{"writes_healthy":true,"written":{"sensor_readings":...}}`
   - Le statut courant du `device_id: esp01`.
