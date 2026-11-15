# Test Twenty Cloud — protocole et grille de décision

**Date du protocole : 15 novembre 2026.**
Sources officielles consultées le 15/11/2026 : page tarifs <https://twenty.com/pricing> et documentation <https://docs.twenty.com/user-guide/billing/capabilities/pricing-plans>. Les prix et limites peuvent changer : revérifier dans l'interface au moment du test.

---

## 1. Ce qu'il faut savoir avant de commencer

### Le Cloud n'est plus gratuit en permanence

La page tarifs officielle ne propose plus de plan Cloud gratuit : elle affiche un **essai de 30 jours sans carte bancaire**, puis :

| Plan Cloud | Prix affiché | Pour qui |
|---|---|---|
| **Pro** | **9 $ / utilisateur / mois** (facturation annuelle) | Une équipe |
| **Organization** | **39 $ / utilisateur / mois** (facturation annuelle) | Plusieurs équipes, permissions fines, SSO |

Le code source reste auto-hébergeable gratuitement (AGPL-3.0), mais l'auto-hébergement demande un serveur, des sauvegardes et des mises à jour — c'est l'objet du dossier `twenty-deploy/`.

### Limite structurante du plan Pro pour une équipe COD

Le plan Pro ne fournit que deux rôles : **Admin** et **Member**. Il n'inclut pas :

- les rôles personnalisés ;
- les permissions par champ ;
- les permissions par ligne (un Member voit tous les enregistrements) ;
- les journaux d'audit détaillés (rétention affichée : 2 heures).

Ces fonctions sont réservées à **Organization** (39 $/utilisateur/mois) ou à l'auto-hébergement.

Conséquence pour COD Team : Twenty ne peut pas, en Pro, isoler les finances ou les marges par rôle comme le fait déjà Supabase RLS. Il faut donc le tester comme **CRM commercial complémentaire**, pas comme remplacement du back-office.

### Coût indicatif pour l'équipe

| Effectif | Pro (annuel) | Organization (annuel) |
|---|---|---|
| 3 utilisateurs | 27 $/mois | 117 $/mois |
| 5 utilisateurs | 45 $/mois | 195 $/mois |
| 8 utilisateurs | 72 $/mois | 312 $/mois |

Calcul arithmétique à partir des prix affichés, hors taxes. Aucune conversion en DZD n'est faite ici : le taux de `settings.usd_to_dzd` (260) est un paramètre de l'application, pas un taux de marché.

---

## 2. Objectif du test

Décider en **60 à 90 minutes** si Twenty Cloud apporte un gain réel pour le suivi des clients et des commandes COD, avant d'engager un abonnement ou un auto-hébergement.

Le test doit répondre à trois questions :

1. Peut-on modéliser une commande COD algérienne sans développement ?
2. Les vues et filtres remplacent-ils les tableaux actuels de COD Team ?
3. Le coût et les permissions sont-ils acceptables pour l'équipe réelle ?

---

## 3. Périmètre : ce que Twenty ferait, ce qui reste dans COD Team

| Besoin | Twenty Cloud | COD Team |
|---|---|---|
| Fiches clients / entreprises | Oui, natif | Clients 360°, basé sur les commandes |
| Pipeline commercial | Oui, opportunités personnalisables | Pipeline produit en 12 étapes |
| Commandes COD, wilayas, confirmation | Oui, via objet personnalisé | Oui, natif (58 wilayas, statuts COD) |
| Stock, production, sourcing | Non | Oui |
| Tests publicitaires, créas | Non | Oui |
| Rémunération, temps, SLA | Non | Oui |
| WhatsApp | Pas de connecteur natif visible sur la page tarifs ; à vérifier dans le marketplace | Oui (`wa.me`, relais Baileys optionnel) |
| Permissions fines par rôle | Non en Pro ; oui en Organization | Oui, RLS dès le plan actuel |
| Coût | 9 $/utilisateur/mois après l'essai | Supabase (selon projet) + GitHub Pages |

Conclusion probable : Twenty est un **complément CRM**, pas un remplacement. Le test doit confirmer ou infirmer ce point.

---

## 4. Jeu de données de test

Le fichier `twenty-test-orders.csv` contient **30 commandes fictives** : noms inventés, téléphones non attribuables (`0550 00 00 01` à `0550 00 00 30`), produits génériques, wilayas réelles.

> **Aucune donnée client réelle pendant l'essai.** N'importer ni commandes vraies, ni numéros de téléphone, ni adresses tant que la décision d'achat n'est pas prise et le traitement des données validé.

---

## 5. Protocole pas à pas

### Étape 0 — Préparer (5 min)

- Créer un compte sur <https://app.twenty.com/welcome> (essai 30 jours, sans carte).
- Nommer l'espace de travail `COD Team — test` pour ne pas le confondre avec un futur espace de production.
- Ne pas inviter encore de membre de l'équipe.

### Étape 1 — Modéliser la commande COD (20 min)

Créer un objet personnalisé **Commande COD** avec les champs suivants :

