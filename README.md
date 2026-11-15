# COD Team — CRM & Ops pour e-commerce COD (Algérie)

**Version 15** — archive consolidée du 15 novembre 2026.

Application web interne pour piloter une opération e-commerce en paiement à la livraison (COD) : pipeline produit, sourcing ateliers, tests publicitaires, production, commandes et confirmation, stock, finances, WhatsApp et gestion du temps.

---

## Accès

| Élément | Valeur |
|---|---|
| Application en ligne | https://chicluxuryy5-art.github.io/cod-team-app/ |
| Dépôt publié (fork) | https://github.com/chicluxuryy5-art/cod-team-app |
| Dépôt canonique | https://github.com/mrchiealgerie-hub/cod-team-app (à fusionner) |
| Projet Supabase | `pqnauwlwyrqftgywgoxi` |
| URL Supabase | `https://pqnauwlwyrqftgywgoxi.supabase.co` |
| Compte admin de test | `test.admin@codteam.dz` |

> Le mot de passe du compte de test n'est pas stocké dans cette archive. Il a été communiqué séparément. **Changez-le avant tout usage réel.**

> Le site public actuel est servi depuis le fork `chicluxuryy5-art/cod-team-app`, car le compte GitHub disponible n'a pas le droit d'écriture sur le dépôt canonique. La pull request **#1** est ouverte et sans conflit : le propriétaire doit la fusionner. Procédure dans `DEPLOIEMENT_GITHUB.md`.

---

## Contenu de l'archive

```text
cod-team-FINAL-v15/
├── index.html                  Application complète (mono-fichier, v15)
├── .nojekyll                   Nécessaire pour GitHub Pages
├── README.md                   Ce document
├── CHANGELOG.md                Historique des versions
├── RECOVERY_SUPABASE.md        Reprise du projet Supabase pas à pas
├── DEPLOIEMENT_GITHUB.md       État du déploiement et procédure de push
├── TWENTY_CLOUD_TEST.md        Protocole de test Twenty Cloud + grille de décision
├── twenty-test-orders.csv      30 commandes fictives pour le test d'import
├── bootstrap_full.sql          Tout le schéma en un seul collage (recommandé)
├── bootstrap_base.sql          Socle de base : 14 tables, RLS, triggers, seeds
├── migrations_combined.sql     Migrations v6 → v12 (à exécuter après v5)
├── v5_migration.sql            Wilayas, stock, top 5 stratégique
├── v6_migration.sql            Tests A/B créas
├── v7_migration.sql            Notifications WhatsApp
├── v8_migration.sql            WhatsApp CRM (broadcasts, inbox, agent)
├── v9_migration.sql            Support relais Baileys
├── v10_migration.sql           Time tracking
├── v11_migration.sql           Time management T1–T6
├── v12_migration.sql           Rémunération variable confirmatrices
├── wacrm-relay/                Relais WhatsApp Baileys (optionnel)
└── twenty-deploy/              Package Twenty CRM self-host (optionnel)
```

---

## Architecture

- **Front-end** : un seul fichier `index.html` (HTML/CSS/JavaScript), bibliothèque `@supabase/supabase-js` chargée par CDN. Interface bilingue français / arabe avec RTL natif.
- **Back-end** : Supabase — PostgreSQL, Auth, Row Level Security (RLS), Realtime et Storage. Le bucket public `media` est provisionné par le bootstrap ; la v15 du front ne l'utilise pas encore (les vidéos et créas sont référencées par URL).
- **Hébergement** : GitHub Pages (statique). Aucun serveur applicatif à maintenir.
- **Temps réel** : les données sont partagées entre les utilisateurs via Supabase Realtime.
- **WhatsApp** : envoi manuel via `wa.me` par défaut ; relais Baileys optionnel pour l'envoi automatisé.
- **PDF** : génération côté navigateur avec `html2pdf`.

---

## Mise en route

### 1. Appliquer le schéma SQL

**Voie recommandée — un seul collage.** Dans **Supabase → SQL Editor → New query**, coller l'intégralité de `bootstrap_full.sql`, puis **Run**. Le script contient, dans l'ordre :

1. le socle de base (`bootstrap_base.sql`) : 14 tables, RLS, triggers, réglages ;
2. la migration v5 : wilayas, stock, top 5 ;
3. les migrations v6 → v12.

Il est idempotent : réexécutable sans perte de données. Il se termine par `Bootstrap complet OK` avec `tables = 28`, `wilayas = 58`, `settings = 10`.

**Voie détaillée** — exécuter dans cet ordre :

