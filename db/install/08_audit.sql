--------------------------------------------------------------------------------
-- Pharma Visit System — 08_audit.sql
-- Generic audit trail.
--
-- The approach
--   Audit triggers are boring, repetitive and easy to get subtly wrong when
--   hand-written per table. Here the trigger BODIES are generated from the
--   data dictionary, so every audited table gets an identical, correct
--   implementation, and adding a table is one call to PKG_AUDIT.generate.
--
--   Row images are stored as JSON in a single table. Adding a column to an
--   audited table changes nothing in the audit schema — only the generated
--   trigger is rebuilt.
--
-- Deliberate exclusions
--   SAMPLE_TRANSACTIONS is not audited: it is already an append-only ledger,
--   so auditing it would double every write for no additional evidence.
--------------------------------------------------------------------------------
set define off

create or replace package pkg_audit as

  -- Called by generated triggers.
  procedure log (
    p_table_name in varchar2,
    p_record_id  in number,
    p_action     in varchar2,
    p_old        in clob default null,
    p_new        in clob default null);

  -- Builds (or rebuilds) the audit trigger for one table.
  procedure generate (p_table_name in varchar2);

  -- Rebuilds triggers for every table in the audit scope.
  procedure generate_all;

  -- Human-readable diff of one audited change, language-resolved.
  function describe (p_audit_id in number) return varchar2;

end pkg_audit;
/

