# Reprise et exploitation de Supabase — COD Team v15

**État au 15 novembre 2026.** Le projet Supabase actif est `pqnauwlwyrqftgywgoxi` (nom `cod-team`, organisation `bghhtoeptsxaejfrttbk`, région `eu-west-3` Paris, statut `ACTIVE_HEALTHY`).

| Élément | Valeur |
|---|---|
| URL du projet | `https://pqnauwlwyrqftgywgoxi.supabase.co` |
| Clé `anon` | intégrée dans `index.html` (publique par conception) |
| Schéma | `bootstrap_full.sql` appliqué — 28 tables, 84 politiques RLS, 58 wilayas, 10 réglages |
| Realtime | 28 tables publiées dans `supabase_realtime` |
| Auto-confirmation e-mail | **activée** (`mailer_autoconfirm = true`) |
| `site_url` | `https://chicluxuryy5-art.github.io/cod-team-app/` |
| URL autorisées | fork, dépôt canonique, `http://localhost:8765/**` |
| Mot de passe base | conservé **hors dépôt**, dans `%TEMP%\opencode\cod-team\supabase-cod-team-credentials.txt` |

> Ce guide ne contient aucune clé secrète. La clé `anon` du front est publique ; la clé `service_role` ne doit jamais quitter le dashboard ou un script serveur.

---

## 1. Vérifier que le projet répond

Dans **SQL Editor** du dashboard, ou en CLI :

```powershell
supabase db query --remote=pqnauwlwyrqftgywgoxi --read-only "select current_database(), version()"
```

Attendu : une ligne avec `postgres` et la version du moteur.

Contrôle complet du schéma :

```sql
select
  (select count(*) from pg_tables where schemaname='public')                     as tables,          -- 28
  (select count(*) from pg_policies where schemaname='public')                   as policies,        -- 84
  (select count(*) from pg_trigger t
     join pg_class c on c.oid=t.tgrelid
     join pg_namespace n on n.oid=c.relnamespace
    where not t.tgisinternal and n.nspname='public')                             as user_triggers,   -- 14
  (select count(*) from public.wilayas)                                          as wilayas,         -- 58
  (select count(*) from public.settings)                                         as settings,        -- 10
  (select count(*) from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public')                   as realtime_tables; -- 28
```

Mesures relevées sur le projet réel le 15 novembre 2026 : **28 / 84 / 14 / 58 / 10 / 28**.

---

## 2. Réappliquer le schéma (projet vide ou remis à zéro)

### Voie CLI (utilisée pour la mise en service)

```powershell
supabase db query --remote=pqnauwlwyrqftgywgoxi --yes --file ".\bootstrap_full.sql"
```

Le script est idempotent : il peut être relancé sans perte de données. Il se termine par un `select` de contrôle :

```json
{ "settings": 10, "status": "Bootstrap complet OK", "tables": 28, "wilayas": 58 }
```

`--yes` confirme l'écriture sur un projet hébergé. Sans ce drapeau, la CLI s'arrête en mode agent.

### Voie dashboard

**SQL Editor → New query** → coller l'intégralité de `bootstrap_full.sql` → **Run**. Même résultat attendu.

---

## 3. Configuration Auth

Réglages appliqués au projet :

| Réglage | Valeur | Raison |
|---|---|---|
| `mailer_autoconfirm` | `true` | Les comptes sont utilisables immédiatement, sans boîte e-mail de confirmation. |
| `disable_signup` | `false` | Les inscriptions restent ouvertes ; le rôle est de toute façon forcé à `confirmatrice`. |
| `external_email_enabled` | `true` | Connexion e-mail + mot de passe. |
| `site_url` | `https://chicluxuryy5-art.github.io/cod-team-app/` | URL publique actuelle. |
| `uri_allow_list` | fork + dépôt canonique + `http://localhost:8765/**` | Liens de confirmation / réinitialisation. |

