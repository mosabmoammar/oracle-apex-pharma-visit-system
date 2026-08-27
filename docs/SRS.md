# Software Requirements Specification — Pharma Visit System

**Medical Visit & Sample Management System**
Built on Oracle Database 19c+ and Oracle APEX

| | |
|---|---|
| Document version | 1.0 |
| Status | Baseline |
| Author | Mosab N. R. Abumoammar |
| Last updated | 2026-08-25 |

> **Note:** Pharma Visit System is an original demonstration system built from scratch. All data used in this repository is synthetic. It is not derived from, and contains no artefacts of, any client system.

---

## 1. Introduction

### 1.1 Purpose
This document specifies the functional and non-functional requirements of **Pharma Visit System**, an enterprise application that manages the full working cycle of medical sales representatives: planning visits to physicians, executing and recording those visits, dispensing drug samples under controlled limits, and measuring achievement against assigned targets.

### 1.2 Intended audience
Development team, database designers, reviewers and evaluators of the codebase.

### 1.3 Problem statement
Field visit activity is commonly tracked in spreadsheets and paper logs. This produces four recurring problems:

1. **No conflict control** — the same representative is recorded in two places at the same time.
2. **Uncontrolled sample dispensing** — no enforced ceiling per physician and no reliable stock balance, creating both compliance and cost exposure.
3. **Late and manual reporting** — achievement against target is calculated after month end, when it is too late to act.
4. **No access boundaries** — every user can see every record; there is no enforced separation between teams.

Pharma Visit System addresses these by moving the rules into the database layer, where they cannot be bypassed by any client.

### 1.4 Definitions

| Term | Meaning |
|---|---|
| Representative (Rep) | Field user who visits physicians |
| Supervisor | Manages a team of representatives within one or more regions |
| Visit plan | A monthly set of planned visits requiring approval before execution |
| Sample | A promotional drug unit dispensed to a physician, tracked by batch |
| Target | A quota assigned to a representative for a product over a period |
| Coverage | Percentage of planned visits actually executed |

---

## 2. Overall description

### 2.1 Product perspective
Pharma Visit System is a standalone Oracle APEX application. Business logic resides in PL/SQL packages inside the database; the APEX application and the ORDS REST layer are two consumers of the same logic, so a mobile client cannot bypass any rule enforced for web users.

```
   APEX UI  ─┐
             ├─►  PL/SQL API packages  ─►  Tables / Views
   ORDS REST ┘        (all business rules)
```

### 2.2 User roles

| Role | Scope of data | Key capabilities |
|---|---|---|
| `REP` | Own records only | Create plans, record visits, dispense samples, view own performance |
| `SUPERVISOR` | Own team and regions | Approve plans, authorise exceptions, monitor team dashboards |
| `SALES_MANAGER` | All regions | Set targets, manage products, access all reports |
| `SYS_ADMIN` | System-wide | Users, roles, reference data, audit review |

### 2.3 Operating environment
- Oracle Database 19c or later (Oracle XE acceptable for the reference deployment)
- Oracle APEX 23.2 or later
- Oracle REST Data Services (ORDS)
- Browser: current versions of Chrome, Edge, Firefox

### 2.4 Assumptions and constraints
- One representative belongs to exactly one supervisor at any point in time.
- Planning is monthly; the planning period is a calendar month.
- Sample ceilings are defined per product per physician per month.
- All timestamps are stored in UTC and displayed in the application timezone.

### 2.5 Out of scope
Invoicing and accounting, human resources and payroll, the mobile client application itself (only its API is delivered), live GPS tracking, and integration with external ERP systems.

---

## 3. Functional requirements

Requirements are numbered `FR-<module>-<n>` and prioritised **M** (must), **S** (should), **C** (could).

### 3.1 Security and access control (SEC)

