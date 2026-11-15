# Déploiement GitHub Pages — état et procédure

**État au 15 novembre 2026.**

| Élément | Valeur |
|---|---|
| Fichier local | `index.html` — **392 463 octets** |
| SHA-256 local | `9F3C86663C95E99F10E008A22AB9A126219D4B859D3D6590D7117CEB5E0648D3` |
| Site publié (fork) | <https://chicluxuryy5-art.github.io/cod-team-app/> — **HTTP 200**, 392 463 octets |
| Dépôt publié | <https://github.com/chicluxuryy5-art/cod-team-app> (fork, branche `main`) |
| Dépôt canonique | <https://github.com/mrchiealgerie-hub/cod-team-app> — **non mis à jour** |
| Projet Supabase lié | `pqnauwlwyrqftgywgoxi` (région `eu-west-3`) |

Le site public sert bien la version rebranchée sur le nouveau projet Supabase : la constante `SUPABASE_URL` vaut `https://pqnauwlwyrqftgywgoxi.supabase.co`. Connexion admin testée sur l'URL publique.

## Pourquoi un fork ?

Le compte GitHub utilisé sur ce poste (`chicluxuryy5-art`) n'a pas le droit d'écriture sur le dépôt `mrchiealgerie-hub/cod-team-app` : la page de téléversement répond « Uploads are disabled. File uploads require push access to this repository. » Le fork permet une mise en ligne immédiate sans attendre la fusion.

Le dépôt canonique reste la cible finale. Une **pull request #1** est déjà ouverte depuis le fork : <https://github.com/mrchiealgerie-hub/cod-team-app/pull/1> — « No conflicts with base branch ». Le propriétaire n'a plus qu'à cliquer **Merge pull request**.

Deux voies pour aligner :

1. **Fusion de la PR #1** — le propriétaire ouvre <https://github.com/mrchiealgerie-hub/cod-team-app/pull/1> puis **Merge pull request** → **Confirm merge**.
2. **Invitation en Write** — <https://github.com/mrchiealgerie-hub/cod-team-app/settings/access> → **Add people** → `chicluxuryy5-art` → rôle **Write**. Le fork pourra alors être poussé directement sur le dépôt canonique.

Après fusion, GitHub Pages peut être activé sur le dépôt canonique (**Settings → Pages → Deploy from a branch → main / (root)**). Il faut alors mettre à jour l'URL autorisée dans Supabase Auth (voir `RECOVERY_SUPABASE.md`).

---

## Procédure de mise à jour du site (fork)

### Option A — Téléversement par l'interface GitHub (utilisée)

1. Ouvrir <https://github.com/chicluxuryy5-art/cod-team-app/upload/main>.
2. Glisser-déposer les fichiers depuis `cod-team-FINAL-v15/` :
   - `index.html` (obligatoire) ;
   - `.nojekyll` (si absent) ;
   - les scripts SQL (`bootstrap_full.sql`, `bootstrap_base.sql`, `migrations_combined.sql`, `v5` → `v12`) ;
   - les documents (`README.md`, `CHANGELOG.md`, `RECOVERY_SUPABASE.md`, `DEPLOIEMENT_GITHUB.md`, `TWENTY_CLOUD_TEST.md`, `twenty-test-orders.csv`).
3. Renseigner un message de commit explicite, puis **Commit changes** sur `main`.
4. Attendre 1 à 2 minutes ; GitHub Pages reconstruit le site.

### Option B — Push Git

```powershell
cd "C:\Users\pc\AppData\Local\Temp\opencode\cod-team\repo-git"
git add -A
git commit -m "mise a jour"
git push origin main
```

Le dépôt distant de ce clone est le fork. Un push sur `main` déclenche la publication Pages.

---

## Vérification après déploiement

```powershell
# Taille et hash locaux
(Get-Item .\index.html).Length
(Get-FileHash .\index.html -Algorithm SHA256).Hash

# Fichier réellement servi (contourne le cache)
$u = "https://chicluxuryy5-art.github.io/cod-team-app/?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 30
"HTTP $($r.StatusCode) - $($r.RawContentLength) octets"
"nouveau Supabase : $($r.Content -match 'pqnauwlwyrqftgywgoxi')"
```

Attendu : **HTTP 200**, **392 463 octets**, `nouveau Supabase : True`.

Si le site sert encore l'ancienne version :

1. vérifier le dernier commit sur `main` et l'onglet **Actions** (workflow Pages) ;
2. attendre 1 à 2 minutes ;
3. forcer le rechargement avec **Ctrl + Shift + R** ou ajouter `?v=2` à l'URL.

> Le cache GitHub Pages et le cache navigateur peuvent conserver l'ancien fichier quelques minutes. C'est ce qui a produit un premier test trompeur lors de la bascule : le fichier publié était l'ancienne version alors que le fichier local était correct.

---

## Ce que change cette version du front

- `SUPABASE_URL` et `SUPABASE_ANON_KEY` pointent vers le projet `pqnauwlwyrqftgywgoxi`.
- Inscription : sélecteur de rôle retiré ; le formulaire envoie `role: 'confirmatrice'`, et le trigger `handle_new_user` force ce rôle quoi qu'il arrive.
- Message d'erreur réseau clarifié sur les appels Supabase : « Serveur Supabase injoignable. Le projet est peut-être en pause - contactez l'administrateur. »
- Le reste de l'interface v15 est inchangé.

---

## Historique du blocage initial

L'ancien projet Supabase `sfsnyppydvhvnjiqjgjt` était inaccessible (403, NXDOMAIN). Un projet neuf a été créé sur le compte Supabase accessible, le schéma y a été appliqué, puis le front a été rebranché. Le détail de la reprise est dans `RECOVERY_SUPABASE.md`.
