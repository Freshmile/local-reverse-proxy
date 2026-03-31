# Traefik Reverse Proxy avec step-ca ACME

Configuration complète de Traefik avec **certificats ACME automatiques** via step-ca pour un environnement de développement local sécurisé avec HTTPS.

## Fonctionnalités

- **Certificats automatiques** : step-ca génère les certificats à la demande via ACME
- Support HTTPS pour tous les services sans configuration manuelle
- Redirection automatique HTTP vers HTTPS
- Dashboard Traefik pour monitoring et debugging
- Auto-discovery des services Docker via labels
- Makefile multi-OS pour une utilisation simplifiée
- Support Linux, macOS et Windows

## Architecture

```
Service démarre avec labels Traefik
    ↓
Traefik détecte le nouveau domaine
    ↓
Traefik demande un certificat à step-ca (ACME)
    ↓
step-ca génère et signe le certificat
    ↓
Traefik utilise le certificat
    ↓
Navigateur accepte (CA installée)
```

## Prérequis

- Docker et Docker Compose installés
- Navigateur moderne (Chrome 64+, Firefox 60+) pour la résolution automatique de *.localhost

## Démarrage Rapide

### Option 1: Makefile (Recommandé)

```bash
# Setup complet en une seule commande
make setup
```

Cette commande va:
1. Démarrer step-ca et Traefik (avec dépendance healthcheck)
2. Extraire et installer le certificat CA automatiquement

Accédez ensuite au dashboard: **https://traefik.localhost**

Pour tester rapidement avec le service `whoami` inclus dans les exemples:

```bash
docker compose -f examples/example-service.yml up -d whoami
# https://whoami.localhost
```

### Option 2: Manuel

```bash
# 1. Démarrer step-ca et Traefik
docker compose up -d

# 2. Installer le certificat CA
make install-ca

# 3. Accéder au dashboard
# https://traefik.localhost
```

## Installation du Certificat CA

Le certificat CA doit être importé **une seule fois** dans votre système pour que tous les services HTTPS soient approuvés.

> **Note:** `make setup` exécute automatiquement `make install-ca`. Cette étape n'est nécessaire manuellement que si vous avez utilisé `make start` au lieu de `make setup`, ou pour réinstaller le certificat (nouveau profil Firefox, nouvelle machine, etc.).

### Installation Automatique (Recommandé)

```bash
make install-ca
```

Cette commande:
- Extrait le certificat CA de step-ca
- Détecte automatiquement votre OS (Linux/macOS/Windows)
- Installe le certificat dans Chrome/Chromium (NSS database)
- Installe le certificat dans Firefox (tous les profils, y compris snap)
- Affiche les instructions pour l'installation système (curl, wget, etc.)

### Installation Manuelle (Alternative)

**Linux (tous navigateurs):**
```bash
sudo cp ./certs/root_ca.crt /usr/local/share/ca-certificates/step-ca-dev.crt
sudo update-ca-certificates
```

**macOS:**
```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ./certs/root_ca.crt
```

**Windows (PowerShell administrateur):**
```powershell
Import-Certificate -FilePath ".\certs\root_ca.crt" -CertStoreLocation Cert:\LocalMachine\Root
```

### Après Installation

1. **Redémarrez votre navigateur**
2. Accédez à vos services en HTTPS
3. Les certificats sont automatiquement générés et approuvés

## Commandes Make Disponibles

```bash
make help          # Afficher l'aide
make setup         # Setup complet (recommandé pour premier démarrage)
make start         # Démarrer Traefik et step-ca
make stop          # Arrêter tous les containers
make restart       # Redémarrer tous les containers
make logs          # Afficher les logs Traefik en temps réel
make logs-ca       # Afficher les logs step-ca en temps réel
make status        # Afficher l'état des services
make install-ca    # Installer le certificat CA
make labels        # Générer les labels Traefik pour un nouveau service
make clean         # Tout supprimer (containers, volumes, certificats)
```

## Ajouter un Nouveau Service

### Méthode 1: Docker Compose

Créez un fichier `docker-compose.override.yml` ou ajoutez à votre projet:

