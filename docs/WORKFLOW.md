# Project Workflow — from empty folder to a public GitHub repository

How this project is actually built and maintained, in the order the work
happens. Written for Windows with SQLcl, Git and Docker.

---

## Part 0 — Before any code (half a day)

### Environments

| Environment | Purpose | Rule |
|---|---|---|
| DEV | Where you build | The only place APEX pages are edited |
| TEST | Where you verify a release | Refreshed by script from the repository |
| PROD | Where users work | **Never** opened in App Builder |

Editing an application directly in production is the defining habit of an
amateur APEX team. Once a page is changed there, the repository is no longer
the truth, and every later deployment risks overwriting an undocumented fix.

### Standards, written down first

A one-page file agreed before the first table exists:

- table and constraint naming (`<TBL>_PK`, `<TBL>_FK_<COL>`, `<TBL>_CK_<COL>`)
- page numbering — ten numbers reserved per module (10s rep, 50s supervisor…)
- where logic lives: packages, never pages
- branch and commit conventions

Fixing naming on day one costs nothing. Fixing it in month three is a rename
of every object and every reference to it.

---

## Part 1 — Create the project

```powershell
mkdir C:\dev\pvs ; cd C:\dev\pvs
git init -b main
```

**The first commit is `.gitignore`, before anything else exists.** A secret
committed once lives in the history forever, and rewriting published history is
a bad first impression.

```powershell
# create .gitignore (see the repo copy), then:
git add .gitignore
git commit -m "chore: add gitignore before any code exists"
```

### Optional but modern: SQLcl Projects

```powershell
sql /nolog
SQL> project init -name pvs -schemas PVS
```

This generates a Liquibase-backed structure with schema changelogs and an APEX
export target. Oracle's current recommended path for versioning APEX and schema
together — worth knowing by name even if you keep plain scripts, because it is
what a modern team will ask about.

This project uses plain, numbered SQL scripts instead: they are readable by
anyone in thirty seconds without knowing Liquibase, which matters more for a
public portfolio repository than migration machinery does.

### Folder skeleton

```powershell
mkdir db\install, db\seed, db\tests, apex, docs\screenshots, .github\workflows
```

---

## Part 2 — Build order

The sequence below is not the order the finished documentation reads in. It is
the order that produces working software with the fewest reversals.

**1. Schema as scripts.** ERD, then `01_tables.sql`. From this moment:
*no object is ever created by clicking in a tool.* Anything created by hand
cannot be reproduced in TEST, and the repository quietly stops being true.

**2. One vertical slice, end to end.** One table → one package → one page →
one test, working together. Days, not weeks. Show it to whoever asked for the
system. APEX's real advantage is how fast you can put something in front of a
user; building twenty-five screens before anyone sees one throws that advantage
away.

**3. Shared components before pages.** Authentication, authorization schemes,
LOVs, templates, navigation, the error handler. Built after the pages, every
one of those pages must be revisited.

**4. Security and error handling from the start.** Adding row scoping to a
finished application means auditing every query on every page. This is the most
common technical debt in APEX projects, and it is never paid off cheaply.

**5. Realistic data volume in week two.** Twenty thousand rows early. Performance
problems found at the end are not query problems — they are design problems.

**6. Short cycles.** Build → demo → adjust, every one or two weeks.

---

## Part 3 — The two directions of change

This is the part that confuses everyone new to APEX in Git.

```
   Database code            APEX application
   ─────────────            ────────────────
   edit the .sql file       edit in App Builder (browser)
          │                          │
          ▼                          ▼
   run it into the DB        apex export -split
          │                          │
          ▼                          ▼
        commit                     commit
```

Database code is **pushed** from files into the database.
APEX pages are **pulled** from the database into files.

Editing `apex/f100/application/pages/p00030.sql` by hand does nothing — and the
next export overwrites it.

### After changing pages in the Builder

```powershell
cd C:\dev\pvs
sql pvs/pwd@localhost:1521/FREEPDB1

SQL> apex export -applicationid 100 -split -dir ./apex -skipExportDate
SQL> exit

git add apex/
git commit -m "feat(plan): add tier filter to plan page"
```

`-split` writes one file per page, so a diff shows what changed.
`-skipExportDate` prevents a timestamp change from creating an empty commit on
every export — without it, `git status` is dirty after doing nothing.

---

## Part 4 — Branching and commits

For a solo portfolio project, keep it light but real:

```powershell
git switch -c feat/sample-ceilings
# … work, commit in small steps …
git push -u origin feat/sample-ceilings
# open a Pull Request on GitHub, review your own diff, merge
```

Reviewing your own PR is not theatre: reading a split export diff catches
changes you did not intend to make — a debug flag left on, a hardcoded string,
a page you opened and accidentally saved.

Commit message convention (Conventional Commits):

```
feat(sample): enforce monthly ceiling per doctor and product
fix(plan): reject overlapping items on the same day
docs(adr): record why VPD was rejected
test(scope): add supervisor visibility case
chore(ci): run test suite on push
```

Commits like `update`, `fix`, and `changes` tell a reviewer nothing — and the
commit history is part of what a hiring reviewer reads.

---

## Part 5 — Publishing to GitHub

### 1. Final check before the repository is public

```powershell
# Anything that looks like a credential?
git grep -in "password\|conn_string\|client_secret\|ORACLE_PWD"

# Any unsplit export or dump accidentally staged?
git ls-files | Select-String "^f\d+\.sql|\.dmp$"
```

