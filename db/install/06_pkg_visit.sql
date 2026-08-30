--------------------------------------------------------------------------------
-- Pharma Visit System — 06_pkg_visit.sql
-- Visit execution and offline synchronisation.
--
-- One rule about this package: the APEX pages and the REST endpoints call
-- exactly these procedures. Nothing writes to VISITS directly. That is what
-- makes "the mobile app enforces the same rules as the web app" a structural
-- guarantee rather than a promise in a document.
--------------------------------------------------------------------------------
set define off

insert into error_messages values (20018,
  'This plan item has already been executed.',
  'تم تنفيذ هذا البند من الخطة مسبقًا.');
insert into error_messages values (20019,
  'Visits can only be recorded against an approved plan.',
  'لا يمكن تسجيل الزيارات إلا ضمن خطة معتمدة.');
insert into error_messages values (20020,
  'A reason is required for this outcome.',
  'يجب ذكر السبب لهذه النتيجة.');
commit;

--------------------------------------------------------------------------------
-- Object type for the offline sync result set
--------------------------------------------------------------------------------
create or replace type t_sync_result as object (
  client_ref   varchar2(64),
  status       varchar2(10),   -- ACCEPTED | DUPLICATE | REJECTED
  visit_id     number,
  error_code   number,
  error_text   varchar2(400)
);
/
create or replace type t_sync_results as table of t_sync_result;
/

--------------------------------------------------------------------------------
-- Package specification
--------------------------------------------------------------------------------
create or replace package pkg_visit as

  -- Record execution of a planned visit.
  procedure execute_planned (
    p_plan_item_id in  number,
    p_actual_start in  timestamp with local time zone,
    p_actual_end   in  timestamp with local time zone,
    p_outcome      in  varchar2,
    p_reason       in  varchar2 default null,
    p_notes        in  clob     default null,
    p_client_ref   in  varchar2 default null,
    p_visit_id     out number);

  -- Record a visit that was not in the approved plan.
  procedure record_unplanned (
    p_rep_user_id  in  number,
    p_doctor_id    in  number,
    p_actual_start in  timestamp with local time zone,
    p_actual_end   in  timestamp with local time zone,
    p_outcome      in  varchar2,
    p_reason       in  varchar2,
    p_notes        in  clob     default null,
    p_client_ref   in  varchar2 default null,
    p_visit_id     out number);

  -- Attach a discussed product with feedback.
  procedure add_product (
    p_visit_id   in number,
    p_product_id in number,
    p_feedback   in varchar2 default null);

  -- Reverse a visit. Visits are never deleted; the reversal is auditable.
  procedure cancel_visit (p_visit_id in number, p_reason in varchar2);

  -- Batch import from an offline client. Each item succeeds or fails
  -- independently; one bad row must not discard the whole upload.
  function sync_batch (p_payload in clob) return t_sync_results pipelined;

end pkg_visit;
/