```yaml
services:
  mon-app:
    image: nginx:alpine
    container_name: mon-app
    networks:
      - traefik_network
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik_network"
      - "traefik.http.routers.mon-app.rule=Host(`mon-app.localhost`)"
      - "traefik.http.routers.mon-app.entrypoints=websecure"
      - "traefik.http.routers.mon-app.tls.certresolver=stepca"
      - "traefik.http.services.mon-app.loadbalancer.server.port=80"

networks:
  traefik_network:
    external: true
```

Ensuite démarrez:
```bash
docker compose up -d
```

Accédez à: **https://mon-app.localhost** (certificat généré automatiquement!)

### Méthode 2: Container Docker Standalone

```bash
docker run -d \
  --name mon-app \
  --network traefik_network \
  --label "traefik.enable=true" \
  --label "traefik.docker.network=traefik_network" \
  --label "traefik.http.routers.mon-app.rule=Host(\`mon-app.localhost\`)" \
  --label "traefik.http.routers.mon-app.entrypoints=websecure" \
  --label "traefik.http.routers.mon-app.tls.certresolver=stepca" \
  --label "traefik.http.services.mon-app.loadbalancer.server.port=80" \
  nginx:alpine
```

## Structure du Projet

```
.
├── Makefile                        # Automatisation multi-OS
├── docker-compose.yml              # Orchestration Docker (Traefik + step-ca)
├── .gitignore                      # Fichiers à ignorer
├── README.md                       # Ce fichier
├── traefik/
│   ├── traefik.yml                 # Configuration statique
│   ├── acme/                       # Stockage certificats ACME
│   │   └── acme.json               # Certificats générés (Git-ignoré)
│   ├── dynamic/
│   │   └── tls.yml                 # Options TLS
│   └── logs/                       # Logs Traefik
├── certs/
│   └── root_ca.crt                 # Certificat CA (à importer!)
├── scripts/
│   ├── install-ca.sh               # Installation CA dans les navigateurs
│   └── generate-labels.sh          # Génération interactive de labels Traefik
└── examples/
    └── example-service.yml         # Templates services exemples
```

## Configuration des Domaines

Les domaines `*.localhost` se résolvent automatiquement vers `127.0.0.1` sur les navigateurs modernes (Chrome 64+, Firefox 60+). **Aucune configuration DNS n'est nécessaire!**

Si votre navigateur ne supporte pas la résolution automatique, ajoutez manuellement à `/etc/hosts` (Linux/macOS) ou `C:\Windows\System32\drivers\etc\hosts` (Windows):

```
127.0.0.1 traefik.localhost
127.0.0.1 mon-app.localhost
```

## Exemples de Configuration Avancée

### Service avec Path Prefix

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=traefik_network"
  - "traefik.http.routers.api.rule=Host(`api.localhost`) && PathPrefix(`/v1`)"
  - "traefik.http.routers.api.entrypoints=websecure"
  - "traefik.http.routers.api.tls.certresolver=stepca"
```

### Service avec Multiples Domaines

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=traefik_network"
  - "traefik.http.routers.multi.rule=Host(`app1.localhost`) || Host(`app2.localhost`)"
  - "traefik.http.routers.multi.entrypoints=websecure"
  - "traefik.http.routers.multi.tls.certresolver=stepca"
```

### Service avec TLS 1.3 Strict

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=traefik_network"
  - "traefik.http.routers.secure.rule=Host(`secure.localhost`)"
  - "traefik.http.routers.secure.entrypoints=websecure"
  - "traefik.http.routers.secure.tls.certresolver=stepca"
  - "traefik.http.routers.secure.tls.options=modern@file"
```

### Service avec Health Check

```yaml
services:
  monitored-app:
    image: nginx:alpine
    networks:
      - traefik_network
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik_network"
      - "traefik.http.routers.monitored.rule=Host(`monitored.localhost`)"
      - "traefik.http.routers.monitored.entrypoints=websecure"
      - "traefik.http.routers.monitored.tls.certresolver=stepca"
      - "traefik.http.services.monitored.loadbalancer.server.port=80"
      - "traefik.http.services.monitored.loadbalancer.healthcheck.path=/health"
      - "traefik.http.services.monitored.loadbalancer.healthcheck.interval=10s"
