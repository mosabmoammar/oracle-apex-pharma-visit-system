# Architecture Decision Record — Pharma Visit System

Each entry states the decision, the alternatives that were considered, and why
they were rejected. A decision recorded without its rejected alternative is
not a decision — it is a preference.

---

## ADR-01 — Business logic lives in PL/SQL packages, not in APEX pages

**Decision.** Every write goes through a package procedure. APEX page processes
and ORDS handlers are one-line calls with no rules in them.

**Rejected: rules in APEX validations and page processes.**
Faster to build, and it works until a second channel appears. The mobile client
would then need its own copy of every rule, and the two copies diverge on the
first change. Structural prevention beats disciplined duplication.

**Cost.** More code to write for simple screens; editable Interactive Grids
need custom DML processes instead of the built-in option.

---

## ADR-02 — Row scoping through an application context, not per-page predicates

**Decision.** `CTX_PVS` is populated at authentication; secure views filter
on `PKG_SECURITY.visible_rep_ids`. Pages select from views, never base tables.

**Rejected: a `WHERE rep_id = :APP_USER_ID` clause on each page.**
This is the single most common data-leak defect in APEX applications: it works
on twenty pages and fails on the twenty-first that someone added in a hurry.

**Rejected: VPD (`DBMS_RLS`).**
The correct tool, and more elegant — but Enterprise Edition only. This project
must run on XE, so the constraint is documented rather than assumed away.

---

## ADR-03 — Stored balances with a reconciliation job, not balances derived at read time

**Decision.** `SAMPLE_TRANSACTIONS` is the ledger of record.
`SAMPLE_BALANCES` is maintained inside the same transaction as each movement.
A nightly job verifies one against the other.

**Rejected: `SUM(quantity)` at read time.**
Perfectly correct, and perfectly unusable: every dispense would aggregate the
representative's full movement history, and every stock report would scan the
ledger.

**Rejected: a materialized view refreshed on commit.**
Fast-refresh restrictions make it fragile for this join shape, and the refresh
would sit inside the user's transaction.

**Cost.** Two places hold the same truth, so they can drift. Mitigated by the
reconciliation job — which **reports** and does not silently correct, because a
silent fix hides the defect that caused the drift.

---

## ADR-04 — Overlap prevention is a locking problem, not a constraint problem

**Decision.** `SELECT … FOR UPDATE` on the representative's row, then validate,
then insert.

**Rejected: a unique constraint.**
Oracle has no range-exclusion constraint; no combination of unique keys
expresses "no two intervals may overlap".

**Rejected: validate-then-insert without a lock.**
Two concurrent sessions both read before either writes; both pass; both insert.
This is the defect that only appears in production.

**Rejected: `SERIALIZABLE` isolation.**
Correct, but it converts the race into `ORA-08177` for the user to handle, and
serialises far more than the one representative involved.

---

## ADR-05 — Bilingual columns for reference data, not a translation table

**Decision.** `_EN` / `_AR` column pairs, resolved by `PKG_I18N.label`.

**Rejected: a generic `TRANSLATIONS(table, column, lang, text)` table.**
It scales to any number of languages — which this system does not need. The
cost is a join on every reference lookup, the loss of `NOT NULL` on the name
itself, and index shapes that no longer cover the query.

**Reversal condition.** If the language set becomes open-ended, this decision
inverts. It is written down so the trigger for revisiting it is explicit.

---

## ADR-06 — One application serving both languages, not a translated APEX application

**Decision.** A single application; `APEX_UTIL.SET_SESSION_LANG` switches
language; Text Messages carry UI strings.

**Rejected: APEX Translated Application.**
The native mechanism, and the right one for a stable product. It requires
seeding and publishing a translated copy after every change — acceptable at
release cadence, a permanent tax during active development.

---

## ADR-07 — Audit triggers generated from the data dictionary

**Decision.** `PKG_AUDIT.generate` builds each trigger body from
`USER_TAB_COLUMNS`; row images are stored as JSON in one table.

**Rejected: hand-written triggers per table.**
Sixteen tables means sixteen opportunities for a silently wrong column list,
and every schema change means editing a trigger by hand.

**Rejected: auditing every table.**
`SAMPLE_TRANSACTIONS` is append-only by design; auditing it doubles every
write and adds no evidence that the ledger does not already hold.

**Cost.** Dynamic SQL that must be regenerated after schema changes — one call,
and it is part of the install script.

---

## ADR-08 — Authentication delegated to APEX, identity kept locally

**Decision.** `APEX_UTIL.IS_LOGIN_PASSWORD_VALID` verifies credentials.
`APP_USERS` stores identity, status and role links — never a password hash.

**Rejected: a custom credential table with salted hashes.**
It looks like a demonstration of security skill and is the opposite: hashing
choices age, and a project that stores credentials must then defend rotation,
lockout, reset and breach handling. The most secure credential store is the
one you did not build.

---

## ADR-09 — Idempotency through a unique constraint, not an application check

**Decision.** Offline clients supply `client_ref`; a unique constraint enforces
single application; a replay returns the original result.

**Rejected: "check whether it already exists, then insert".**
Two retries arriving together both find nothing and both insert. A constraint
cannot be raced; a check can.

**Consequence.** Sync handlers must translate `DUP_VAL_ON_INDEX` into a
`DUPLICATE` verdict rather than an error — which is what the per-item result
envelope is for.

---

## ADR-10 — Per-item savepoints in batch sync, not all-or-nothing

**Decision.** Each item in a sync batch runs inside a savepoint and receives
its own verdict; the response is `207` when any item is rejected.

**Rejected: reject the whole batch on the first failure.**
Simpler, and unusable for a representative who has been offline for two days:
one malformed item would discard forty-nine valid visits, and the client has no
way to know which one to fix.

**Cost.** A partially applied batch is a state the client must reason about —
so the response tells it exactly which items landed, which were duplicates,
and which failed and why.
