# Changelog — COD Team

Historique des versions livrées. Les dates correspondent aux commits du dépôt.

---

## 15 novembre 2026 — Remise en service complète (Supabase + GitHub Pages)

- Création du projet Supabase `cod-team` (`pqnauwlwyrqftgywgoxi`, org `bghhtoeptsxaejfrttbk`, région `eu-west-3`), statut `ACTIVE_HEALTHY`.
- Application de `bootstrap_full.sql` par CLI : **28 tables, 84 politiques RLS, 14 déclencheurs utilisateur, 58 wilayas, 10 réglages**, 28 tables publiées en Realtime.
- Auth configurée : auto-confirmation e-mail active, `site_url` sur le fork publié, URL autorisées pour le fork, le dépôt canonique et le serveur local.
- `index.html` rebranché sur `https://pqnauwlwyrqftgywgoxi.supabase.co` — **392 463 octets**, SHA-256 `9F3C86663C95E99F10E008A22AB9A126219D4B859D3D6590D7117CEB5E0648D3`.
- Publication immédiate via le fork `chicluxuryy5-art/cod-team-app` et GitHub Pages : <https://chicluxuryy5-art.github.io/cod-team-app/> (HTTP 200).
- Vérifications sur le site public : connexion admin, navigation complète, table Wilayas à **58 lignes**, Stock SKU et Tests A/B opérationnels.
- Test réel d'inscription : rôle forcé `confirmatrice` ; interface limitée aux modules autorisés ; auto-promotion admin neutralisée par trigger.
- Test d'isolation RLS : `comp_runs` en lecture = 0 ligne, écriture = 403 ; `products` = 403 ; `settings` inchangé ; `orders` création et mise à jour = 201/200.
- Documentation actualisée : `README.md`, `DEPLOIEMENT_GITHUB.md`, `RECOVERY_SUPABASE.md`, `CHANGELOG.md`.
- Pull request **#1** ouverte du fork vers le dépôt canonique : <https://github.com/mrchiealgerie-hub/cod-team-app/pull/1> (aucun conflit, fusion à valider par le propriétaire).
- Reste à faire : fusion de la PR #1, création des comptes réels, changement du mot de passe de test.

## 15 novembre 2026 — Protocole de test Twenty Cloud

- Ajout de `TWENTY_CLOUD_TEST.md` : périmètre, protocole en 60–90 minutes, grille de décision sur 40 points.
- Ajout de `twenty-test-orders.csv` : 30 commandes fictives pour tester l'import (aucune donnée réelle).
- Constat : Twenty Cloud ne propose plus de plan gratuit permanent — essai de 30 jours, puis 9 $/utilisateur/mois en Pro ou 39 $ en Organization, facturation annuelle.
- Le plan Pro ne fournit que les rôles Admin et Member ; les permissions fines restent assurées par COD Team (RLS Supabase).

## 14 novembre 2026 — Reconstruction du schéma et reprise Supabase

- Ajout de `bootstrap_base.sql` : les 14 tables de base absentes des migrations (profils, produits, commandes, KPI, etc.), avec RLS, triggers et réglages par défaut.
- Ajout de `bootstrap_full.sql` : schéma complet en un seul collage (base + v5 + v6 → v12), idempotent.
- Validation locale (PGlite + stubs Supabase) : 28 tables, 84 politiques RLS, 16 triggers, 58 wilayas, 10 réglages ; tests de comportement et seconde exécution sans erreur.
- Inscription : le formulaire envoie désormais explicitement `role: 'confirmatrice'` ; le trigger `handle_new_user` force ce rôle quoi qu'il arrive.
- Message d'erreur réseau clarifié sur tous les appels Supabase : les erreurs renvoyées dans un objet (et non levées) passent désormais par `friendlyErr`.
- Tests d'anti-escalade : un utilisateur ne peut pas modifier son rôle, son statut actif ni sa rémunération ; un admin peut promouvoir.
- Correction d'idempotence de la vue `wa_campaigns_with_progress` après l'ajout de `send_mode`.
- Ajout de `RECOVERY_SUPABASE.md` (reprise du projet, clés API, comptes, vérifications).
- Ajout de `DEPLOIEMENT_GITHUB.md` (état du déploiement, procédure de push, vérification du fichier servi).
- Constat : le projet Supabase `sfsnyppydvhvnjiqjgjt` est injoignable (NXDOMAIN, pause probable) ; reprise manuelle requise.

## v15 — 18 juin 2026

**Rémunération variable des confirmatrices**

- Calcul automatique mensuel : 80 % fixe + 20 % variable.
- 5 critères pondérés avec paliers.
- Migration `v12_migration.sql`.

## v14 — 17 juin 2026

**Time Management T1–T6**

- SLAs par type de tâche.
- Coût horaire et marge après main-d'œuvre.
- Capacity planning.
- Coaching insights.
- Minuteur Pomodoro.
- Timesheet et paie (export CSV / PDF).
- Migration `v11_migration.sql`.

## v13 — 17 juin 2026

**Time tracking**

- Suivi du temps style ClickUp.
- Auto-track pour les confirmatrices.
- Widget flottant.
- Migration `v10_migration.sql`.

## v12 — 16 juin 2026

**Navigation et accueil**

- Page d'accueil personnalisée par rôle.
- Barre de navigation mobile en bas d'écran.
- Sidebar repliable.

## v11.2 — 16 juin 2026

**Inbox WhatsApp**

- L'assistant détecte automatiquement le dernier message entrant.

## v11.1 — 16 juin 2026

**Inbox WhatsApp**

- Chat manuel.
- Suggestions de réponses en temps réel.

## v11 — 16 juin 2026

**Relais WhatsApp**

- Relais Baileys pour l'envoi automatisé des campagnes.
- Bascule `send_mode` côté front (manuel / relais).
- Migration `v9_migration.sql`.

## v10 — 16 juin 2026

**WhatsApp CRM**

- Campagnes broadcast via `wa.me`.
- Inbox et copilote de réponses.
- Migration `v8_migration.sql`.

## v9.6 — 16 juin 2026

**Clients 360°**

- Enrichissement de la fiche client.
- Taux de retour.
- Segmentation risque.

## Modules v5 → v8

- **v5** — Wilayas (58), stock SKU, mouvements, top 5 stratégique.
- **v6** — Tests A/B des créations vidéo.
- **v7** — Notifications WhatsApp.
- **v8** — WhatsApp CRM : campagnes, inbox, agent.

## 29 mai 2026 — Socle applicatif

- Création du dépôt et publication de l'application `index.html`.
- Pipeline 11 étapes, scoring produit, sourcing ateliers, tests pubs, paramètres.
- Correction du bug de connexion « missing email or phone ».
- Ajout de `.nojekyll` pour GitHub Pages.

## 19 juin 2026 — Packages complémentaires

- Ajout de `twenty-deploy/` : package Twenty CRM self-host (Docker / Railway).

---

## Notes

- Le schéma de base complet est désormais fourni : `bootstrap_base.sql` (14 tables) puis les migrations `v5` → `v12`. `bootstrap_full.sql` regroupe l'ensemble.
- Les documents stratégiques (audits, étude ClickUp, landing) sont livrés séparément.
