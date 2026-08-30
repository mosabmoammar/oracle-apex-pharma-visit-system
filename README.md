# Pharma Visit System

**Medical visit & drug-sample management system — Oracle Database + Oracle APEX**

A bilingual (Arabic / English) enterprise application that manages the working
cycle of medical sales representatives: monthly visit planning with supervisor
approval, visit execution, controlled sample dispensing, and achievement
measurement against targets — with the business rules enforced inside the
database rather than in the interface.

Built end to end: requirements → data model → PL/SQL API → APEX application →
REST layer → tests.

Tested on **Windows 10 / 11**.

> **Status:** Database layer verified on Oracle 26ai Free — clean install, 0 invalid objects, 20/20 business-rule tests passing. Schema, PL/SQL packages, seed data and
> the business-rule test suite install and pass. The APEX application layer is
> being built from the specification in `docs/apex-build-guide.md`; the export
> in `apex/f100/` is published once the first working version is done.


---

## Reviewing this in five minutes

If you only have a few minutes, these four files show what the project is:

| Look at | To see |
|---|---|
| [`db/install/04_pkg_sample.sql`](db/install/04_pkg_sample.sql) | Business logic under concurrency — the ceiling rule, the balance lock, idempotent replay |
| [`db/tests/10_tests.sql`](db/tests/10_tests.sql) | Every rule proved with **both** a negative and a positive case |
| [`docs/erd.md`](docs/erd.md) | The data model, and the reasoning behind each modelling decision |
| [`docs/adr.md`](docs/adr.md) | Ten architectural decisions, each with the alternative that was rejected and why |

---

## The problem

Field visit activity is typically tracked in spreadsheets. Four failures follow:

- the same representative is recorded in two places at the same time
- sample dispensing has no enforced ceiling per physician and no reliable stock balance
- achievement against target is known only after month end, too late to act on
- everyone can see everyone's data

Pharma Visit System moves all four rules into the database, where no client — web, mobile
or script — can bypass them.

---

## Architecture

```
   APEX application  ─┐
                      ├──►  PL/SQL API packages  ──►  Tables · Views · Ledger
   ORDS REST (mobile) ─┘         all business rules
```

One implementation of every rule. The mobile client and the web application do
not share code by convention — they share it structurally, because neither can
write to a table directly.

| Layer | Contents |
|---|---|
| Data | 19 tables, temporal assignments, append-only sample ledger, generic JSON audit |
| Logic | 9 packages — security, i18n, plan, visit, sample, target, audit, APEX support, REST façade |
| Presentation | APEX 23.2+, Universal Theme, RTL-aware, ~25 pages across 4 roles |
| Integration | ORDS REST module, OAuth2 client credentials, idempotent offline sync |

---

## Business rules

The rules are the point of this project. Each is enforced in exactly one place
and proved by tests.

| Rule | Enforced in | Test |
|---|---|---|
| No overlapping visits for one representative | `PKG_VISIT`, `PKG_PLAN` + row lock | `OVERLAP` suite |
| An approved plan is immutable; changes need an approved request | `PKG_PLAN` state machine | `PLAN` suite |
| Cannot dispense more than the representative holds | `PKG_SAMPLE.dispense` | `SAMPLES` suite |
| Cannot exceed the monthly ceiling per physician and product | `PKG_SAMPLE.dispense` | `SAMPLES` suite |
| Expired batches and inactive products cannot be dispensed | `PKG_SAMPLE.dispense` | `SAMPLES` suite |
| Users read only within their hierarchy | `PKG_SECURITY` + secure views | `SCOPE` suite |
| Closed periods are immutable | period gate in every write API | `PERIOD` suite |
| Stored balances always equal the ledger | `PKG_SAMPLE.reconcile_balances` | `LEDGER` suite |

Ceiling resolution order: **approved exception → physician tier → product default**.
An exception *adds* to the ceiling rather than replacing it — a deliberate
business decision, documented at the point of implementation.

---

## Concurrency

The rules above are the easy half. The hard half is that they must hold when
two sessions act at once.

- **Dispensing** locks the single `(representative, batch)` balance row with
  `SELECT … FOR UPDATE` before validating. Validating before locking passes
  both sessions and oversells the stock.
- **Scheduling** locks the representative's row in `APP_USERS` before the
  overlap check, serialising that one representative's timeline and nothing else.
