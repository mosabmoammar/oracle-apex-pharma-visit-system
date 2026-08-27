--------------------------------------------------------------------------------
-- Pharma Visit System — install.sql
-- One command from an empty schema to a running, populated, tested system.
--
--   sqlplus pvs/<password>@localhost:1521/xepdb1 @install.sql
--
-- Order is dependency-driven, not alphabetical:
--   tables -> i18n (PKG_I18N is used by every later package)
--          -> security (PKG_SECURITY is used by every write API)
--          -> sample -> plan -> visit (visit calls sample and plan)
--          -> target -> audit (generated from the finished table set)
--          -> seed -> tests
--
-- Prerequisites
--   * Oracle Database 19c+ with character set AL32UTF8
--   * Schema owner granted: CREATE SESSION, TABLE, VIEW, PROCEDURE, TRIGGER,
--     TYPE, SEQUENCE, MATERIALIZED VIEW, JOB, and EXECUTE on DBMS_SESSION,
--     DBMS_SCHEDULER, DBMS_MVIEW
--   * CREATE ANY CONTEXT (needed once for CTX_PVS)
--------------------------------------------------------------------------------
set define off
set echo off
set feedback off
set serveroutput on size unlimited
whenever sqlerror exit failure rollback

prompt
prompt ================================================================
prompt  Pharma Visit System installation
prompt ================================================================
prompt

prompt [1/11] Schema objects ...
@@db/install/01_tables.sql

prompt [2/11] Bilingual layer ...
@@db/install/02_i18n.sql

prompt [3/11] Security context and secure views ...
@@db/install/03_security.sql

prompt [4/11] Sample stock logic ...
@@db/install/04_pkg_sample.sql

prompt [5/11] Plan lifecycle ...
@@db/install/05_pkg_plan.sql

prompt [6/11] Visit execution and sync ...
@@db/install/06_pkg_visit.sql

prompt [7/11] Targets and dashboards ...
@@db/install/07_pkg_target.sql

prompt [8/11] Audit trail ...
@@db/install/08_audit.sql

prompt [9/11] APEX support layer ...
@@db/install/11_apex_support.sql

prompt [10/11] Seed data ...
@@db/seed/09_seed_data.sql

prompt [11/11] Business rule tests ...
@@db/tests/10_tests.sql

--------------------------------------------------------------------------------
-- Post-install verification: fail loudly rather than leave a broken schema
--------------------------------------------------------------------------------
prompt
prompt Verifying installation ...

declare
  l_invalid number;
  l_failed  number;
begin
  select count(*) into l_invalid
    from user_objects
   where status = 'INVALID';

  if l_invalid > 0 then
    dbms_output.put_line('Recompiling ' || l_invalid || ' invalid object(s) ...');
    dbms_utility.compile_schema(schema => user, compile_all => false);

    select count(*) into l_invalid from user_objects where status = 'INVALID';
  end if;

  select count(*) into l_failed from test_results where passed = 'N';

  dbms_output.put_line(rpad('-', 64, '-'));
  dbms_output.put_line('Invalid objects : ' || l_invalid);
  dbms_output.put_line('Failed tests    : ' || l_failed);
  dbms_output.put_line(rpad('-', 64, '-'));

  if l_invalid > 0 or l_failed > 0 then
    raise_application_error(-20500,
      'Installation completed with errors: ' || l_invalid ||
      ' invalid object(s), ' || l_failed || ' failed test(s).');
  end if;

  dbms_output.put_line('Pharma Visit System installed successfully.');
  dbms_output.put_line('Next: import apex/f100/install.sql into your APEX workspace.');
end;
/

exit success