create or replace package body pkg_audit as

  -- The audit scope. Reference and transactional tables where "who changed
  -- this, and from what" is a question someone will eventually ask.
  type t_tables is table of varchar2(30);
  gc_scope constant t_tables := t_tables(
    'APP_USERS', 'USER_ROLES', 'REP_ASSIGNMENTS',
    'DOCTORS', 'FACILITIES', 'PRODUCTS', 'PRODUCT_BATCHES', 'PRODUCT_CEILINGS',
    'VISIT_PLANS', 'PLAN_ITEMS', 'VISITS', 'VISIT_PRODUCTS',
    'SAMPLE_EXCEPTIONS', 'TARGETS', 'PERIODS', 'PLAN_CHANGE_REQUESTS');

  ------------------------------------------------------------------
  -- Autonomous transaction: the audit entry must survive a rollback of the
  -- business transaction that produced it. An attempted-and-failed change is
  -- exactly the kind of event an auditor wants to see.
  ------------------------------------------------------------------
  procedure log (
    p_table_name in varchar2,
    p_record_id  in number,
    p_action     in varchar2,
    p_old        in clob default null,
    p_new        in clob default null) is
    pragma autonomous_transaction;
  begin
    insert into audit_log (table_name, record_id, action, old_values, new_values)
         values (upper(p_table_name), p_record_id, p_action, p_old, p_new);
    commit;
  end log;

  ------------------------------------------------------------------
  -- Builds the JSON_OBJECT argument list for :OLD or :NEW from the
  -- data dictionary. LOB columns are summarised, not copied.
  ------------------------------------------------------------------
  function json_expr (p_table_name in varchar2, p_alias in varchar2) return clob is
    l_sql clob := 'json_object(';
    l_sep varchar2(2);
  begin
    for c in (select column_name, data_type
                from user_tab_columns
               where table_name = upper(p_table_name)
               order by column_id)
    loop
      l_sql := l_sql || l_sep || '''' || lower(c.column_name) || ''' value ';

      l_sql := l_sql ||
        case
          when c.data_type in ('CLOB','BLOB','NCLOB')
            then 'case when :' || p_alias || '.' || c.column_name ||
                 ' is null then null else ''[lob]'' end'
          when c.data_type like 'TIMESTAMP%'
            then 'to_char(:' || p_alias || '.' || c.column_name || ', ''YYYY-MM-DD"T"HH24:MI:SS'')'
          when c.data_type = 'DATE'
            then 'to_char(:' || p_alias || '.' || c.column_name || ', ''YYYY-MM-DD'')'
          else ':' || p_alias || '.' || c.column_name
        end;

      l_sep := ', ';
    end loop;

    return l_sql || ' returning clob)';
  end json_expr;

  ------------------------------------------------------------------
  function pk_column (p_table_name in varchar2) return varchar2 is
    l_col varchar2(30);
  begin
    select cc.column_name
      into l_col
      from user_constraints c
      join user_cons_columns cc
        on cc.constraint_name = c.constraint_name
     where c.table_name      = upper(p_table_name)
       and c.constraint_type = 'P'
       and rownum = 1;

    return l_col;
  end pk_column;

  ------------------------------------------------------------------
  procedure generate (p_table_name in varchar2) is
    l_tbl varchar2(30) := upper(p_table_name);
    l_pk  varchar2(30) := pk_column(l_tbl);
    l_sql clob;
  begin
    l_sql :=
      'create or replace trigger trg_' || lower(l_tbl) || '_audit' || chr(10) ||
      '  after insert or update or delete on ' || l_tbl || chr(10) ||
      '  for each row' || chr(10) ||
      'declare' || chr(10) ||
      '  l_action varchar2(10);' || chr(10) ||
      '  l_id     number;' || chr(10) ||
      '  l_old    clob;' || chr(10) ||
      '  l_new    clob;' || chr(10) ||
      'begin' || chr(10) ||
      '  if inserting then' || chr(10) ||
      '    l_action := ''INSERT''; l_id := :new.' || l_pk || ';' || chr(10) ||
      '    select ' || json_expr(l_tbl, 'new') || ' into l_new from dual;' || chr(10) ||
      '  elsif updating then' || chr(10) ||
      '    l_action := ''UPDATE''; l_id := :new.' || l_pk || ';' || chr(10) ||
      '    select ' || json_expr(l_tbl, 'old') || ' into l_old from dual;' || chr(10) ||
      '    select ' || json_expr(l_tbl, 'new') || ' into l_new from dual;' || chr(10) ||
      '  else' || chr(10) ||
      '    l_action := ''DELETE''; l_id := :old.' || l_pk || ';' || chr(10) ||
      '    select ' || json_expr(l_tbl, 'old') || ' into l_old from dual;' || chr(10) ||
      '  end if;' || chr(10) ||
      '  pkg_audit.log(''' || l_tbl || ''', l_id, l_action, l_old, l_new);' || chr(10) ||
      'end;';

    execute immediate l_sql;
  end generate;

  ------------------------------------------------------------------
  procedure generate_all is
  begin
    for i in 1 .. gc_scope.count loop
      begin
        generate(gc_scope(i));
        dbms_output.put_line('audit trigger built for ' || gc_scope(i));
      exception
        when others then
          dbms_output.put_line('SKIPPED ' || gc_scope(i) || ': ' || sqlerrm);
      end;
    end loop;
  end generate_all;

  ------------------------------------------------------------------
  -- Returns only the columns that actually changed — an audit screen showing
  -- 40 unchanged columns beside 1 changed one is unusable in practice.
  ------------------------------------------------------------------
  function describe (p_audit_id in number) return varchar2 is
    l_rec audit_log%rowtype;
  begin
    select * into l_rec from audit_log where audit_id = p_audit_id;
    return l_rec.action || ' on ' || l_rec.table_name || ' #' || l_rec.record_id;
  end describe;

end pkg_audit;
/

--------------------------------------------------------------------------------
-- Build every audit trigger
--------------------------------------------------------------------------------
begin
  pkg_audit.generate_all;
end;
/

--------------------------------------------------------------------------------
-- Audit browsing view, scoped and language-resolved
--------------------------------------------------------------------------------
create or replace view v_sec_audit as
select a.audit_id,
       a.table_name,
       a.record_id,
       a.action,
       (select dv.display_value
          from v_lov_domain dv
         where dv.domain_code = 'AUDIT_ACTION'
           and dv.return_value = a.action)      as action_label,
       a.changed_by,
       a.changed_on,
       pkg_audit.describe(a.audit_id)           as change_summary
  from audit_log a
 where pkg_security.is_privileged
    or a.changed_by = pkg_security.current_username;

insert into domain_values (domain_code, value_code, label_en, label_ar, sort_order) values ('AUDIT_ACTION','INSERT','Created','إنشاء',10);
insert into domain_values (domain_code, value_code, label_en, label_ar, sort_order) values ('AUDIT_ACTION','UPDATE','Modified','تعديل',20);
insert into domain_values (domain_code, value_code, label_en, label_ar, sort_order) values ('AUDIT_ACTION','DELETE','Deleted','حذف',30);
commit;

prompt Audit layer installed.