- **Offline sync** is idempotent through a unique constraint on a
  client-supplied reference — the constraint is the deduplication, not an
  application check that a race can slip past.
- **Batch sync** uses a savepoint per item: one invalid visit out of fifty is
  rejected alone, not with the other forty-nine.

---

## Bilingual by design

Arabic and English are a structural requirement here, not a translation pass.

- UI text through APEX Text Messages; a single application serves both
  languages rather than a translated copy that must be re-synchronised on
  every change
- Reference data carries `_EN` / `_AR` column pairs; `PKG_I18N.label`
  resolves them, so no page contains language logic
- Coded domains (statuses, outcomes, types) resolve through one
  `DOMAIN_VALUES` table feeding every list of values
- Error messages are catalogued bilingually and surfaced by a custom APEX
  error handler
- Arabic sorting uses `NLSSORT` with function-based indexes — sorting Arabic
  without it is simply wrong
- RTL through Universal Theme with logical CSS properties, not mirrored
  stylesheets

---

# How this repository works

**Read this before installing anything.** An APEX project is not a program you
download and double-click. Understanding where the pieces live saves an hour
of confusion.

## What is in Git, and what is not

| Lives in this repository | Lives inside your database |
|---|---|
| SQL scripts that **create** tables and packages | The actual tables, packages and data |
| The APEX application **export** (`apex/f100/`) | The running application you click through |
| Documentation | — |

Git holds the *recipe*. The database holds the *result*. Cloning the repository
gives you the recipe; running `install.sql` cooks it.

This is why there is no "build" step and no server to start: the database *is*
the runtime, and APEX runs inside it.

## Which situation are you in?

### Situation 1 — "I want to run it" (a reviewer, or you on a new machine)

You do **not** create a new project. You clone this one and execute it:

```
1. Install Oracle Database + APEX + ORDS   (once per machine — see below)
2. git clone <this repo>
3. Run install.sql                          → creates schema, data, tests
4. Import apex/f100/install.sql into APEX   → creates application 100
5. Open the app in the browser
```

Steps 2–5 take about ten minutes. Step 1 is the long one, and you do it once.

### Situation 2 — "I want to change something"

Here the direction matters, because **two different things are edited in two
different places**:

| To change… | Edit… | Then… |
|---|---|---|
| A table, package or business rule | the `.sql` file in `db/` | run that file against the database, commit the file |
| A page, region, item, or LOV | the **APEX Builder in the browser** — not a file | re-export the application, commit the export |

Database code is edited as text and pushed into the database.
APEX pages are edited in the browser and pulled out of the database.
Getting this backwards is the single most common mistake with APEX in Git:
editing `p00030.sql` by hand does nothing until it is imported, and it will be
overwritten by the next export.

**The export command** (after changing anything in the Builder):

```powershell
sql pvs/YourPwd@localhost:1521/FREEPDB1

SQL> apex export -applicationid 100 -split -dir ./apex -skipExportDate
SQL> exit

git add apex/ ; git commit -m "Plan page: add tier filter"
```

`-split` writes one file per page instead of one 40,000-line file, so a code
review shows what actually changed. `-skipExportDate` stops the timestamp from
changing on every export and producing empty commits.

### Situation 3 — "I'm coming back to this months later"

```powershell
cd C:\dev\oracle-apex-pharma-visit-system
git pull
docker compose up -d              # start the database again
# wait ~60 seconds, then open http://localhost:8181/ords/r/pvs/pvs
```

The database keeps its data between restarts because it is stored in the
`oracle_oradata` folder, not inside the container.

To wipe everything and start clean:

```powershell
sql pvs/YourPwd@localhost:1521/FREEPDB1 @install.sql
```

`install.sql` drops nothing by itself — if you want a truly empty start, drop
and recreate the `PVS` user first (the statement is in *Database setup*
below).

## The one-time cost, and the repeatable part

| | How often |
|---|---|
| Installing Oracle + APEX + ORDS | Once per machine |
| `git clone` + `install.sql` + import | Once per environment, ~10 minutes |
| `docker compose up -d` | Every time you sit down to work |
| `apex export -split` + commit | Every time you change a page |

---

# Requirements (Windows)

## Hardware

| Resource | Minimum | Comfortable |
|---|---|---|
| RAM | 8 GB total (6 GB free) | 16 GB |
| Disk | 25 GB free | 40 GB |
| CPU | 2 cores | 4 cores |
| Windows | 10 build 19044+ / 11 | 11 |

