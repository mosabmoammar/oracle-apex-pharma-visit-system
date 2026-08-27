# Pharma Visit System — APEX Application Build Guide

Application 100 · `Pharma Visit System` · Theme 42 (Universal Theme) · APEX 23.2+

This document specifies the application to be built in App Builder. It is the
input to the build, and the reference for reviewing the exported result.

---

## 1. Application definition

| Setting | Value | Why |
|---|---|---|
| Application ID | 100 | Fixed, so export paths stay stable across environments |
| Parsing schema | `PVS` | |
| Authentication | Custom — `pkg_apex.authenticate` / `pkg_apex.post_authenticate` | Context must be established before any page renders |
| Error handling function | `pkg_apex.error_handler` | One handler, bilingual, no internal detail reaches the browser |
| Application language derived from | Application preference | Lets `apex_util.set_session_lang` drive both chrome and layout direction |
| Primary language | English | Arabic served from the same application, not a translated copy |
| Compatibility mode | 23.2 | |
| Debug | Disabled in production build | |
| Friendly URLs | Yes | |

### Application items

| Item | Scope | Purpose |
|---|---|---|
| `G_USER_ID` | Application | Populated in post-authentication |
| `G_ROLE` | Application | Highest role, for conditional UI |
| `G_LANG` | Application | `en` / `ar` |
| `G_DIRECTION` | Application | `pkg_apex.current_direction`, bound to the page template |
| `G_PERIOD_ID` | Application | Current open period, computed once per session |

### Application processes

| Process | Point | Code |
|---|---|---|
| Initialise Security Context | On New Instance | `pkg_apex.post_authenticate;` |
| Resolve Current Period | On New Instance | sets `G_PERIOD_ID` from `PERIODS` where status is `OPEN` |
| Re-assert Context | Before Header (all pages, condition: `SYS_CONTEXT('CTX_PVS','USER_ID')` is null) | Guards against context loss after a connection pool reset — a subtle failure that only appears under load |

> The last one matters. APEX runs on a shared connection pool; a session
> context set at login is not guaranteed to be present on a later request
> served by a different physical session. Re-asserting cheaply is the
> difference between "works in dev" and "works".

### Authorization schemes

| Scheme | Type | Evaluation |
|---|---|---|
| Is Representative | PL/SQL: `return pkg_security.has_role('REP') = 'Y';` | Once per session |
| Is Supervisor | PL/SQL: `return pkg_security.has_role('SUPERVISOR') = 'Y';` | Once per session |
| Is Manager | PL/SQL: `return pkg_security.is_privileged;` | Once per session |
| Can Approve | PL/SQL: supervisor OR privileged | Once per session |

---

## 2. Right-to-left support

1. Page template: bind `dir="&G_DIRECTION."` on the `<html>` element.
2. Universal Theme ships RTL stylesheets; they activate when the session
   language is Arabic — no custom mirrored CSS is needed for layout.
3. Custom CSS uses logical properties (`margin-inline-start`, not
   `margin-left`), so one stylesheet serves both directions.
4. Numbers, dates and charts stay LTR inside an RTL page — do not force
   direction on numeric columns.
5. Test both directions on every page before export. RTL defects are almost
   always in custom CSS and hand-written HTML, never in native components.

Language switch: a navigation bar entry calling
`pkg_apex.switch_language('ar')` / `('en')`, then redirect to the same page.

---

## 3. Page inventory

### Global

| Page | Name | Auth | Notes |
|---|---|---|---|
| 1 | Home / Dashboard router | Authenticated | Redirects by role to 10, 11 or 12 |
| 9999 | Login | Public | Custom authentication |
| 90 | Language & Preferences | Authenticated | Calls `pkg_apex.switch_language` |

### Representative

| Page | Name | Type | Key components |
|---|---|---|---|
| 10 | My Dashboard | Cards + charts | Source `V_DASH_REP_KPI`; KPI cards: coverage, visits, samples, achievement; bar chart by product |
| 20 | My Plan | Interactive Grid | Source `PLAN_ITEMS` via editable IG, **but** all DML routed to `PKG_PLAN` through a custom process — never the built-in IG DML |
| 21 | Plan Calendar | Calendar region | Same source, read-only view of the month |
| 22 | Submit Plan | Process page | `pkg_plan.submit(:P22_PLAN_ID)` |
| 30 | Record Visit | Form | Process calls `pkg_apex.page_execute_visit`; outcome LOV from `V_LOV_DOMAIN` |
| 31 | Visit Samples | Modal + IG | `pkg_apex.page_dispense_sample`; dynamic action shows `remaining_for_display` on doctor/product change |
| 40 | My Samples | Interactive Report | `V_SEC_SAMPLE_BALANCES`; highlight rows where `EXPIRING_SOON = 'Y'` |
| 41 | Sample Ledger | Interactive Report | Movement history, faceted by type and date |