| ID | Requirement | Pri |
|---|---|---|
| FR-SEC-1 | The system shall authenticate users against an application user table with hashed credentials, and support account lock after repeated failed attempts. | M |
| FR-SEC-2 | The system shall assign each user one or more roles, and evaluate page and component access against APEX authorization schemes derived from those roles. | M |
| FR-SEC-3 | The system shall restrict data visibility so that a `REP` sees only own records, a `SUPERVISOR` sees own team, and `SALES_MANAGER` / `SYS_ADMIN` see all records. | M |
| FR-SEC-4 | Data scoping shall be enforced in a single central mechanism applied to all queries, not repeated per page. | M |
| FR-SEC-5 | The system shall record every insert, update and delete on operational tables in an audit log capturing user, action, table, record identifier, old and new values, and timestamp. | M |
| FR-SEC-6 | The system shall allow `SYS_ADMIN` to deactivate a user without deleting historical records attributed to that user. | M |

### 3.2 Reference data (REF)

| ID | Requirement | Pri |
|---|---|---|
| FR-REF-1 | The system shall maintain regions with a parent-child hierarchy (country → region → territory). | M |
| FR-REF-2 | The system shall maintain physicians with specialty, classification tier (A/B/C), primary facility and status. | M |
| FR-REF-3 | The system shall maintain facilities (hospital, clinic, pharmacy) with address and region assignment. | M |
| FR-REF-4 | The system shall maintain products with code, name, form, strength, active flag and default monthly sample ceiling per physician. | M |
| FR-REF-5 | The system shall prevent deletion of any reference record referenced by operational data, offering deactivation instead. | M |
| FR-REF-6 | The system shall support bulk upload of physicians and facilities from a spreadsheet with row-level validation and an error report. | S |

### 3.3 Assignment (ASG)

| ID | Requirement | Pri |
|---|---|---|
| FR-ASG-1 | The system shall assign each representative to a supervisor and to one or more territories for a defined effective period. | M |
| FR-ASG-2 | The system shall prevent overlapping active assignments of the same representative to conflicting supervisors. | M |
| FR-ASG-3 | The system shall retain assignment history so that historical records remain attributed to the structure in effect at the time. | S |

### 3.4 Visit planning (PLN)

| ID | Requirement | Pri |
|---|---|---|
| FR-PLN-1 | A representative shall create a monthly visit plan consisting of planned visits, each with physician, facility, planned date, planned time window and objective. | M |
| FR-PLN-2 | The system shall reject a planned visit that overlaps in time with another planned visit of the same representative. | M |
| FR-PLN-3 | The system shall submit a plan for supervisor approval, moving it through the states `DRAFT → SUBMITTED → APPROVED / REJECTED`. | M |
| FR-PLN-4 | An approved plan shall be locked; any subsequent change shall create a change request requiring supervisor approval. | M |
| FR-PLN-5 | The system shall warn when planned coverage of tier-A physicians falls below a configured minimum frequency for the month. | S |
| FR-PLN-6 | The system shall allow a supervisor to reject a plan with a mandatory reason, returning it to `DRAFT`. | M |
| FR-PLN-7 | The system shall allow copying the previous month's plan as a starting draft. | C |

### 3.5 Visit execution (VST)

| ID | Requirement | Pri |
|---|---|---|
| FR-VST-1 | A representative shall record the execution of a planned visit with actual start and end time, outcome, discussed products and free-text notes. | M |
| FR-VST-2 | The system shall permit recording an unplanned visit, flagged as such and requiring a reason. | M |
| FR-VST-3 | The system shall reject a visit recorded for a future date or with an end time earlier than its start time. | M |
| FR-VST-4 | The system shall reject overlapping executed visits for the same representative. | M |
| FR-VST-5 | The system shall support outcomes of `COMPLETED`, `NOT_AVAILABLE`, `POSTPONED` and `CANCELLED`, with a mandatory reason for the last three. | M |
| FR-VST-6 | The system shall prevent editing a visit after the monthly period is closed. | S |
| FR-VST-7 | The system shall allow attaching a follow-up action with a due date to any visit. | C |

