# APEX application export

This folder holds the split export of application **100 (Pharma Visit System)**.

It is **generated**, not hand-written. Pages are edited in the APEX App
Builder and exported from there:

```bash
sql pvs/<password>@localhost:1521/FREEPDB1

SQL> apex export -applicationid 100 -split -dir ./apex -skipExportDate
```

Editing a file in this folder by hand has no effect on the running
application, and the next export overwrites it.

After a successful export this folder contains:

```
apex/f100/
├── install.sql
└── application/
    ├── create_application.sql
    ├── pages/                 p00001.sql … p00080.sql
    ├── shared_components/
    └── end_environment.sql
```

To install into a workspace: App Builder → Import → `apex/f100/install.sql`.

See `docs/apex-build-guide.md` for the page-by-page specification this
application is built from.
