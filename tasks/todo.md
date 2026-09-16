# ArcPay — état de reprise

Plan de référence : `~/.claude/plans/serialized-jumping-walrus.md`

## Objectif

Rendre ArcPay soumissible aux Arc Microgrants (20 × 500 USDC, deadline 2026-10-14 23:59 ET,
portail DoraHacks `dorahacks.io/hackathon/arc-microgrants`) : argument Arc-natif vrai et
vérifiable, contrat déployé et vivant sur Arc Mainnet (chain 5042), frontend qui exécute
réellement le contrat, repo public.

## Critères de DONE

- [ ] Aucune occurrence de « 6 decimals » appliquée au gas natif d'Arc dans le code ou les docs
- [ ] Aucune référence à `arcscan.app` (domaine mort) — remplacé par `explorer.arc.io`
- [ ] `forge test` vert, incluant un test de fork qui prouve la relation 18/6 contre Arc Mainnet
- [ ] Contrat déployé sur Arc Mainnet, `eth_getCode` non vide
- [ ] `getServiceCount() >= 3` et `services(1).totalCalls >= 1` après amorçage
- [ ] Frontend qui encode un vrai appel `payForService` (plus de virement nu)
- [ ] Repo public poussé, sans aucun secret dans l'historique
- [ ] Frontend en ligne, URL ouvrable
- [ ] Revue indépendante = PASS

## Faits mesurés (socle, ne pas re-dériver)

| Fait | Valeur |
|---|---|
| Chain ID Arc | 5042 (0x13b2) |
| Décimales natif (`msg.value`, `balance`) | **18** |
| Predeploy USDC ERC-20 | `0x3600000000000000000000000000000000000000`, **6** décimales |
| Relation | `floor(natif / 1e12) == balanceOf` — vérifié sur 5 adresses |
| Explorateur | `https://explorer.arc.io` (`arcscan.app` est mort, HTTP 000) |
| RPC | `https://rpc.mainnet.arc.io` (+ secours drpc / quicknode) |
| Coût déploiement | 2 739 408 gas ≈ 0,106 USDC |
| Tréso Polygon | 19,810342 pUSD + 3,697921 USDC.e (proxy `0x226afa…eec3`), 16,6368 POL (EOA `0x1064…647b`) |

## Tâches

- [ ] Lot 1 — contrat : `ArcDecimals.sol` + dénomination 18 déc. dans `ArcAgentGateway.sol`
- [ ] Lot 2 — tests : mise à jour 18 déc. + round-trip + test de fork
- [ ] Lot 3 — scripts : `deploy.mjs`, `check-balance.mjs`
- [ ] Lot 4 — frontend : décimales, vrai calldata, registre on-chain, panneau de preuve
- [ ] Lot 5 — docs : `README.md`, `SUBMISSION.md` au format BUIDL
- [ ] Lot 6 — financement : nouveau wallet + bridge Relay
- [ ] Lot 7 — déploiement + amorçage
- [ ] Lot 8 — publication git + Vercel
- [ ] Lot 9 — soumission DoraHacks (avec Alex, irréversible)

## Décisions prises

- Repositionnement sur l'insight dual-decimals 18/6 plutôt que patch mécanique (choix opérateur).
- Nouveau wallet dédié, clé au trousseau macOS `arc-grant-wallet`, jamais dans le dépôt.
- Route de financement : wrap USDC.e → pUSD, puis un seul bridge Relay pUSD → Arc.
- Écarté définitivement : bridger les 16,6 POL (ne rapporte que 1,17 USDC et supprime le gaz Polygon).
- Écarté définitivement : route USDC.e directe vers Arc (aucune route, `NO_SWAP_ROUTES_FOUND`).

## Prochaine action exacte

Lot 1 : écrire `contracts/src/ArcDecimals.sol` puis corriger `contracts/src/ArcAgentGateway.sol`.