### Changer l'URL publique après fusion sur le dépôt canonique

Dashboard → **Authentication → URL Configuration** :

- `Site URL` : `https://mrchiealgerie-hub.github.io/cod-team-app/`
- `Redirect URLs` : ajouter `https://mrchiealgerie-hub.github.io/cod-team-app/**`

L'URL du fork peut rester dans la liste tant qu'elle est utilisée.

### Désactiver l'auto-confirmation (optionnel)

Dashboard → **Authentication → Sign In / Providers → Email** → réactiver **Confirm email**. Les comptes existants restent confirmés ; seules les nouvelles inscriptions devront valider leur adresse.

---

## 4. Comptes et rôles

### 4.1 Inscription

Toute inscription libre passe par le trigger `handle_new_user`, qui insère un profil avec le rôle **`confirmatrice`**, quelles que soient les métadonnées envoyées. C'est le comportement attendu et vérifié sur le projet réel.

### 4.2 Premier administrateur

1. Créer le compte via l'écran d'inscription de l'application.
2. Le promouvoir dans le **SQL Editor** (ou en CLI) :

```sql
update public.profiles
   set role = 'admin'
 where id = (select id from auth.users where email = 'VOTRE_EMAIL');
```

Le SQL Editor s'exécute sans `auth.uid()` : le trigger anti-escalade ne bloque pas cette promotion. C'est le seul chemin prévu pour le premier admin.

Compte admin de test actuel : `test.admin@codteam.dz` (mot de passe communiqué séparément, **à changer avant usage réel**).

### 4.3 Autres membres

Créer chaque compte, puis renseigner rôle, coût horaire et WhatsApp :

```sql
update public.profiles p
   set role            = 'media_buyer',      -- admin | media_buyer | video_editor | confirmatrice | production | sourcing
       hourly_cost_dzd = 400,                -- coût horaire réel en DZD
       whatsapp_phone  = '+213XXXXXXXXX'
 where p.id = (select id from auth.users u where u.email = 'prenom@exemple.dz');
```

Un utilisateur non-admin ne peut modifier ni son rôle, ni son statut actif, ni sa rémunération : le trigger `protect_profile_privileges` réécrit ces colonnes avec les anciennes valeurs.

### 4.4 Fermer les inscriptions (optionnel)

Une fois l'équipe créée : **Authentication → Sign In / Providers** → désactiver les inscriptions. Le rôle minimal reste `confirmatrice` même si elles restent ouvertes.

---

## 5. Isolation RLS — résultats mesurés

Test réalisé le 15 novembre 2026 avec un vrai compte `confirmatrice` et son jeton utilisateur (jamais avec `service_role`) :