1. `bootstrap_base.sql`
2. `v5_migration.sql`
3. `migrations_combined.sql` (ou `v6_migration.sql` à `v12_migration.sql` un par un)

Chaque script se termine par un `select '... OK'` : vérifiez le message de retour avant de passer au suivant.

> Sur une base de production existante, `bootstrap_base.sql` ne recrée pas les tables (`if not exists`) et ne supprime aucune donnée. Il recrée toutefois les politiques RLS et les triggers : relisez-le avant de l'exécuter sur une base déjà en service.

### 2. Créer les comptes de l'équipe

1. **Inscription via l'application** ou **Supabase → Authentication → Users → Add user**.
2. Toute inscription libre est forcée au rôle `confirmatrice` par le trigger `handle_new_user` : les métadonnées de rôle envoyées par le formulaire sont ignorées.
3. Promouvoir le premier admin dans le **SQL Editor** :

```sql
update public.profiles
   set role = 'admin'
 where id = (select id from auth.users where email = 'VOTRE_EMAIL');
```

4. Renseigner ensuite, pour chaque membre, `role`, `hourly_cost_dzd` et `whatsapp_phone` dans `profiles`.
5. Rôles disponibles : `admin`, `media_buyer`, `video_editor`, `confirmatrice`, `production`, `sourcing`.

Les droits fins sont appliqués par les politiques RLS. Seul un administrateur peut promouvoir un compte : un utilisateur ne peut pas modifier son propre rôle, son statut actif ni sa rémunération.