### 3.6 Sample management (SMP)

| ID | Requirement | Pri |
|---|---|---|
| FR-SMP-1 | The system shall maintain a sample stock balance per representative, per product, per batch. | M |
| FR-SMP-2 | The system shall record stock movements of type `RECEIPT`, `DISPENSE`, `RETURN`, `ADJUSTMENT` and `EXPIRY_WRITE_OFF`, each linked to its source document. | M |
| FR-SMP-3 | The system shall reject a dispense that exceeds the representative's available balance for that product and batch. | M |
| FR-SMP-4 | The system shall reject a dispense that would exceed the configured monthly ceiling of that product for that physician. | M |
| FR-SMP-5 | The system shall reject dispensing of an expired batch or an inactive product. | M |
| FR-SMP-6 | The system shall allow a supervisor to authorise a documented exception to the physician ceiling, recorded with reason and approver. | S |
| FR-SMP-7 | The system shall compute the balance from movement history rather than storing a mutable balance column, and reconcile it in a nightly job. | M |
| FR-SMP-8 | The system shall list batches expiring within a configurable horizon and notify the holding representative. | S |

### 3.7 Targets and achievement (TGT)

| ID | Requirement | Pri |
|---|---|---|
| FR-TGT-1 | A sales manager shall assign targets per representative, per product, per period, with a target value and unit. | M |
| FR-TGT-2 | The system shall compute achievement as executed activity against target, refreshed on demand and on a scheduled basis. | M |
| FR-TGT-3 | The system shall compute visit coverage as executed visits divided by approved planned visits for the period. | M |
| FR-TGT-4 | The system shall prevent two overlapping targets for the same representative, product and period. | M |
| FR-TGT-5 | The system shall retain a monthly snapshot of achievement so that closed periods are not recalculated retroactively. | S |

### 3.8 Dashboards and reporting (RPT)

| ID | Requirement | Pri |
|---|---|---|
| FR-RPT-1 | The representative dashboard shall show plan status, coverage, visits this month, achievement versus target and sample balance. | M |
| FR-RPT-2 | The supervisor dashboard shall show team coverage, pending approvals, ceiling exceptions and per-representative comparison. | M |
| FR-RPT-3 | The manager dashboard shall show achievement by region, by product and by tier, with drill-down to representative and to individual visit. | M |
| FR-RPT-4 | All operational reports shall be exportable to Excel, and formal reports to PDF. | M |
| FR-RPT-5 | The system shall provide a faceted search over visits by date range, region, physician, product and outcome. | M |
| FR-RPT-6 | The system shall provide a physician profile view showing full visit and sample history for that physician. | S |
| FR-RPT-7 | The system shall e-mail a scheduled monthly summary to supervisors at period close. | C |

### 3.9 Integration (INT)

| ID | Requirement | Pri |
|---|---|---|
| FR-INT-1 | The system shall publish ORDS REST endpoints allowing an authorised mobile client to read the representative's approved plan and reference data. | M |
| FR-INT-2 | The system shall accept visit execution and sample dispensing through REST, applying exactly the same validations as the web application. | M |
| FR-INT-3 | REST endpoints shall be protected by OAuth2 client credentials and role-based privileges. | M |
| FR-INT-4 | REST responses shall use a consistent JSON envelope with status, data and error detail, and return standard HTTP status codes. | M |
| FR-INT-5 | The system shall accept a batch of offline-captured visits and process them idempotently using a client-supplied unique reference. | S |
| FR-INT-6 | The system shall expose a consumption endpoint for an external reporting tool over a read-only view. | C |

---

## 4. Business rules

Business rules are implemented once, in PL/SQL, and enforced for every channel.