Confirm: no real data, no client artefacts, no `conn_string.txt`, no workspace
export. `ORACLE_PWD=YourStrongPwd1` inside README instructions is fine — it is
an instruction, not a credential.

### 2. Create the repository

```powershell
# With the GitHub CLI
gh repo create pvs --public --source=. --remote=origin `
  --description "Bilingual Oracle APEX + PL/SQL system for medical visit and sample management"

git push -u origin main
```

Or create it on github.com and:

```powershell
git remote add origin https://github.com/<user>/oracle-apex-pharma-visit-system.git
git push -u origin main
```

### 3. Make the repository page do its job

- **Description** — one line stating the stack and the domain
- **Topics** — `oracle`, `oracle-apex`, `plsql`, `ords`, `low-code`,
  `oracle-database`
- **README** — the front door; a reviewer decides in thirty seconds
- **Screenshots** in `docs/screenshots/`, in both Arabic and English, embedded
  in the README. For a UI project, no screenshot means the reviewer never sees
  the UI.
- **Pin the repository** on your GitHub profile
- **LICENSE** — MIT, so the terms are unambiguous

### 4. Protect `main`

Settings → Branches → Add rule for `main`: require a pull request, and require
status checks to pass. Even solo, this prevents an accidental force-push from
rewriting published history.

### 5. Continuous integration — the detail almost no portfolio repo has

`.github/workflows/ci.yml`: on every push, a real Oracle database starts, the
schema installs, and the test suite runs. A green badge on the README means the
claims in it are verified on every commit, not asserted once.

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  database:
    runs-on: ubuntu-latest

    services:
      oracle:
        image: gvenzl/oracle-free:23-slim-faststart
        env:
          ORACLE_PASSWORD: ci_password_1
          ORACLE_CHARACTERSET: AL32UTF8
        ports:
          - 1521:1521
        options: >-
          --health-cmd healthcheck.sh
          --health-interval 20s
          --health-timeout 10s
          --health-retries 15

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'

      - name: Install SQLcl
        run: |
          curl -sL -o sqlcl.zip https://download.oracle.com/otn_software/java/sqldeveloper/sqlcl-latest.zip
          unzip -q sqlcl.zip
          echo "$PWD/sqlcl/bin" >> $GITHUB_PATH

      - name: Create application schema
        run: |
          sql -S sys/ci_password_1@localhost:1521/FREEPDB1 as sysdba <<'SQL'
            CREATE USER pvs IDENTIFIED BY ci_password_1 QUOTA UNLIMITED ON users;
            GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE,
                  CREATE PROCEDURE, CREATE TRIGGER, CREATE TYPE, CREATE JOB,
                  CREATE MATERIALIZED VIEW TO pvs;
            GRANT CREATE ANY CONTEXT, DROP ANY CONTEXT TO pvs;
            GRANT EXECUTE ON DBMS_SESSION TO pvs;
            GRANT EXECUTE ON DBMS_SCHEDULER TO pvs;
            GRANT EXECUTE ON DBMS_MVIEW TO pvs;
          SQL

      - name: Install schema, seed and run tests
        run: sql -S pvs/ci_password_1@localhost:1521/FREEPDB1 @install.sql
```

Two honest notes to keep in the file:

- The CI image is a community image (`gvenzl/oracle-free`), used because it is
  purpose-built for CI and starts in seconds. It runs throwaway data with a
  throwaway password — a different risk profile from a development machine
  holding your own credentials, which is why the README recommends Oracle's own
  registry there.
- CI validates the **database layer**: schema, packages, seed and the full test
  suite. APEX itself is not installed in CI; the application layer is verified
  by importing the export into a real workspace.

Then add the badge at the top of the README:

```markdown
![CI](https://github.com/<user>/oracle-apex-pharma-visit-system/actions/workflows/ci.yml/badge.svg)
```

### 6. Tag a release

```powershell
git tag -a v1.0.0 -m "Pharma Visit System 1.0 — schema, packages, tests, APEX export"
git push origin v1.0.0
```

A tagged release tells a reviewer the project reached a defined state, rather
than being an open-ended work in progress.

---

## Part 6 — Deploying a change to TEST and PROD

```powershell
# 1. Schema changes: forward-only migration scripts, never edits to 01_tables.sql
sql pvs/pwd@test-host:1521/FREEPDB1 @db/migrations/V4__add_visit_followups.sql

# 2. Application: import the export, replacing the existing application id
sql pvs/pwd@test-host:1521/FREEPDB1 @apex/f100/install.sql
```

Two rules that hold in every serious shop:

**Schema changes are forward-only.** Once `01_tables.sql` has run in an
environment that holds data, it is never edited — a new numbered migration is
added instead. Editing the baseline works only for a database that can be
dropped.

**The application is deployed, never edited in place.** If a fix is needed in
production, it is made in DEV, exported, committed, and deployed through TEST.
The exception you make "just this once" is the one that breaks the next
deployment.

---

## Part 7 — What this project did differently, and why

| Real project | This repository |
|---|---|
| One page of rules, growing weekly | A full SRS written up front |
| Vertical slice first, then breadth | Full database layer, then the UI |
| Documentation written alongside | Documentation as a deliverable in itself |
| Demo-driven priorities | Reviewer-driven priorities |

The difference is deliberate. A real project optimises for feedback from the
person who asked for the system. A portfolio project has no such person: the
reviewer reads the repository, so the repository is the product. Knowing which
situation you are in — and building accordingly — is itself the senior
judgement.
