# Twenty CRM — Self-host package pour COD Team

Package prêt à déployer pour héberger **votre propre instance de Twenty CRM**
sur votre infrastructure. Préparé en juin 2026 pour le projet COD Team Algérie.

## 🎯 Qu'est-ce que c'est

[Twenty CRM](https://github.com/twentyhq/twenty) — le CRM open-source #1.
Conçu pour gérer **contacts B2B / pipelines de vente** avec une UX moderne.

⚠️ **Important** : Twenty est un CRM **B2B**, pas un outil d'opérations COD.
Il NE remplace PAS votre COD Team app. Il est utile pour :
- Gérer des **grossistes / revendeurs** (canal B2B)
- Gérer des **partenariats** (influenceurs, fournisseurs)
- Pipeline de **gros contrats**
- CRM pour la branche corporate de votre business

## 📦 3 paths de déploiement (du plus simple au plus pro)

### Path 1 — Twenty Cloud (recommandé pour démarrer)
```
URL: https://app.twenty.com/welcome
Coût: 0 DA (free tier)
Temps: 5 minutes
Niveau: Aucun technique
```
Créez votre compte, vous avez Twenty en ligne en 60 secondes.
Pas de migration possible vers votre propre serveur après.

### Path 2 — Hostinger Cloud Managed
```
URL: https://hpanel.hostinger.com/web-apps/twenty
Coût: ~15 $/mois
Temps: 15 minutes
Niveau: Léger
```
Hostinger a un installer one-click pour Twenty.
Inclut PostgreSQL + Redis + nom de domaine + SSL.

### Path 3 — Railway / DigitalOcean / VPS (vrai self-host)
```
URL: votre.domaine.com (libre choix)
Coût: ~20-25 $/mois (Railway) ou ~10 $/mois (DigitalOcean droplet)
Temps: 30-45 minutes
Niveau: Technique
```
Vous contrôlez tout. Utilise ce package docker-compose.yml.

## 🚀 Déploiement sur Railway (recommandé Path 3)

### Pré-requis
- Compte Railway ✓ (vous l'avez déjà pour le relais Baileys)
- Domaine ou sous-domaine (ex: `twenty.codteam.dz`)

### Étape 1 — Créer un nouveau projet Railway
1. Aller sur **https://railway.app/new**
2. Cliquer **« Deploy from template »** → chercher **"Twenty"**
3. Si template présent : cliquer **Deploy**, sinon passer à Étape 2

### Étape 2 — Deploy manuel (template absent)
1. **New Project** → **Empty Project**
2. **+ New** → **Database** → **PostgreSQL** (Railway le provisionne)
3. **+ New** → **Database** → **Redis**
4. **+ New** → **Empty Service** → renommer "twenty-server"
5. Dans **twenty-server** → **Settings** → **Source** :
   - **Image** : `twentycrm/twenty:latest`
   - **Port** : `3000`
6. Variables d'environnement (Settings → Variables) :
   ```
   NODE_ENV=production
   SERVER_URL=https://${{RAILWAY_PUBLIC_DOMAIN}}
   FRONT_BASE_URL=https://${{RAILWAY_PUBLIC_DOMAIN}}
   DATABASE_URL=${{Postgres.DATABASE_URL}}
   REDIS_URL=${{Redis.REDIS_URL}}
   APP_SECRET=<générer avec : openssl rand -hex 32>
   STORAGE_TYPE=local
   STORAGE_LOCAL_PATH=/app/.local-storage
   SIGN_IN_PREFILLED=true
   AUTH_PASSWORD_ENABLED=true
   ```
7. **Settings** → **Networking** → **Generate Domain** → noter l'URL générée
8. **Volume** → **+ Add Volume** → mount path `/app/.local-storage` (pour les uploads)
9. Wait ~3 minutes pour le premier deploy

### Étape 3 — Premier login
1. Ouvrir votre URL Railway (ex: `twenty-server.up.railway.app`)
2. Twenty affiche **"Welcome"** → cliquer **Sign Up**
3. Créer le compte admin
4. Onboarding guidé (~5 min)

### Étape 4 — Connecter un domaine perso (optionnel)
1. Railway → **Settings** → **Networking** → **Custom Domain**
2. Ajouter `twenty.codteam.dz` (ou votre domaine)
3. Suivre les instructions DNS (CNAME)

## 🔌 Intégration avec COD Team app

Pour partager des données entre les deux outils, vous avez 3 options :

### Option A — Aucune intégration (recommandée)
Les deux outils restent indépendants. COD Team gère le COD retail, Twenty gère les grossistes.

### Option B — Webhook → API
COD Team app envoie un webhook vers Twenty à chaque commande > 50 000 DA.
Twenty crée un "Deal" automatiquement.
**Effort** : ~1 semaine de code custom.

### Option C — Import CSV manuel
Une fois par semaine, vous exportez les VIPs depuis Clients 360° (CSV)
et vous les importez dans Twenty comme "People" + "Companies".
**Effort** : 5 min/semaine, zero code.

## 🧮 Coûts annuels comparés

| Solution | Coût/an | Pro | Contre |
|---|---|---|---|
| Twenty Cloud free | 0 DA | Aucune infra | Pas de migration possible |
| Twenty Cloud Pro | ~240 $/an | Support officiel | Cher si gros usage |
| Hostinger Managed | ~180 $/an | One-click | Pas Algérie-friendly |
| Railway (ce package) | ~240 $/an | Total contrôle, votre data | Setup technique |
| DigitalOcean droplet | ~120 $/an | Le moins cher | Plus de maintenance |

## ⚠️ Garde-fous importants

- **Ne JAMAIS commit le `.env`** dans Git (déjà dans `.gitignore`)
- **APP_SECRET** doit être différent entre staging et prod
- **Backup PostgreSQL quotidien obligatoire** (Twenty stocke tout dedans)
- **Twenty Cloud free tier** : ~3-5 utilisateurs gratuits puis payant
- **Self-host** : vous êtes responsable des mises à jour de sécurité Twenty

## 🆘 Si vous voulez de l'aide

Je peux vous accompagner sur :
- Setup Railway pas-à-pas
- Configuration domaine personnel
- Import initial de vos clients VIP depuis COD Team
- Intégration webhook COD → Twenty

Demandez juste.