| ID | Rule | Enforcement |
|---|---|---|
| BR-01 | A representative cannot have two overlapping visits, planned or executed. | Package validation + constraint on time range |
| BR-02 | An approved plan is immutable; changes require an approved change request. | State machine in `PKG_PLAN` |
| BR-03 | Dispensed quantity cannot exceed the representative's stock balance for the batch. | `PKG_SAMPLE.dispense` |
| BR-04 | Dispensed quantity cannot exceed the monthly ceiling for the product and physician, unless a supervisor exception exists. | `PKG_SAMPLE.dispense` |
| BR-05 | Expired batches and inactive products cannot be dispensed. | `PKG_SAMPLE.dispense` |
| BR-06 | A user reads only the rows within their hierarchical scope. | Central scoping function + secure views |
| BR-07 | Targets for the same representative, product and period cannot overlap. | Unique constraint + validation |
| BR-08 | Reference records in use are deactivated, never deleted. | Foreign keys + status column |
| BR-09 | Every operational change is written to the audit log with old and new values. | Compound triggers |
| BR-10 | A closed period cannot be modified. | Period status check in all write APIs |

---

## 5. Non-functional requirements

| ID | Category | Requirement |
|---|---|---|
| NFR-1 | Performance | Any interactive report shall return the first page within 2 seconds on a dataset of 100,000 visits and 500,000 sample movements. |
| NFR-2 | Performance | Dashboard aggregates shall be served from indexed views or materialized views refreshed on a schedule. |
| NFR-3 | Scalability | The data model shall support 200 representatives, 10,000 physicians and 5 years of history without redesign. |
| NFR-4 | Security | All dynamic SQL shall use bind variables; no user input is concatenated into SQL. |
| NFR-5 | Security | Passwords shall be stored as salted hashes; no credentials appear in source control. |
| NFR-6 | Reliability | Every write API shall be atomic — either the full operation and its audit entry commit, or nothing does. |
| NFR-7 | Maintainability | Business logic shall live in packages; APEX pages shall contain no business rules beyond calling those packages. |
| NFR-8 | Auditability | Audit records shall be immutable and retained for the life of the system. |
| NFR-9 | Usability | The interface shall be usable on tablet width and support Arabic and English labels. |
| NFR-10 | Portability | The entire schema and application shall be reproducible from scripts in this repository on a clean database. |

---

## 6. Use cases

### UC-01 — Submit monthly visit plan
**Actor:** Representative
**Precondition:** Period is open; representative has an active assignment.
1. Representative opens plan for the coming month.
2. Adds planned visits with physician, date and time window.
3. System validates each entry against BR-01 and coverage guidance (FR-PLN-5).
4. Representative submits the plan.
5. System sets status `SUBMITTED` and notifies the supervisor.

**Alternate 3a:** Overlap detected → system rejects the row and displays the conflicting visit.
**Postcondition:** Plan awaits approval and cannot be executed against.

### UC-02 — Approve or reject plan
**Actor:** Supervisor
1. Supervisor opens pending approvals.
2. Reviews plan summary: visit count, tier coverage, geographic spread.
3. Approves, or rejects with a mandatory reason.
4. System locks an approved plan (BR-02) and writes the decision to the audit log.

### UC-03 — Record visit and dispense samples
**Actor:** Representative
**Precondition:** Plan approved; period open.
1. Representative selects the planned visit and records actual times and outcome.
2. Adds discussed products and, optionally, dispensed samples with product, batch and quantity.
3. System validates BR-03, BR-04 and BR-05 for each sample line.
4. System writes the visit, the stock movements and the audit entries in a single transaction.

**Alternate 3a:** Ceiling exceeded → operation is rejected with the remaining allowance; representative may request a supervisor exception (FR-SMP-6).
**Postcondition:** Balance and achievement reflect the visit immediately.

### UC-04 — Review regional performance
**Actor:** Sales manager
1. Manager opens the regional dashboard for a period.
2. Reviews achievement and coverage by region, product and tier.
3. Drills down from region to representative to individual visit.
4. Exports the result to Excel or PDF.