| Test | Résultat |
|---|---|
| Inscription libre | profil créé avec `role = confirmatrice` |
| `PATCH profiles { role: admin }` sur son propre profil | HTTP 200 mais rôle **inchangé** (`confirmatrice`) — trigger anti-escalade |
| `GET comp_runs` | **0 ligne** (aucune rémunération d'autrui visible) |
| `POST comp_runs` | **403** — `new row violates row-level security policy` |
| `POST products` | **403** |
| `PATCH settings` | **200 avec 0 ligne modifiée** — valeur `usd_to_dzd` restée à 260 |
| `POST orders` | **201** — création autorisée |
| `PATCH orders { status: confirmed }` | **200** — mise à jour autorisée |
| `GET time_entries` | **0 ligne** |

L'interface applique la même logique : une confirmatrice ne voit que Accueil, Temps, Timesheet, Compensation, Commandes COD, Clients 360°, WhatsApp CRM et Mes tâches. Les modules CFO, Pipeline, Produits, Équipe, Wilayas et Paramètres ne sont pas affichés.

---

## 6. Mettre à jour les clés dans le front

Les deux constantes se trouvent lignes 183–184 de `index.html` :

```js
var SUPABASE_URL='https://pqnauwlwyrqftgywgoxi.supabase.co';
var SUPABASE_ANON_KEY='eyJ...';
```

Après modification :

1. téléverser `index.html` sur `main` (voir `DEPLOIEMENT_GITHUB.md`) ;
2. attendre la reconstruction GitHub Pages ;
3. forcer le rechargement (**Ctrl + Shift + R**) ;
4. vérifier taille, hash et présence de la nouvelle référence.

---

## 7. Vérifier le déploiement du front

```powershell
(Get-Item .\index.html).Length
(Get-FileHash .\index.html -Algorithm SHA256).Hash

$u = "https://chicluxuryy5-art.github.io/cod-team-app/?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 30
"HTTP $($r.StatusCode) - $($r.RawContentLength) octets"
"nouveau Supabase : $($r.Content -match 'pqnauwlwyrqftgywgoxi')"
```

Attendu : **392 463 octets**, hash `9F3C86663C95E99F10E008A22AB9A126219D4B859D3D6590D7117CEB5E0648D3`, `nouveau Supabase : True`.

---

## 8. Recréer un projet de zéro (si nécessaire)

1. **New project** : nom `cod-team`, mot de passe fort conservé hors dépôt, région `eu-west-3`.
2. Attendre le statut `ACTIVE_HEALTHY`.
3. **Project Settings → API** : copier `Project URL` et la clé `anon`.
4. Appliquer `bootstrap_full.sql` (§ 2).
5. Configurer Auth (§ 3).
6. Mettre à jour `index.html` (§ 6), puis redéployer.
7. Créer le premier admin (§ 4.2).
8. Relancer les contrôles (§ 1 et § 7).

> Un projet supprimé emporte ses données. Les données de cette archive sont fictives ou absentes ; aucune donnée réelle n'est stockée dans le dépôt Git.

---

## 9. Sécurité — à faire avant usage réel

| Point | Action |
|---|---|
| Compte `test.admin@codteam.dz` | Changer le mot de passe ou supprimer le compte |
| Clé `service_role` | Ne jamais la mettre dans `index.html`, le dépôt ou un navigateur |
| `relay_token` / `relay_url` | Stockés dans `settings`, lisibles par tout utilisateur authentifié : jeton dédié, à renouveler si le relais est abandonné |
| Inscriptions | Fermer après création de l'équipe, ou garder le rôle minimal `confirmatrice` |
| Mot de passe base de données | Conservé hors dépôt (gestionnaire de mots de passe) |
| Relais Baileys | Non officiel : numéro dédié, risque de suspension |
| Données personnelles | Les exports CSV/PDF peuvent en contenir : ne pas les committer |

---

## 10. Checklist de reprise

- [x] Projet Supabase actif (`pqnauwlwyrqftgywgoxi`, `ACTIVE_HEALTHY`)
- [x] `bootstrap_full.sql` appliqué : 28 tables, 84 politiques, 58 wilayas, 10 réglages
- [x] Realtime publié sur 28 tables
- [x] Auto-confirmation e-mail activée
- [x] `index.html` rebranché et publié sur GitHub Pages
- [x] Connexion admin testée sur l'URL publique
- [x] Inscription confirmatrice et isolation RLS vérifiées
- [ ] Fusion du fork dans `mrchiealgerie-hub/cod-team-app`
- [ ] Pages activé sur le dépôt canonique (si souhaité) + `site_url` mis à jour
- [ ] Comptes réels de l'équipe créés (rôle, coût horaire, WhatsApp)
- [ ] Mot de passe du compte de test changé
- [ ] Inscriptions fermées (si équipe stabilisée)
- [ ] Relais WhatsApp configuré uniquement si nécessaire (sinon mode manuel `wa.me`)

---

*Guide d'exploitation et de reprise — COD Team v15. Les valeurs « attendues » ont été mesurées sur le projet réel et sur le banc de test local.*
