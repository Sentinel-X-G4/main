-- Compte PostgreSQL de Grafana : lecture seule sur les schémas public et detection.
-- Rejoué à chaque `make up` par le conteneur grafana-db-init (idempotent) : crée le rôle
-- s'il manque et resynchronise son mot de passe avec GRAFANA_DB_PASSWORD (.env).
-- Variables psql : user, password.

\set ON_ERROR_STOP on

SELECT format('CREATE ROLE %I LOGIN', :'user')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'user')\gexec

SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION '
              'CONNECTION LIMIT 20 PASSWORD %L', :'user', :'password')\gexec

-- Garde-fous : aucune écriture possible, requêtes longues coupées
SELECT format('ALTER ROLE %I SET default_transaction_read_only = on', :'user')\gexec
SELECT format('ALTER ROLE %I SET statement_timeout = %L', :'user', '30s')\gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'user')\gexec
SELECT format('GRANT USAGE ON SCHEMA public, detection TO %I', :'user')\gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA public, detection TO %I', :'user')\gexec
-- Tables créées plus tard (migrations) par le propriétaire du schéma
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA public, detection GRANT SELECT ON TABLES TO %I', :'user')\gexec
