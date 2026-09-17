# DoraHacks BUIDL — exact form state

Every value entered in the DoraHacks BUIDL wizard, recorded so the browser tab holding the draft
is not a single point of failure. The draft is reachable only through that open tab — "Create
BUIDL" opens a blank wizard and there is no edit page until the BUIDL exists as a project — so if
the tab is lost, this file plus the linked assets rebuild it in full.

## Step 1 — Profile

| Field | Value |
|---|---|
| BUIDL (project) name | `ArcPay — Agentic Micro-Payment & Escrow Gateway` |
| BUIDL logo | [`buidl-logo.png`](buidl-logo.png) — 480x480 (the slot centre-crops anything wider) |
| Vision | the one-line pitch from [`../SUBMISSION.md`](../SUBMISSION.md) |
| Category | **Crypto / Web3** |
| Key innovation domains | free-text chips: `agentic payments`, `micro-payments`, `escrow`, `infrastructure` |
| Layer-1s/L1s | free-text chip: `Arc` |
| GitHub | `https://github.com/elzuzu/otter-arc` |
| Project website | `https://elzuzu.github.io/otter-arc/` |
| Demo video | empty |
| Social link 1 | `https://github.com/elzuzu` |

Both chip fields read "Select or input" and accept free text: type the value and press Enter to
commit it as a new chip. An empty dropdown showing "No available options" is a filtered list before
typing, not a closed taxonomy — `Arc` is absent from the L1 list but is accepted as free text.

## Step 2 — Details

One required markdown field, 6,689 characters: the Description, "What it uses Arc for", "How to
verify the claims" and "What we would do next" sections of [`../SUBMISSION.md`](../SUBMISSION.md),
concatenated. Use the **old editor** (raw markdown textarea) rather than the WYSIWYG default so the
markdown is stored literally.

## Step 3 — Team

`Team information`, 1,565 characters: [`buidl-team-information.txt`](buidl-team-information.txt)
verbatim. "Invite new members" left empty.

## Step 4 — Contact

Alex's own details, not recorded here.

| Field | Format |
|---|---|
| Telegram (primary) | username **without** the `@` — the prefix is rendered outside the input |
| Backup contact | pick exactly one: Discord username, WhatsApp `+123456789`, or WeChat ID |

Then "I agree to the Terms of Use Agreement", then **Submit for Review**.

## The hackathon entry form (separate from the wizard)

Reached from the hackathon page: Submit BUIDL -> Use existing BUIDL -> ArcPay. Track is
`All BUIDLs`, the only option. Its questions are answered from
[`../SUBMISSION.md`](../SUBMISSION.md), with one exception.

**"What does it use Arc for?" is capped at 960 characters**, and the cap is enforced only on
submit -- the input declares no `maxLength`, so an over-long answer types in fine and is rejected
at the end. The section in `SUBMISSION.md` runs to 1,930 characters, so the form carries a
939-character condensation kept verbatim in
[`buidl-arc-usage-960.txt`](buidl-arc-usage-960.txt). The escrow paragraph was dropped rather than
trimmed everywhere: it is the least Arc-specific of the five, and the question asks what the
project uses *Arc* for. `SUBMISSION.md` keeps the full answer.

Two dropdowns worth reading carefully: "Had you deployed to Arc before this project?" offers
**Mainnet / Testnet / No** -- it is not a yes/no -- and there is a separate Circle/Arc grant
question.

## Two traps on this form

**The contact fields are not enforced client-side.** `required` is false on the Telegram input, the
red asterisk is a decorative sibling, and the submit button goes live as soon as a backup *channel*
is selected — before anything is typed into it. The form will not stop a submission with empty
contact details. Server behaviour is unknown and untested. Since the banner states these details
are how DoraHacks staff contact the builder, fill them for real.

**Submitting here does not enter the hackathon.** See "How to actually submit" in
[`../SUBMISSION.md`](../SUBMISSION.md).
