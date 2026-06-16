# wacrm-baileys-relay

Serveur Node.js qui automatise les envois WhatsApp de COD Team via **Baileys** (WhatsApp Web non-officiel).

## Comment ça marche

```
COD Team app                Supabase                  Ce serveur
(GitHub Pages)        →    (wa_campaigns)       →    (Baileys → WhatsApp)
        │                       ↑                            │
        │ Crée campagne         │                            │
        │ send_mode='baileys'   │                            │
        │                       │                            │
        │                       │ Poll toutes les 8s         │
        │                       └────────────────────────────┘
        │                                Auto-envoie chaque destinataire
        │                                avec délais 8-15s aléatoires
        │
        └─► UI: voit le statut + QR code via /status
```

## ⚠️ Risques à connaître

- Baileys est **contre les CGU WhatsApp**. Risque de ban.
- Bans typiques : 24h-7j temporaire, parfois permanent.
- Pour réduire le risque : numéro chauffé, délais aléatoires (déjà configuré), opt-in audience, ≤150 msg/jour.
- **Test d'abord avec un numéro secondaire** avant de l'utiliser sur votre numéro pro.

## Pré-requis

1. **Compte Supabase** : votre projet `sfsnyppydvhvnjiqjgjt` (déjà OK)
2. **Compte Railway** (gratuit jusqu'à 5$/mois de crédit) : https://railway.app
3. **Numéro WhatsApp** : un téléphone avec WhatsApp installé pour scanner le QR code une fois
4. **Migrations SQL** : v6, v7, v8 et v9 appliquées dans Supabase

## 📋 Étape 1 — Créer un bot user dans Supabase

Pour que le relais puisse lire/écrire dans Supabase, il faut un compte auth dédié.

1. **Ouvrez** https://supabase.com/dashboard/project/sfsnyppydvhvnjiqjgjt/auth/users
2. Cliquez **« Add user »** → **« Create new user »**
3. Email : `wabot@votredomaine.com` (ou n'importe quel email)
4. Password : générez-en un fort (24+ caractères aléatoires)
5. Cochez **« Auto Confirm User »**
6. Cliquez **Create user**
7. Notez l'email + le password — vous en aurez besoin à l'étape 3

Ensuite, ouvrez le **SQL Editor** et collez :
```sql
update public.profiles set role='admin', full_name='WhatsApp Bot'
where id=(select id from auth.users where email='wabot@votredomaine.com');
```

Vérifiez :
```sql
select id,full_name,role from public.profiles where role='admin';
```

## 🚂 Étape 2 — Déployer sur Railway

### Option A : Depuis GitHub (recommandé)

1. **Pushez ce dossier `wacrm-relay/`** dans votre repo GitHub
2. Allez sur **https://railway.app/new** → **« Deploy from GitHub repo »**
3. Sélectionnez votre repo `cod-team-app`
4. Railway détecte le `Dockerfile` automatiquement
5. Dans **« Service Settings » → « Source » → « Root Directory »** : indiquez `wacrm-relay`
6. Cliquez **Deploy** — première build prend ~3 min

### Option B : CLI Railway

```bash
cd wacrm-relay
npm i -g @railway/cli
railway login
railway init
railway up
```

## ⚙️ Étape 3 — Variables d'environnement

Dans Railway → votre projet → **Variables** → ajoutez :

| Variable | Valeur |
|---|---|
| `SUPABASE_URL` | `https://sfsnyppydvhvnjiqjgjt.supabase.co` |
| `SUPABASE_ANON_KEY` | la clé anon (à copier depuis Supabase Settings → API) |
| `SUPABASE_BOT_EMAIL` | l'email du bot user (étape 1) |
| `SUPABASE_BOT_PASSWORD` | le password du bot user |
| `RELAY_AUTH_TOKEN` | un token long aléatoire (ex: `openssl rand -hex 32`) |
| `CORS_ORIGINS` | `https://mrchiealgerie-hub.github.io` |
| `SEND_DELAY_MIN_MS` | `8000` (par défaut) |
| `SEND_DELAY_MAX_MS` | `15000` (par défaut) |
| `MAX_PER_HOUR` | `120` (commencez bas, augmentez progressivement) |
| `MAX_PER_DAY` | `500` (idem) |

**Pour générer un RELAY_AUTH_TOKEN sécurisé**, dans n'importe quel terminal :
```bash
openssl rand -hex 32
# ou : node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

## 💾 Étape 4 — Volume persistant (CRUCIAL)

Sans volume, Railway efface l'auth Baileys à chaque restart → vous devez re-scanner le QR à chaque fois.

1. Dans Railway → votre service → **Settings** → **Volumes** → **+ Add Volume**
2. **Mount path** : `/data`
3. **Size** : 1 GB suffit
4. Save — Railway redéploie automatiquement

## 📱 Étape 5 — Scanner le QR code

Une fois la première build terminée :

1. Railway → votre service → **Settings** → **Networking** → **Generate Domain**
2. Vous obtenez une URL type `https://votre-relais.up.railway.app`
3. **Notez cette URL** — vous la mettrez dans l'app COD Team
4. Récupérez le QR :
   - Ouvrez `https://votre-relais.up.railway.app/status` avec en-tête `Authorization: Bearer VOTRE_RELAY_AUTH_TOKEN`
   - **OU** plus simple : ouvrez l'app COD Team → **📲 WhatsApp CRM** → onglet **« Connexion »** (à venir dans v10+)
5. Scannez le QR avec WhatsApp sur votre téléphone (**Réglages → Appareils connectés → Lier un appareil**)
6. Une fois scanné, l'état passe à `connected` — c'est gagné !

## 🔧 Étape 6 — Configurer COD Team

Dans l'app COD Team :

1. Ouvrir **⚙ Réglages**
2. Section **« Relais Baileys »** (à venir avec v10.1)
3. Remplir :
   - **URL du relais** : `https://votre-relais.up.railway.app`
   - **Token** : votre `RELAY_AUTH_TOKEN`
4. Sauvegarder

## 🚀 Étape 7 — Lancer une campagne en mode auto

1. **📲 WhatsApp CRM → + Nouvelle campagne**
2. Wizard étapes 1-3 comme avant
3. **Étape 4** : choisir **« Auto (Baileys) »** au lieu de **« Manuel (wa.me) »**
4. Lancer → le serveur Baileys prend la relève, vous voyez le compteur monter en temps réel

## 📊 Vérifier que ça tourne

- **Logs Railway** : doivent afficher périodiquement `[Worker] Sending to ...` et `[Worker] ✓ Sent to ...`
- **Endpoint health** : `https://votre-relais.up.railway.app/health` doit retourner `{"ok":true,"state":"connected"}`
- **App COD Team** : le panneau de statut indique `🟢 Connecté` et le numéro du téléphone lié

## 🆘 Dépannage

| Symptôme | Solution |
|---|---|
| `state: disconnected` après scan | Le volume n'est pas monté. Vérifier étape 4. |
| `Bot login failed` dans les logs | Vérifier `SUPABASE_BOT_EMAIL/PASSWORD` + le bot user a bien `role='admin'` dans `profiles` |
| `Number not registered on WhatsApp` | Normal pour les numéros inexistants. Le destinataire est marqué `failed`. |
| Aucun envoi ne part | Vérifier que la campagne a `send_mode='baileys'` (pas `manual`) ET `status='running'` |
| Ban WhatsApp | Baissez `MAX_PER_HOUR` à 60 et `MAX_PER_DAY` à 200. Attendez 24-48h. |
| Connexion perdue souvent | Bug Baileys connu — laissez les reconnexions auto faire leur travail. Pire cas, redémarrez le service Railway. |

## 🔒 Sécurité

- **Ne commitez JAMAIS le `.env`** dans Git
- **Ne partagez JAMAIS le `RELAY_AUTH_TOKEN`** — il donne le contrôle total du relais
- Le bot user Supabase a un rôle `admin` mais reste soumis à RLS — il ne peut pas faire n'importe quoi
- Le dossier `auth_info_baileys` contient les credentials WhatsApp — il est dans le volume privé Railway, jamais exposé

## 🛠 Développement local

```bash
cd wacrm-relay
cp .env.example .env
# Éditez .env avec vos credentials
npm install
npm start
```

Le QR s'affiche dans les logs au démarrage. Scannez-le avec votre téléphone.

## 📝 Coûts

- **Railway** : ~5$/mois (volume + execution time pour un service qui tourne 24/7)
- **Supabase** : votre plan actuel (free tier OK si <500 MB DB)
- **WhatsApp** : 0 DA (c'est tout l'intérêt)

## License

MIT