### UC-05 — Synchronise offline visits
**Actor:** Mobile client (system actor)
1. Client authenticates via OAuth2 and posts a batch of captured visits.
2. System processes each item under the same validations as the web channel (FR-INT-2).
3. Duplicates are detected by client reference and ignored idempotently (FR-INT-5).
4. System returns a per-item result with accepted and rejected entries and reasons.

---

## 7. Data model overview

Detailed ERD is maintained in `docs/erd.png` and DDL in `db/tables/`.

| Entity | Purpose |
|---|---|
| `REGIONS` | Hierarchical geography |
| `APP_USERS` | Application accounts and status |
| `ROLES`, `USER_ROLES` | Role assignment |
| `REP_ASSIGNMENTS` | Representative ↔ supervisor ↔ territory over time |
| `FACILITIES` | Hospitals, clinics, pharmacies |
| `DOCTORS` | Physicians with specialty and tier |
| `PRODUCTS` | Products, sample ceilings, status |
| `PRODUCT_BATCHES` | Batch number and expiry date |
| `VISIT_PLANS`, `PLAN_ITEMS` | Monthly plan header and planned visits |
| `VISITS`, `VISIT_PRODUCTS` | Executed visits and discussed products |
| `SAMPLE_TRANSACTIONS` | All stock movements (balance derived) |
| `SAMPLE_EXCEPTIONS` | Approved ceiling exceptions |
| `TARGETS`, `ACHIEVEMENT_SNAPSHOT` | Quotas and monthly results |
| `PERIODS` | Open/closed accounting periods |
| `AUDIT_LOG` | Immutable change history |

---

## 8. PL/SQL package plan

| Package | Responsibility |
|---|---|
| `PKG_SECURITY` | Current user context, role checks, scoping predicate |
| `PKG_PLAN` | Plan lifecycle, overlap validation, approval, change requests |
| `PKG_VISIT` | Visit execution, validation, unplanned visit handling |
| `PKG_SAMPLE` | Stock movements, balance calculation, ceiling enforcement |
| `PKG_TARGET` | Target assignment, achievement and coverage calculation |
| `PKG_REPORT` | Aggregation routines and report pipelines |
| `PKG_API` | REST-facing façade returning JSON envelopes |
| `PKG_AUDIT` | Centralised audit writing |
| `PKG_UTIL` | Date, period and error-handling helpers |

---

## 9. Acceptance criteria

The system is accepted when all `M` requirements are implemented and the following hold:

1. Every rule in section 4 is demonstrated by a failing case and a passing case in `db/tests/`.
2. A clean database can be built end to end by running `install.sql`.
3. Seed data produces at least 3 regions, 12 representatives, 300 physicians and 20,000 visits, and dashboards meet NFR-1 against it.
4. The same dispensing rule is proven to be enforced through both the APEX page and the REST endpoint.
5. No credentials or real data exist anywhere in the repository history.

---

## 10. Traceability

| Business rule | Requirements | Implementation | Test |
|---|---|---|---|
| BR-01 | FR-PLN-2, FR-VST-4 | `PKG_PLAN`, `PKG_VISIT` | `t_overlap.sql` |
| BR-02 | FR-PLN-4 | `PKG_PLAN` | `t_plan_lock.sql` |
| BR-03, BR-04, BR-05 | FR-SMP-3..5 | `PKG_SAMPLE` | `t_dispense.sql` |
| BR-06 | FR-SEC-3, FR-SEC-4 | `PKG_SECURITY`, secure views | `t_scope.sql` |
| BR-07 | FR-TGT-4 | `PKG_TARGET` | `t_target.sql` |
| BR-09 | FR-SEC-5 | `PKG_AUDIT`, triggers | `t_audit.sql` |
| BR-10 | FR-VST-6, FR-TGT-5 | period check in write APIs | `t_period.sql` |