La procédure complète de reprise (projet en pause, clés API, confirmation d'e-mail, vérifications) est décrite dans `RECOVERY_SUPABASE.md`.

### 3. Déployer le front

Le fichier `index.html` doit rester à la racine du dépôt, accompagné de `.nojekyll`.

- Un `push` sur la branche `main` déclenche la publication GitHub Pages en 1 à 2 minutes.
- Après une mise à jour, forcer le rechargement : **Ctrl + Shift + R** (le cache du navigateur est agressif).

L'application peut aussi être hébergée sur n'importe quel hébergeur statique (Netlify, Cloudflare Pages, Vercel…).

> L'état exact du déploiement au 15 novembre 2026, le fork et la procédure de fusion sont documentés dans `DEPLOIEMENT_GITHUB.md`.

### 4. Configuration

- La clé `anon` / publishable est déjà présente dans `index.html`. Elle est publique par conception : la sécurité repose sur les politiques RLS.
- **Ne jamais exposer la clé `service_role`** dans le front ou dans le dépôt.
- WhatsApp : le mode `manual` ouvre `wa.me` avec le message pré-rempli. Le mode relais nécessite de déployer `wacrm-relay/` et de renseigner son URL.

---

## Modules

| Module | Fonction |
|---|---|
| Accueil | Tableau de bord adapté au rôle de l'utilisateur |
| Mes tâches | Tâches assignées, priorités et échéances |
| Pipeline | 12 étapes, du sourcing au scaling |
| Produits | Fiches produit, coûts, marges, scoring |
| Recherche produit | Tableur de prospection et d'évaluation |
| Validation admin | File de validation des produits |
| Sourcing ateliers | Fournisseurs, échantillons, négociation |
| Tests pubs | Suivi Meta / TikTok / Snap / Google |
| Tests A/B créas | Comparaison des créations vidéo |
| Production | Suivi de fabrication et réassort |
| Vidéos | Bibliothèque et statut des montages |
| Commandes COD | File d'appels, statuts, historique client |
| Clients 360° | LTV, taux de retour, segmentation risque |
| Stock SKU | Mouvements, seuils, inventaire |
| Wilayas | 58 wilayas, zones et tarifs de livraison |
| WhatsApp CRM | Campagnes, inbox, réponses assistées |
| Performance / KPI | Dépenses, revenus, ROAS, CPA |
| Équipe | Annuaire, rôles et charge |
| Temps | Suivi du temps, SLAs, capacité |
| Timesheet | Feuilles de temps et paie |
| Compensation | Part variable des confirmatrices (80/20) |
| Cockpit CFO | Prévision de trésorerie à 30 jours |
| Rapport hebdo | Synthèse PDF / e-mail / impression |
| Blacklist | Clients à risque (anti-fraude) |
| Corbeille | Restauration des éléments supprimés |
| Paramètres | Configuration de l'espace de travail |

---

## Rôles et navigation

| Rôle | Usage principal |
|---|---|
| Admin | Accès complet, validation, paramètres, équipe |
| Media buyer | Tests pubs, créas, campagnes WhatsApp |
| Monteur | Vidéos et tests A/B créas |
| Confirmatrice | Commandes, clients, WhatsApp, temps, compensation |
| Atelier | Production et stock |
| Recherche | Recherche produit et sourcing |

La navigation affichée s'adapte automatiquement au rôle connecté.

---

## Twenty CRM (option)

Twenty est testé comme **CRM commercial complémentaire**, pas comme remplacement du back-office. Le protocole complet, la grille de décision et le jeu de données fictif sont dans `TWENTY_CLOUD_TEST.md` et `twenty-test-orders.csv`.

À retenir : le Cloud n'a plus de plan gratuit permanent — c'est un essai de 30 jours, puis 9 $/utilisateur/mois (Pro) ou 39 $/utilisateur/mois (Organization), en facturation annuelle. Le plan Pro ne gère que les rôles Admin et Member : les permissions fines par rôle restent dans COD Team via RLS.

---

## Données et sécurité

- Les données de démonstration sont fictives ou absentes : la base actuelle ne contient que le compte admin de test, aucun produit ni commande.
- Les données réelles vivent dans Supabase, pas dans le dépôt Git.
- La clé `anon` du front est publique ; les politiques RLS limitent les lectures et écritures selon le rôle.
- Les exports CSV/PDF peuvent contenir des données personnelles : ne pas les committer.

### Checklist de sécurité avant mise en production

1. **Trigger d'inscription** : `bootstrap_base.sql` crée le trigger `handle_new_user` sur `auth.users`, qui force le rôle `confirmatrice`. Vérifier sa présence après bootstrap :
   ```sql
   select tgname from pg_trigger
    where tgrelid = 'auth.users'::regclass and not tgisinternal;
   ```
2. **RLS** : les 84 politiques sont créées par le bootstrap. Vérifier que toutes les tables sont en `row level security` et que les politiques correspondent aux rôles attendus.
3. **Compte de test** : changer le mot de passe de `test.admin@codteam.dz` ou supprimer le compte.
4. **Clés** : la clé `service_role` ne doit jamais apparaître dans `index.html`, dans le dépôt ou dans un navigateur.
5. **Inscriptions** : si l'équipe est fermée, désactiver les inscriptions libres dans Supabase Auth après avoir créé les comptes.
6. **Relais WhatsApp** : `relay_token` et `relay_url` sont stockés dans `settings`, lisibles par tout utilisateur authentifié. Utiliser un jeton dédié et le renouveler en cas d'abandon du relais.

---

## Limites connues

- **Migrations** : exécuter `bootstrap_full.sql` sur un projet neuf, ou `v5` → `v12` sur une base existante. Sans ces scripts, les modules Stock, Wilayas, Tests A/B, WhatsApp, Temps et Compensation restent partiellement inactifs.
- **Projet Supabase** : le projet actif est `pqnauwlwyrqftgywgoxi` (statut `ACTIVE_HEALTHY` au 15 novembre 2026). L'ancien projet `sfsnyppydvhvnjiqjgjt` est abandonné. Voir `RECOVERY_SUPABASE.md` pour l'exploitation et la reprise.
- **Dépôt canonique** : le site public est servi depuis le fork ; la fusion dans `mrchiealgerie-hub/cod-team-app` reste à faire par le propriétaire.
- **WhatsApp** : l'envoi manuel `wa.me` est la voie officielle et sûre. Le relais Baileys est **non officiel** et peut entraîner une suspension du numéro ; à utiliser avec un numéro dédié.
- **IA WhatsApp** : les suggestions aident l'agent, mais l'envoi reste une action humaine.
- **PDF** : la qualité dépend du navigateur et de la bibliothèque `html2pdf`.

---

## Dépannage

| Symptôme | Piste |
|---|---|
| « missing email or phone » à la connexion | Forcer le rechargement (Ctrl + Shift + R) ; le bug est corrigé depuis la v4 |
| Un module apparaît vide | Vérifier que la migration correspondante a bien été exécutée |
| Les données ne se mettent pas à jour en temps réel | Vérifier que la table est publiée dans `supabase_realtime` |
| GitHub Pages affiche l'ancienne version | Attendre 1–2 min, vider le cache, vérifier le dernier commit |
| Le PDF ne se génère pas | Vérifier que `html2pdf` est accessible (CDN) |

---

## Documents liés

Les documents stratégiques (audit stratégique Vol. I et II, étude comparative ClickUp, landing page) ont été livrés séparément. Ils ne font pas partie de cette archive, qui contient uniquement l'application et ses composants techniques.

---

*COD Team — outil interne. Les chiffres affichés dépendent des données saisies dans Supabase.*