--------------------------------------------------------------------------------
-- Package body
--------------------------------------------------------------------------------
create or replace package body pkg_visit as

  ------------------------------------------------------------------
  function period_of (p_ts in timestamp with local time zone) return number is
    l_period_id number;
    l_status    varchar2(10);
    l_date      date := cast(p_ts as date);
  begin
    select period_id, status
      into l_period_id, l_status
      from periods
     where l_date between start_date and end_date + 0.99999;

    if l_status <> 'OPEN' then
      pkg_i18n.raise_error(20003);
    end if;

    return l_period_id;
  exception
    when no_data_found then
      pkg_i18n.raise_error(20003, to_char(l_date, 'YYYY-MM'));
  end period_of;

  ------------------------------------------------------------------
  procedure validate_times (
    p_start in timestamp with local time zone,
    p_end   in timestamp with local time zone) is
  begin
    if p_end <= p_start then
      pkg_i18n.raise_error(20015, 'end <= start');
    end if;

    -- A visit cannot be recorded before it happened.
    if p_start > systimestamp then
      pkg_i18n.raise_error(20010);
    end if;
  end validate_times;

  ------------------------------------------------------------------
  procedure validate_outcome (p_outcome in varchar2, p_reason in varchar2) is
    l_ok number;
  begin
    select count(*) into l_ok
      from domain_values
     where domain_code = 'VISIT_OUTCOME'
       and value_code  = p_outcome
       and status      = 'ACTIVE';

    if l_ok = 0 then
      pkg_i18n.raise_error(20014, 'outcome=' || p_outcome);
    end if;

    if p_outcome <> 'COMPLETED' and trim(p_reason) is null then
      pkg_i18n.raise_error(20020);
    end if;
  end validate_outcome;

  ------------------------------------------------------------------
  -- Serialisation point for a representative's timeline.
  -- Locking the parent user row is cheaper and less deadlock-prone than
  -- locking a range of visit rows, and it is held only until commit.
  ------------------------------------------------------------------
  procedure lock_rep (p_rep_user_id in number) is
    l_id number;
  begin
    select user_id into l_id
      from app_users
     where user_id = p_rep_user_id
       for update;
  end lock_rep;

  ------------------------------------------------------------------
  procedure assert_no_visit_overlap (
    p_rep_user_id in number,
    p_start       in timestamp with local time zone,
    p_end         in timestamp with local time zone,
    p_visit_id    in number default null) is
    l_cnt number;
  begin
    select count(*)
      into l_cnt
      from visits v
     where v.rep_user_id = p_rep_user_id
       and v.outcome    <> 'CANCELLED'
       and (p_visit_id is null or v.visit_id <> p_visit_id)
       and v.actual_start < p_end
       and v.actual_end   > p_start;

    if l_cnt > 0 then
      pkg_i18n.raise_error(20004);
    end if;
  end assert_no_visit_overlap;

  ------------------------------------------------------------------
  -- Returns an existing visit for this client reference, or null.
  ------------------------------------------------------------------
  function existing_by_ref (p_client_ref in varchar2) return number is
    l_visit_id number;
  begin
    if p_client_ref is null then
      return null;
    end if;

    select visit_id into l_visit_id
      from visits
     where client_ref = p_client_ref;

    return l_visit_id;
  exception
    when no_data_found then
      return null;
  end existing_by_ref;

  ------------------------------------------------------------------
  procedure execute_planned (
    p_plan_item_id in  number,
    p_actual_start in  timestamp with local time zone,
    p_actual_end   in  timestamp with local time zone,
    p_outcome      in  varchar2,
    p_reason       in  varchar2 default null,
    p_notes        in  clob     default null,
    p_client_ref   in  varchar2 default null,
    p_visit_id     out number) is
    l_item      plan_items%rowtype;
    l_plan      visit_plans%rowtype;
    l_period_id number;
    l_existing  number;
  begin
    l_existing := existing_by_ref(p_client_ref);
    if l_existing is not null then
      p_visit_id := l_existing;                        -- idempotent replay
      return;
    end if;

    select * into l_item from plan_items where plan_item_id = p_plan_item_id;
    select * into l_plan from visit_plans where plan_id = l_item.plan_id;

    pkg_security.assert_can_write_rep(l_plan.rep_user_id);

    if l_plan.status <> pkg_plan.gc_status_approved then
      pkg_i18n.raise_error(20019);
    end if;

    if l_item.item_status = 'EXECUTED' then
      pkg_i18n.raise_error(20018);
    end if;

    validate_times(p_actual_start, p_actual_end);
    validate_outcome(p_outcome, p_reason);
    l_period_id := period_of(p_actual_start);

    lock_rep(l_plan.rep_user_id);
    assert_no_visit_overlap(l_plan.rep_user_id, p_actual_start, p_actual_end);

    insert into visits (
      plan_item_id, rep_user_id, doctor_id, period_id,
      actual_start, actual_end, outcome, is_unplanned, reason, notes, client_ref)
    values (
      p_plan_item_id, l_plan.rep_user_id, l_item.doctor_id, l_period_id,
      p_actual_start, p_actual_end, p_outcome, 'N', p_reason, p_notes, p_client_ref)
    returning visit_id into p_visit_id;

    update plan_items
       set item_status = case when p_outcome = 'COMPLETED' then 'EXECUTED' else 'MISSED' end
     where plan_item_id = p_plan_item_id;

  exception
    when no_data_found then
      pkg_i18n.raise_error(20002, 'plan_item_id=' || p_plan_item_id);
  end execute_planned;

  ------------------------------------------------------------------
  procedure record_unplanned (
    p_rep_user_id  in  number,
    p_doctor_id    in  number,
    p_actual_start in  timestamp with local time zone,
    p_actual_end   in  timestamp with local time zone,
    p_outcome      in  varchar2,
    p_reason       in  varchar2,
    p_notes        in  clob     default null,
    p_client_ref   in  varchar2 default null,
    p_visit_id     out number) is
    l_period_id number;
    l_existing  number;
  begin
    l_existing := existing_by_ref(p_client_ref);
    if l_existing is not null then
      p_visit_id := l_existing;
      return;
    end if;

    if trim(p_reason) is null then
      pkg_i18n.raise_error(20020);
    end if;

    pkg_security.assert_can_write_rep(p_rep_user_id);
    validate_times(p_actual_start, p_actual_end);
    validate_outcome(p_outcome, p_reason);
    l_period_id := period_of(p_actual_start);

    lock_rep(p_rep_user_id);
    assert_no_visit_overlap(p_rep_user_id, p_actual_start, p_actual_end);

    insert into visits (
      plan_item_id, rep_user_id, doctor_id, period_id,
      actual_start, actual_end, outcome, is_unplanned, reason, notes, client_ref)
    values (
      null, p_rep_user_id, p_doctor_id, l_period_id,
      p_actual_start, p_actual_end, p_outcome, 'Y', p_reason, p_notes, p_client_ref)
    returning visit_id into p_visit_id;
  end record_unplanned;

  ------------------------------------------------------------------
  procedure add_product (
    p_visit_id   in number,
    p_product_id in number,
    p_feedback   in varchar2 default null) is
    l_rep number;
  begin
    select rep_user_id into l_rep from visits where visit_id = p_visit_id;
    pkg_security.assert_can_write_rep(l_rep);

    merge into visit_products t
    using (select p_visit_id as visit_id, p_product_id as product_id from dual) s
       on (t.visit_id = s.visit_id and t.product_id = s.product_id)
     when matched then
       update set t.feedback = p_feedback
     when not matched then
       insert (visit_id, product_id, feedback)
       values (s.visit_id, s.product_id, p_feedback);
  end add_product;

  ------------------------------------------------------------------
  procedure cancel_visit (p_visit_id in number, p_reason in varchar2) is
    l_visit visits%rowtype;
    l_trx   number;
  begin
    if trim(p_reason) is null then
      pkg_i18n.raise_error(20020);
    end if;

    select * into l_visit from visits where visit_id = p_visit_id for update;
    pkg_security.assert_can_write_rep(l_visit.rep_user_id);

    -- Period gate: a closed month cannot be rewritten.
    declare
      l_status varchar2(10);
    begin
      select status into l_status from periods where period_id = l_visit.period_id;
      if l_status <> 'OPEN' then
        pkg_i18n.raise_error(20003);
      end if;
    end;

    -- Samples dispensed during the visit are returned to stock by reversing
    -- entries, never by deleting the original ledger rows.
    for r in (select trx_id, batch_id, quantity
                from sample_transactions
               where visit_id = p_visit_id
                 and trx_type = 'DISPENSE')
    loop
      pkg_sample.return_stock(
        p_rep_user_id => l_visit.rep_user_id,
        p_batch_id    => r.batch_id,
        p_quantity    => abs(r.quantity) * -1 * -1,   -- explicit: positive quantity
        p_reason      => 'Reversal of cancelled visit ' || p_visit_id,
        p_trx_id      => l_trx);
    end loop;

    update visits
       set outcome    = 'CANCELLED',
           reason     = p_reason,
           updated_by = pkg_security.current_username,
           updated_on = systimestamp
     where visit_id = p_visit_id;

    if l_visit.plan_item_id is not null then
      update plan_items set item_status = 'PLANNED' where plan_item_id = l_visit.plan_item_id;
    end if;
  end cancel_visit;

  ------------------------------------------------------------------
  -- Offline sync.
  --
  -- Per-item savepoint: a rejected row rolls back only its own work, so a
  -- single invalid visit in a batch of fifty does not discard the other
  -- forty-nine. The caller receives a per-item verdict and can display
  -- exactly which entries failed and why.
  ------------------------------------------------------------------
  function sync_batch (p_payload in clob) return t_sync_results pipelined is
    l_visit_id number;
    l_trx_id   number;
  begin
    for j in (
      select *
        from json_table(p_payload, '$.visits[*]'
             columns (
               client_ref    varchar2(64)  path '$.client_ref',
               plan_item_id  number        path '$.plan_item_id',
               rep_user_id   number        path '$.rep_user_id',
               doctor_id     number        path '$.doctor_id',
               actual_start  timestamp     path '$.actual_start',
               actual_end    timestamp     path '$.actual_end',
               outcome       varchar2(15)  path '$.outcome',
               reason        varchar2(400) path '$.reason',
               notes         varchar2(4000) path '$.notes',
               samples       varchar2(4000) format json path '$.samples')))
    loop
      begin
        savepoint sp_item;

        if existing_by_ref(j.client_ref) is not null then
          pipe row (t_sync_result(j.client_ref, 'DUPLICATE', existing_by_ref(j.client_ref), null, null));
        else
          if j.plan_item_id is not null then
            execute_planned(
              p_plan_item_id => j.plan_item_id,
              p_actual_start => j.actual_start,
              p_actual_end   => j.actual_end,
              p_outcome      => j.outcome,
              p_reason       => j.reason,
              p_notes        => j.notes,
              p_client_ref   => j.client_ref,
              p_visit_id     => l_visit_id);
          else
            record_unplanned(
              p_rep_user_id  => j.rep_user_id,
              p_doctor_id    => j.doctor_id,
              p_actual_start => j.actual_start,
              p_actual_end   => j.actual_end,
              p_outcome      => j.outcome,
              p_reason       => j.reason,
              p_notes        => j.notes,
              p_client_ref   => j.client_ref,
              p_visit_id     => l_visit_id);
          end if;

          -- Nested sample lines, validated by PKG_SAMPLE exactly as on the web.
          if j.samples is not null then
            for s in (
              select *
                from json_table(j.samples, '$[*]'
                     columns (
                       batch_id   number       path '$.batch_id',
                       quantity   number       path '$.quantity',
                       client_ref varchar2(64) path '$.client_ref')))
            loop
              declare
                l_rep number := j.rep_user_id;
                l_doc number := j.doctor_id;
              begin
                if l_rep is null or l_doc is null then
                  select rep_user_id, doctor_id
                    into l_rep, l_doc
                    from visits where visit_id = l_visit_id;
                end if;

                pkg_sample.dispense(
                  p_rep_user_id => l_rep,
                  p_batch_id    => s.batch_id,
                  p_visit_id    => l_visit_id,
                  p_doctor_id   => l_doc,
                  p_quantity    => s.quantity,
                  p_client_ref  => s.client_ref,
                  p_trx_id      => l_trx_id);
              end;
            end loop;
          end if;

          pipe row (t_sync_result(j.client_ref, 'ACCEPTED', l_visit_id, null, null));
        end if;

      exception
        when others then
          rollback to sp_item;
          pipe row (t_sync_result(j.client_ref, 'REJECTED', null, sqlcode, substr(sqlerrm, 1, 400)));
      end;
    end loop;

    return;
  end sync_batch;

end pkg_visit;
/

prompt PKG_VISIT installed.