```

### Service avec Middleware (Strip Prefix)

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=traefik_network"
  - "traefik.http.routers.prefixed.rule=Host(`app.localhost`) && PathPrefix(`/admin`)"
  - "traefik.http.routers.prefixed.entrypoints=websecure"
  - "traefik.http.routers.prefixed.tls.certresolver=stepca"
  - "traefik.http.routers.prefixed.middlewares=strip-admin"
  - "traefik.http.services.prefixed.loadbalancer.server.port=80"
  # Strip /admin prefix before forwarding to backend
  - "traefik.http.middlewares.strip-admin.stripprefix.prefixes=/admin"
```

Voir `examples/example-service.yml` pour plus d'exemples complets.

## Troubleshooting

### Le service n'apparaît pas dans Traefik

1. Vérifiez que le label `traefik.enable=true` est présent
2. Vérifiez que le service est sur le réseau `traefik_network`
3. Consultez les logs: `make logs` ou `docker compose logs traefik`
4. Vérifiez l'état: `make status`

### Certificat non approuvé par le navigateur

1. Assurez-vous d'avoir importé `certs/root_ca.crt` dans votre système/navigateur
2. Redémarrez votre navigateur après l'import
3. Vérifiez que step-ca est healthy: `make status`
4. Si nécessaire, régénérez tout: `make clean && make setup`

### Impossible d'accéder au service

1. Vérifiez que Traefik est démarré: `make status`
2. Testez avec curl: `curl -Ik https://traefik.localhost`
3. Vérifiez le dashboard Traefik pour voir si le router est configuré
4. Consultez les logs du service: `docker compose logs nom-du-service`

### step-ca ne démarre pas

1. Vérifiez les logs: `make logs-ca`
2. Supprimez le volume et recommencez: `make clean && make setup`

### Ports 80/443 déjà utilisés

```bash
# Trouver le processus utilisant le port
sudo lsof -i :80
sudo lsof -i :443

# Arrêter le service conflictuel ou modifier les ports dans docker-compose.yml
# Exemple: "8080:80" et "8443:443"
```

### Régénérer les Certificats

```bash
# Supprimer tout et recommencer
make clean
make setup
```

## Informations Techniques

- **Version Traefik:** v3.2
- **step-ca:** smallstep/step-ca:latest
- **Protocole:** ACME avec TLS-ALPN-01 Challenge
- **Validité des certificats:** Définie par step-ca (par défaut 24h, renouvelés automatiquement)
- **Logs d'accès:** `traefik/logs/access.log` (format JSON)
- **Rechargement automatique:** Les modifications de `traefik/dynamic/*.yml` sont appliquées sans redémarrage

**Architecture réseau Docker:**
- `step-ca` tourne avec `network_mode: host` pour pouvoir valider les challenges ACME TLS sur `*.localhost`
- `traefik` se connecte à step-ca via `host.docker.internal:9000`
- Les services utilisent le réseau bridge `traefik_network`

## Notes de Sécurité

**Dashboard non sécurisé:** Par défaut, le dashboard Traefik est accessible sans authentification (`api.insecure: true`). C'est acceptable en développement local, mais ne jamais exposer cette configuration sur un réseau public.

Cette configuration est **exclusivement pour le développement local**. Les certificats step-ca ne doivent **jamais** être utilisés en production publique.

Pour la production:
- Utilisez Let's Encrypt pour des certificats réels
- Activez l'authentification sur le dashboard Traefik
- Suivez les meilleures pratiques de sécurité pour votre environnement
- Ne jamais exposer le dashboard publiquement sans authentification

## Ressources

- [Documentation Traefik](https://doc.traefik.io/traefik/)
- [Documentation step-ca](https://smallstep.com/docs/step-ca/)
- [Documentation Docker Compose](https://docs.docker.com/compose/)
- [ACME Protocol](https://letsencrypt.org/docs/challenge-types/)

## License

Cet outil de développement est fourni tel quel. Utilisez-le librement pour vos besoins de développement local.