Virtualisation must be enabled in the BIOS/UEFI — WSL2 and Docker both require
it. Check with `systeminfo` in PowerShell: *Hyper-V Requirements* should say
virtualisation is enabled in firmware.

## Software and official sources

Download everything from Oracle directly. Third-party "all-in-one" images
exist and are convenient, but nothing here needs one, and an unverifiable
database image is not something to run credentials against.

| Software | Version | Official source | Download | On disk |
|---|---|---|---|---|
| Docker Desktop for Windows | current | [docs.docker.com/desktop/setup/install/windows-install](https://docs.docker.com/desktop/setup/install/windows-install/) | ≈ 1.5 GB | ≈ 3 GB |
| Oracle Database Free — container image | 23ai | `container-registry.oracle.com/database/free` | ≈ 10 GB | ≈ 12 GB with data |
| Oracle Database Free — Windows installer | 23ai | [oracle.com/database/free/get-started](https://www.oracle.com/database/free/get-started/) | ≈ 2 GB | ≈ 15 GB (allow 50 GB) |
| ORDS + APEX container image | current | `container-registry.oracle.com/database/ords-developer` | ≈ 1.5 GB | — |
| Oracle APEX (manual install only) | 23.2+ (26.1 current) | [oracle.com/tools/downloads/apex-downloads](https://www.oracle.com/tools/downloads/apex-downloads/) | 670 MB English-only · 1,178 MB full | + ≈ 220 MB in the APEX tablespace, + ≈ 60 MB per extra language |
| ORDS (manual install only) | 24.x+ | [oracle.com/database/sqldeveloper/technologies/db-actions/download](https://www.oracle.com/database/sqldeveloper/technologies/db-actions/download/) | ≈ 100 MB | ≈ 250 MB |
| SQLcl | 24+ | [oracle.com/database/sqldeveloper/technologies/sqlcl/download](https://www.oracle.com/database/sqldeveloper/technologies/sqlcl/download/) | ≈ 130 MB | ≈ 300 MB |
| Java (JDK) | 17+ | [adoptium.net](https://adoptium.net/) or Oracle JDK | ≈ 180 MB | ≈ 320 MB |
| Git for Windows | any | [git-scm.com/download/win](https://git-scm.com/download/win) | ≈ 60 MB | ≈ 350 MB |

The APEX figures are Oracle's published requirements; the rest are approximate
and shift between releases. A free Oracle account is required for the database,
APEX, ORDS and SQLcl downloads and for pulling from the container registry.

**Enterprise Edition is not required.** The project runs entirely on Oracle
Database Free — see [ADR-02](docs/adr.md#adr-02) for the one place that
constraint changed a design decision.

**The database character set must be `AL32UTF8`.** This is not a preference:
Arabic stored under any other character set is corrupted on write and cannot be
recovered by conversion afterwards. `02_i18n.sql` verifies it and refuses to
install otherwise.

---

# Installation on Windows

Two paths. **Path A is strongly recommended** — it installs APEX and ORDS
automatically, which is the part that goes wrong most often by hand.

## Path A — Docker Desktop + WSL2 (recommended, ~30 minutes)

### 1. Enable WSL2

In PowerShell **as Administrator**, then restart the machine:

```powershell
wsl --install
wsl --set-default-version 2
```

### 2. Install Docker Desktop

Install from the link above, then open it and set:

- **Settings → General → Use the WSL 2 based engine** — enabled
- **Settings → Resources → Memory → at least 6 GB** (the default is too small;
  the database container will fail to start)

### 3. Create the working folder

Work inside the WSL2 filesystem, not `C:\Users\...`. Open the **Ubuntu**
terminal that WSL installed:

```bash
mkdir -p ~/oracle-apex/{oracle_oradata,ords_secrets,ords_config}
cd ~/oracle-apex
```

> Database files on a Windows-mounted drive are dramatically slower. The seed
> load that takes 40 seconds inside WSL2 can take ten minutes under `C:\`. This
> single choice causes more "Oracle on Windows is slow" complaints than any
> other.

### 4. Give ORDS the database connection

```bash
echo 'CONN_STRING=sys/YourStrongPwd1@database:1521/FREEPDB1' \
  > ords_secrets/conn_string.txt
```

This file is consumed and deleted on first start. Never commit it.

### 5. Create `compose.yml`

```yaml
services:
  db:
    image: container-registry.oracle.com/database/free:latest
    hostname: database
    ports:
      - "1521:1521"
    environment:
      - ORACLE_PWD=YourStrongPwd1
      - ORACLE_CHARACTERSET=AL32UTF8      # required for Arabic
    volumes:
      - ./oracle_oradata/:/opt/oracle/oradata
    healthcheck:
      test: ["CMD", "sqlplus", "-L", "sys/YourStrongPwd1@//localhost:1521/FREEPDB1", "as", "sysdba", "@/dev/null"]
      interval: 30s
      retries: 20

  ords:
    image: container-registry.oracle.com/database/ords-developer:latest
    ports:
      - "8181:8181"
    volumes:
      - ./ords_secrets/:/opt/oracle/variables
      - ./ords_config/:/etc/ords/config/
    depends_on:
      db:
        condition: service_healthy
```

### 6. Start it

```bash
docker compose up -d
docker compose logs -f ords        # watch the APEX installation finish
```

First start downloads ~10 GB and installs APEX — allow 20–40 minutes on a home
connection. Every later start takes under a minute.

### 7. Set the APEX admin password and create a workspace

```bash
docker compose exec db sqlplus sys/YourStrongPwd1@FREEPDB1 as sysdba
```

```sql
@/opt/oracle/product/*/apex/apxchpwd.sql
```

Open **http://localhost:8181/ords/apex_admin**, sign in to the `INTERNAL`
workspace, and create a workspace named `PVS` with a new schema of the same
name.

## Path B — Native Windows installation (no Docker)

Use this only if Docker is unavailable to you — it has more manual steps and
more ways to go wrong.

1. Download the Windows zip from
   [oracle.com/database/free/get-started](https://www.oracle.com/database/free/get-started/),
   extract it, and run `setup.exe` **as Administrator**. Set the SYS password;
   the PDB created is `FREEPDB1`.
2. Install APEX — extract the APEX zip, open a terminal in that folder:
   ```powershell
   sqlplus / as sysdba
   ```
   ```sql
   ALTER SESSION SET CONTAINER = FREEPDB1;
   @apexins.sql SYSAUX SYSAUX TEMP /i/
   @apxchpwd.sql
   ALTER USER APEX_PUBLIC_USER IDENTIFIED BY YourPwd ACCOUNT UNLOCK;
   ```
3. Install a JDK 17+, extract ORDS, then:
   ```powershell
   ords.bat --config C:\ords\config install
   ords.bat --config C:\ords\config serve
   ```

Windows specifics worth knowing before you start: run the installer with UAC
prompts accepted, exclude the Oracle directories from real-time antivirus
scanning (it slows datafile I/O badly), and allow 50 GB free — the Windows
footprint is larger than the Linux one.

## Not an option: apex.oracle.com

A free workspace on apex.oracle.com runs APEX pages, but **not this project**:
it does not grant `CREATE ANY CONTEXT`, `DBMS_SCHEDULER` job creation, or ORDS
client and OAuth administration — three things Pharma Visit System depends on. Use it to
explore APEX, not to install Pharma Visit System.

## Installing SQLcl

SQLcl provides the `sql` command used by `install.sql` and by `apex export`.
It needs a JDK 17 or newer.

```powershell
winget install EclipseAdoptium.Temurin.17.JDK
Expand-Archive sqlcl-latest.zip -DestinationPath C:\tools
setx PATH "$env:PATH;C:\tools\sqlcl\bin"
```

Verify with `sql -v`. If you use the Oracle SQL Developer extension for VS
Code, SQLcl comes bundled with it and a separate install is unnecessary.

---

# Database setup

Connect as a privileged user and create the application schema.

```powershell
docker compose exec db sqlplus sys/YourStrongPwd1@FREEPDB1 as sysdba
```

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;

-- For a clean re-install, drop first:
-- DROP USER pvs CASCADE;

CREATE USER pvs IDENTIFIED BY "ChangeMe_123"
  DEFAULT TABLESPACE users
  QUOTA UNLIMITED ON users;

GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE,
      CREATE PROCEDURE, CREATE TRIGGER, CREATE TYPE, CREATE JOB,
      CREATE MATERIALIZED VIEW, CREATE SYNONYM TO pvs;

-- Application contexts require a system privilege; it cannot come from a role
GRANT CREATE ANY CONTEXT, DROP ANY CONTEXT TO pvs;

GRANT EXECUTE ON DBMS_SESSION   TO pvs;
GRANT EXECUTE ON DBMS_SCHEDULER TO pvs;
GRANT EXECUTE ON DBMS_MVIEW     TO pvs;

-- Required for the ORDS module in 12_ords_rest.sql
GRANT EXECUTE ON ORDS_ADMIN TO pvs;
```

Verify the character set before continuing:

```sql
SELECT value FROM nls_database_parameters WHERE parameter = 'NLS_CHARACTERSET';
```

It must return `AL32UTF8`. If it does not, stop and recreate the database with
the correct character set.

---

# Running Pharma Visit System

```powershell
git clone https://github.com/mosabmoammar/oracle-apex-pharma-visit-system.git
cd oracle-apex-pharma-visit-system

sql pvs/ChangeMe_123@localhost:1521/FREEPDB1 @install.sql
```

`install.sql` creates the schema, installs all packages, loads the synthetic
dataset, runs the test suite, and **fails loudly** if any object is invalid or
any test fails. Expected ending:

```
Invalid objects : 0
Failed tests    : 0
Pharma Visit System installed successfully.
```

Install the REST layer:

```powershell
sql pvs/ChangeMe_123@localhost:1521/FREEPDB1 @db/install/12_ords_rest.sql
```

Import the application:

```
APEX → App Builder → Import → apex/f100/install.sql → Application 100
```

Open **http://localhost:8181/ords/r/pvs/pvs** and sign in.

Demo accounts (synthetic): `ADMIN`, `MANAGER`, `SUP1`, `REP01`.

---

# Everyday commands

```powershell
# Start working
docker compose up -d

# Stop for the day (data is preserved)
docker compose stop

# See what the database is doing
docker compose logs -f db

# Connect
sql pvs/ChangeMe_123@localhost:1521/FREEPDB1

# Re-run the tests after changing a rule
sql pvs/ChangeMe_123@localhost:1521/FREEPDB1 @db/tests/10_tests.sql

# Export the APEX app after changing pages, then commit
sql pvs/ChangeMe_123@localhost:1521/FREEPDB1
SQL> apex export -applicationid 100 -split -dir ./apex -skipExportDate
```

---

# Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ORA-01031: insufficient privileges` on `CREATE CONTEXT` | `CREATE ANY CONTEXT` not granted | Grant it as `sysdba`; it cannot be granted through a role |
| Arabic text stored as `¿¿¿` | Character set is not `AL32UTF8` | Recreate the database correctly; existing data cannot be repaired by conversion |
| Arabic sorts in the wrong order | Query bypasses `NLSSORT` | Sort through the provided views, which apply `PKG_I18N.sort_key` |
| Everything is extremely slow | Project sits under `C:\Users\...` | Move it into the WSL2 filesystem |
| Database container will not start | Docker Desktop memory below 6 GB | Settings → Resources → Memory |
| `wsl --install` fails | Virtualisation disabled in firmware | Enable VT-x / AMD-V in BIOS |
| ORDS container exits at start | `conn_string.txt` missing or wrong | Recreate it and restart; it is deleted after a successful read |
| `ORA-12514` service unknown | Wrong service name | Use `FREEPDB1`, not `FREE` or `XEPDB1` |
| Port 1521 or 8181 already in use | Another Oracle or ORDS instance | Change the host-side port in `compose.yml` |
| APEX login loop after import | Post-authentication process not set | Application → Security → Authentication → post-authentication must be `pkg_apex.post_authenticate` |
| `ORA-20001` on every page | Security context not established | Same cause as above — the context must exist before any secure view is queried |
| Seed load runs for many minutes | Audit triggers left enabled | Re-run `09_seed_data.sql`, which disables and rebuilds them |
| `sql` is not recognised | SQLcl not on `PATH`, or no JDK | Install a JDK 17+ and add `sqlcl\bin` to `PATH` |

---

# Dataset

Every record is generated by `09_seed_data.sql`:

| | |
|---|---|
| Doctors / facilities | 300 / 45 |
| Products / batches | 24 / 72 |
| Periods | 12 months |
| Planned items | ~24,000 |
| Executed visits | ~20,000 |
| Sample movements | ~35,000 |

Sized so that performance claims can be tested rather than asserted.
Generation is set-based; audit triggers are disabled during the load and
rebuilt afterwards; statistics are gathered at the end — without them any
timing measurement is meaningless.

---

# Testing

```sql
begin pkg_test.run_all; end;
/
```

```
[PASS] SAMPLES   BR-03 valid dispense reduces balance by exact quantity
[PASS] SAMPLES   BR-03 dispense above balance is rejected
[PASS] SAMPLES   BR-04 dispense above monthly ceiling is rejected
[PASS] SAMPLES   BR-04 dispense exactly at the ceiling is allowed
[PASS] OVERLAP   BR-01 overlapping item is rejected
[PASS] OVERLAP   BR-01 back-to-back visits are allowed
...
Result: 18/18 passed
```

Every rule has both a negative and a positive case. A suite with only negative
cases hides over-blocking: two visits where one ends exactly as the next begins
are **not** overlapping, and the tests prove the system agrees.

---

# REST API

Base `/ords/pvs/v1/` · OAuth2 client credentials.

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/plan/current` | The representative's approved plan for the open period |
| GET | `/reference` | Doctors, products and batch balances for offline caching |
| POST | `/visits/sync` | Batch upload of offline-captured visits — per-item results |
| POST | `/samples/dispense` | Single dispense, identical validation to the UI |

`POST /visits/sync` returns **207** when part of a batch is rejected, with a
verdict per item. A single status for the whole batch would force the client to
re-send everything or lose data.

The REST layer is defined as code in
[`db/install/12_ords_rest.sql`](db/install/12_ords_rest.sql) — a REST API that
exists only in a development instance's metadata is neither deployable nor
reviewable.

---

# Repository layout

```
oracle-apex-pharma-visit-system/
├── install.sql                   one command, empty schema to tested system
├── compose.yml                   database + ORDS/APEX containers
├── db/
│   ├── install/
│   │   ├── 01_tables.sql         schema, constraints, indexes
│   │   ├── 02_i18n.sql           bilingual layer, PKG_I18N, error catalogue
│   │   ├── 03_security.sql       context, PKG_SECURITY, secure views
│   │   ├── 04_pkg_sample.sql     stock ledger, ceilings, concurrency
│   │   ├── 05_pkg_plan.sql       plan state machine, change requests
│   │   ├── 06_pkg_visit.sql      execution, offline sync
│   │   ├── 07_pkg_target.sql     targets, achievement, dashboards
│   │   ├── 08_audit.sql          generated audit triggers
│   │   ├── 11_apex_support.sql   authentication, error handler, wrappers
│   │   └── 12_ords_rest.sql      REST module and OAuth2
│   ├── seed/09_seed_data.sql
│   └── tests/10_tests.sql
├── apex/f100/                    split application export — edited in the Builder, not here
└── docs/
    ├── SRS.md                    requirements, use cases, traceability
    ├── erd.md                    data model and modelling decisions
    ├── adr.md                    architectural decisions and rejected alternatives
    ├── apex-build-guide.md       page-by-page application specification
    └── screenshots/
```

---

# Deliberate omissions

Knowing what not to build is part of the design:

- **No hand-rolled credential storage.** Authentication goes through
  `APEX_UTIL`; `APP_USERS` holds identity and authorisation only.
- **No audit on `SAMPLE_TRANSACTIONS`.** It is already append-only; auditing it
  would double every write for no additional evidence.
- **No VPD.** It would express row scoping more elegantly, but it is an
  Enterprise Edition feature — the licensing constraint is stated rather than
  ignored.
- **No `IS_DELETED` flags on transactional tables.** Corrections are reversing
  entries. That is what makes the ledger trustworthy.
- **No generic key-value attribute table.** It defeats constraints, typing and
  the optimizer.

---

# Data & confidentiality

Every record in this repository is synthetic and generated by
`09_seed_data.sql`. No physician, facility, product, organisation or person in
this project corresponds to anything real, and no code, schema, screen or
document from any client engagement was used in building it.

---

## Author

**Mosab N. R. Abumoammar** — Oracle APEX Developer
Khan Yunis, Gaza, Palestine

[GitHub](https://github.com/mosabmoammar) ·
[LinkedIn](https://linkedin.com/in/mosabmoammar) ·
mosab.abumoammar@gmail.com

## License

MIT — see [LICENSE](LICENSE).