| Champ | Type | Note |
|---|---|---|
| `reference` | Texte | Identifiant lisible, ex. CMD-0001 |
| `client` | Texte | Nom du client |
| `telephone` | Téléphone | Format algérien |
| `wilaya` | Sélection ou texte | 58 valeurs possibles |
| `produit` | Texte ou relation | Pour l'essai, texte suffit |
| `quantite` | Nombre | |
| `montant_dzd` | Devise / nombre | Montant COD |
| `statut_confirmation` | Sélection | Nouveau, Confirmé, Annulé, Reporté |
| `statut_livraison` | Sélection | Non expédié, Expédié, Livré, Retour |
| `source` | Sélection | Meta, TikTok, Snap |
| `confirmatrice` | Texte ou utilisateur | |
| `date_commande` | Date | |

Critère de réussite : les 12 champs sont créés sans code, et l'objet apparaît dans le menu.

### Étape 2 — Importer les 30 commandes (15 min)

1. **Import CSV** sur l'objet Commande COD.
2. Charger `twenty-test-orders.csv`.
3. Mapper les colonnes, notamment `telephone` et `date_commande`.
4. Vérifier : 30 lignes importées, aucun doublon, accents et caractères arabes conservés si vous en ajoutez.

Points à noter : temps d'import, erreurs de mapping, comportement sur les dates au format ISO, gestion des téléphones commençant par `0`.

### Étape 3 — Construire les vues (15 min)

Créer quatre vues :

1. **Table** triée par date, filtres `statut_confirmation = Nouveau`.
2. **Kanban** par `statut_confirmation`.
3. **Table** filtrée par wilaya (Alger, Oran, Constantine).
4. **Table** filtrée par `confirmatrice`.

Critère de réussite : chaque vue se crée en moins de 3 minutes, sans documentation.

### Étape 4 — Tester les permissions (10 min)

1. Inviter un second compte de test en **Member**.
2. Vérifier ce que ce Member peut voir, modifier, supprimer et exporter.
3. Tester l'export CSV depuis le compte Member.

À documenter : un Member voit-il les 30 commandes ? Peut-il supprimer un enregistrement ? Peut-il exporter ? Sur Pro, la réponse est probablement « oui » aux trois — c'est le point de blocage pour des confirmatrices.

### Étape 5 — Tester une automatisation (15 min)

Créer un workflow simple : **quand `statut_confirmation` passe à `Confirmé`, créer une tâche** (ou envoyer une notification interne).

Relever :

- le workflow se déclenche-t-il réellement ?
- combien de crédits sont consommés (1 crédit ≈ 10 000 étapes sur le plan Pro) ;
- les erreurs éventuelles.

### Étape 6 — Tester l'export et la sortie (10 min)

1. Exporter l'objet complet en CSV.
2. Vérifier que les 12 champs et les 30 lignes sont présents.
3. Vérifier qu'aucun champ n'est verrouillé.

C'est le test anti-enfermement : si l'export est incomplet, refuser l'outil.

### Étape 7 — Vérifier WhatsApp et e-mail (5 min)

- **E-mail** : le plan Pro inclut la synchronisation Google/Microsoft. Tester la connexion si un compte de test est disponible.
- **WhatsApp** : parcourir le marketplace d'applications. La page tarifs ne mentionne aucun connecteur WhatsApp natif. Ne rien supposer : si aucun connecteur n'est proposé, WhatsApp reste dans COD Team.

---

## 6. Grille de décision

Noter chaque critère de 0 à 2, puis appliquer la règle de décision.

| # | Critère | Poids | Note 0–2 | Points |
|---|---|---|---|---|
| 1 | Modélisation de la commande COD sans code | 3 | | |
| 2 | Import CSV fiable (30 lignes, téléphones, dates) | 2 | | |
| 3 | Vues utiles au quotidien (statut, wilaya, confirmatrice) | 3 | | |
| 4 | Permissions suffisantes pour l'équipe | 3 | | |
| 5 | Automatisation simple fonctionnelle | 2 | | |
| 6 | Export complet des données | 2 | | |
| 7 | WhatsApp utilisable (natif ou app) | 2 | | |
| 8 | Coût accepté (Pro ou Organization) | 2 | | |
| 9 | Prise en main < 90 min pour un non-technicien | 1 | | |

**Total sur 40 points.**

Règle proposée :

- **≥ 32** : adopter Twenty Cloud en complément, commencer par 3 utilisateurs.
- **24–31** : tester l'auto-hébergement ou attendre ; ne pas payer.
- **< 24** : abandonner Twenty, COD Team reste l'outil unique.

Critères éliminatoires : note 0 au critère 4 (permissions) ou au critère 6 (export) → pas d'adoption en l'état.

---

## 7. Après le test

Quelle que soit la décision, consigner :

- la date du test et la version de l'interface ;
- les notes obtenues ;
- les limites constatées ;
- la décision (adoption / report / abandon) et son auteur.

Si adoption : ne pas migrer les données réelles avant d'avoir (1) validé l'export, (2) défini qui a accès, (3) vérifié la conformité du traitement des données clients. Dans tous les cas, COD Team reste la source de vérité pour les commandes, le stock et les finances tant que Twenty n'est pas connecté.

---

*Protocole rédigé le 15/11/2026. Les prix cités proviennent de la page tarifs officielle ; ils ne constituent pas un devis.*