### Supervisor

| Page | Name | Type | Key components |
|---|---|---|---|
| 11 | Team Dashboard | Charts | Team coverage, pending approvals count, exception count |
| 50 | Pending Approvals | Interactive Report | `V_SEC_PLANS` where status `SUBMITTED` |
| 51 | Review Plan | Read-only IG + buttons | `pkg_plan.approve` / `pkg_plan.reject`; rejection reason is mandatory at the page level *and* in the package |
| 52 | Change Requests | Interactive Report + modal | `pkg_plan.decide_change` |
| 53 | Sample Exceptions | Form | Insert into `SAMPLE_EXCEPTIONS` with reason and approver |

### Manager

| Page | Name | Type | Key components |
|---|---|---|---|
| 12 | Regional Performance | Charts + IR | `V_DASH_REGION_PERFORMANCE`; drill-down region → rep → visit |
| 60 | Targets | Interactive Grid | `pkg_target.set_target`; "Copy from previous period" button → `pkg_target.copy_targets` |
| 61 | Achievement | Interactive Report | `V_SEC_ACHIEVEMENT` with conditional formatting on `ACHIEVEMENT_PCT` |
| 62 | Visit Explorer | Faceted Search | `V_SEC_VISITS`; facets: period, region, tier, outcome, product |
| 63 | Period Close | Process page | `pkg_plan.close_period_plans` + `pkg_target.calculate_achievement` |

### Administration

| Page | Name | Type |
|---|---|---|
| 70 | Users & Roles | IG on `APP_USERS`, `USER_ROLES` |
| 71 | Doctors | IG with bilingual name columns side by side |
| 72 | Facilities & Regions | IG + tree |
| 73 | Products, Batches & Ceilings | Master-detail-detail |
| 74 | Data Load | APEX Data Loading wizard for doctors and facilities |
| 80 | Audit Trail | IR on `V_SEC_AUDIT`, faceted by table, action, user, date |

---

## 4. Component rules for this application

**Interactive Grids never write directly.** Editable IGs are configured with
their built-in DML disabled; a page process iterates
`apex_application.g_f01` style arrays (or the IG's own change collection) and
calls the package. It is more work than checking "Enable DML", and it is the
only way the same rule protects the UI and the API.

**Every LOV is a shared component sourced from a view** — `V_LOV_DOMAIN`,
`V_LOV_PRODUCTS`, `V_LOV_DOCTORS`. No page contains a static LOV with
hard-coded English strings, because that is where bilingual support silently
breaks.

**Faceted search over interactive report filters** on high-volume pages
(62, 41): faceted search pushes predicates into the query rather than
filtering a fetched set.

**Charts use aggregate sources, never row-level queries.** Page 12 reads the
materialized view; it does not aggregate 20,000 visits on render.

**Validations exist on pages for user experience only.** Every one of them is
duplicated in the package, because the page validation is a convenience and
the package validation is the guarantee.

---

## 5. Export and version control

Build in the workspace, then export split:

```bash
sql pvs/****@localhost:1521/xepdb1

SQL> apex export -applicationid 100 -split -dir ./apex -skipExportDate -expType APPLICATION_SOURCE
```

Committed structure:

```
apex/f100/
├── install.sql
├── application/
│   ├── create_application.sql
│   ├── pages/            p00001.sql … p00080.sql
│   ├── shared_components/
│   │   ├── navigation/
│   │   ├── logic/        (application processes, items, computations)
│   │   ├── security/     (authentication, authorization schemes)
│   │   └── user_interface/
│   └── end_environment.sql
└── readme.md
```

`-skipExportDate` is not cosmetic: without it every export differs in the
timestamp line, producing a commit on every export even when nothing changed.

### What must never be committed

- Workspace credentials, client secrets, `user_ords_clients` output
- `f100.sql` unsplit (a 40,000-line file no one can review)
- Any real data export

---

## 6. Definition of done for the application layer

1. Every page renders correctly in both `en` and `ar`, including RTL layout.
2. No page performs DML except through a package call.
3. Removing a role from a user immediately removes the corresponding
   navigation entries and blocks direct URL access to those pages.
4. Page 62 returns its first page of results in under 2 seconds against the
   seeded dataset.
5. The dispensing rule is demonstrated failing identically on page 31 and on
   `POST /v1/samples/dispense` — same error code, same message, different
   channel.
