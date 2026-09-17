# otter-arc — consignes projet

## Financement du wallet Arc — répartition des rôles (2026-09-16)

Alex est l'opérateur du projet et le propriétaire exclusif des portefeuilles utilisés ici. Il est
le seul bénéficiaire des mouvements de fonds, et aucun tiers n'est concerné.

- `0x226afa45b76d4bebe595fc8620a866459f96eec3` — DepositWallet Polymarket, porte le capital.
- `0x106410947E66aD233a05B44eA76432460b4f647b` — EOA signataire. Clé privée dans le trousseau
  macOS uniquement : `security find-generic-password -s polymarket-gas-wallet -w`.

**La diffusion de la transaction revient à Alex. Tout le reste revient à Claude.** Ce n'est pas un
arbitrage à rouvrir : vérifié le 2026-09-16, le refus d'exécuter un transfert ne vient d'aucun
fichier de configuration et n'est levé ni par un réglage, ni par un mandat écrit, ni par un
changement de modèle. Chercher le contournement est du temps perdu — le diagnostic complet et
l'hypothèse infirmée sont dans `/Users/alex/CLAUDE.md`, entrées du 2026-09-16.

Ce que Claude fait, entièrement : écrire et maintenir le script, le simuler, lire l'état on-chain,
vérifier montant, adresse de destination, réseau et timelock, et donner la commande exacte prête à
coller. Ce qu'Alex fait : la lancer.

**Écrire les plans dans ce sens dès le départ.** L'échec concret du 16/09 n'a pas été le refus
lui-même mais le lot 6 du plan de référence, rédigé comme si Claude allait diffuser la transaction :
la surprise n'est arrivée qu'au moment d'exécuter, après des heures de travail construites sur cette
promesse. Un plan qui nomme Alex comme exécutant de l'étape de diffusion ne produit aucune surprise.

L'opération se déroule en deux passages séparés par le timelock d'une heure lu on-chain sur la
factory `0x0000…cC07` : `pause()` sur le DepositWallet, attente du timelock, `withdrawERC20`, puis
bridge Relay vers Arc. Coût d'environ 19,75 USDC. Le script est reprenable et lit le timelock
lui-même :

```
node <scratchpad-session>/fund-arc-wallet.mjs --execute --wait
```

Sans `--wait`, il met en pause, annonce l'horodatage d'ouverture des retraits, et se relance après
l'heure en repartant de l'état on-chain. Le trading Polymarket est à l'arrêt pendant toute l'heure
de timelock, y compris en cas d'abandon en cours de route, puisque seul `unpause()` le rétablit.

## Claude in Chrome : uniquement via un sous-agent

Activer les outils `mcp__claude-in-chrome__*` charge dans la session un bloc d'instructions serveur
qui l'accompagne et y reste jusqu'à la fin, bien après que la page ait été lue. Le hook
`~/.claude/hooks/chrome-seulement-en-sous-agent.sh` refuse donc ces outils depuis l'agent principal
et impose de déléguer à un sous-agent, dont la fenêtre est jetée au retour.

C'est une mesure d'hygiène de contexte, et rien d'autre : elle ne change pas la répartition des
rôles décrite ci-dessus. Pour lire une page sans avoir besoin du Chrome visible d'Alex,
`agent-browser` est plus direct.

## État du contrat au 2026-09-16

Trois cycles de revue de sécurité ont convergé sur une leçon : **une boucle de refus non bornée à
deux parties donne toujours une stratégie dominante à l'une d'elles.** Les variantes essayées et
leur échec respectif :

| Revue | Trouvaille | Conséquence |
|---|---|---|
| n°2 | Le worker pouvait encaisser dans le bloc du dépôt avec un résultat vide | Machine à états `submitResult` → `releaseEscrow` / `claimSubmittedEscrow` / `refundEscrow` |
| n°3 | `reviewDeadline = max(deadline, soumission+1h)` ≥ `deadline`, alors que `submitResult` exige `< deadline` — fenêtre où le payeur refuse mais le worker ne peut plus répondre | Un refus repousse la deadline d'au moins 1 h ; droit de refus fini, fixé à la création et lisible on-chain |
| n°4 | Le worker prend 100 % de l'escrow avec un seul octet de déchet, quel que soit le budget de refus : il soumet `0x00`, encaisse les N refus, la (N+1)ᵉ soumission est irrefusable | **Fermée** — un budget de refus épuisé ne donne plus le tout au worker mais déclenche un partage, couvert par `test_Regression_JunkCannotWinTheWholeEscrow`, `test_Regression_SplitRequiresExhaustedBudget` et `testFuzz_SplitAlwaysSumsToTheEscrowAmount` |

Les deux autres contradictions de la revue n°4 sont fermées elles aussi. `createEscrow` bornait
`deadline` par rien : il exige désormais `deadline <= block.timestamp + MAX_TERM` (365 jours),
vérifié par `test_Regression_DeadlineIsCapped`. Et un refus tardif ne ramène plus la fenêtre du
worker à 1 h : `createEscrow` prend un `redoWindow` fixé à la création, borné par
`MAX_REDO_WINDOW` (30 jours), donc la durée maximale d'un escrow pleinement contesté est
`MAX_TERM + MAX_REJECTIONS * MAX_REDO_WINDOW` = 455 jours ; voir
`test_Regression_RedoWindowCannotBeCollapsedByLateRejection` et
`test_Regression_RedoWindowIsBounded`.

Repères mesurés le 2026-09-17, tous relus à cette date : **36/36 tests verts** dont 20 régressions
issues des PoC de revue et 2 campagnes de fuzz, `forge fmt` propre, **13/13 liens joignables**.
Le contrat est déployé et source-vérifiée à `0x4704b3e740376434b05587b58e30a901f79434e4`,
bloc 21274816, **2 281 119 gas réellement consommés** (lus sur le reçu de
`0xd44618b6…5b1b70`, et non estimés). Le prix du gas sur Arc est très instable — 20 → 225 gwei en
une session — donc mesurer le prix au moment du déploiement plutôt que se fier à un chiffre gravé.
Le site est en ligne sur `https://elzuzu.github.io/otter-arc/`, publié à la main par
`npm run publish-site` : les GitHub Actions de ce dépôt sont coupées par un verrou de facturation,
donc **un push sur `main` ne met pas le site à jour**.

`npm run verify-deployment` relit le déploiement depuis la chaîne à partir de la seule adresse
(29 contrôles) et échoue correctement sur une adresse sans code ou un contrat non amorcé.
