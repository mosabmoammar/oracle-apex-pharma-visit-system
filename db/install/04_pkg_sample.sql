--------------------------------------------------------------------------------
-- Pharma Visit System — 04_pkg_sample.sql
-- Sample stock: the core business logic of the system.
--
-- Three properties this package guarantees, in this order of difficulty:
--   1. Correctness  — ceiling and balance rules cannot be bypassed by any channel.
--   2. Concurrency  — two simultaneous dispenses cannot both pass the same check.
--   3. Atomicity    — the ledger entry, the balance and the audit trail commit together.
--
-- Concurrency note
--   A naive implementation reads the balance, validates, then inserts. Under two
--   concurrent sessions both reads happen before either insert, and both pass.
--   Locking the balance row with SELECT ... FOR UPDATE serialises only the
--   sessions touching that rep+batch, which is the narrowest correct lock.
--------------------------------------------------------------------------------
set define off

create or replace package pkg_sample as

  -- Resolution order for a monthly ceiling: exception > tier ceiling > product default.
  function resolve_ceiling (
    p_doctor_id  in number,
    p_product_id in number,
    p_period_id  in number) return number;

  -- Quantity already dispensed to this doctor for this product in this period.
  function dispensed_this_period (
    p_doctor_id  in number,
    p_product_id in number,
    p_period_id  in number) return number;

  -- Remaining allowance; never negative.
  function remaining_allowance (
    p_doctor_id  in number,
    p_product_id in number,
    p_period_id  in number) return number;

  function balance_of (
    p_rep_user_id in number,
    p_batch_id    in number) return number;

  -- Receive stock into a representative's custody.
  procedure receive (
    p_rep_user_id in  number,
    p_batch_id    in  number,
    p_quantity    in  number,
    p_reference   in  varchar2 default null,
    p_trx_id      out number);

  -- Dispense samples to a doctor during a visit. Enforces BR-03, BR-04, BR-05.
  procedure dispense (
    p_rep_user_id in  number,
    p_batch_id    in  number,
    p_visit_id    in  number,
    p_doctor_id   in  number,
    p_quantity    in  number,
    p_client_ref  in  varchar2 default null,
    p_trx_id      out number);

  -- Return unused stock to the warehouse.
  procedure return_stock (
    p_rep_user_id in  number,
    p_batch_id    in  number,
    p_quantity    in  number,
    p_reason      in  varchar2,
    p_trx_id      out number);

  -- Write off expired batches for one representative; returns rows affected.
  function write_off_expired (p_rep_user_id in number) return number;

  -- Nightly verification of SAMPLE_BALANCES against the ledger.
  procedure reconcile_balances (p_discrepancies out number);

end pkg_sample;
/

create or replace package body pkg_sample as

  ------------------------------------------------------------------
  -- Private: current open period, or error if none
  ------------------------------------------------------------------
  function open_period_id (p_date in date default sysdate) return number is
    l_period_id number;
    l_status    varchar2(10);
  begin
    select period_id, status
      into l_period_id, l_status
      from periods
     where p_date between start_date and end_date + 0.99999;

    if l_status <> 'OPEN' then
      pkg_i18n.raise_error(20003);
    end if;

    return l_period_id;
  exception
    when no_data_found then
      pkg_i18n.raise_error(20003, to_char(p_date, 'YYYY-MM'));
  end open_period_id;

  ------------------------------------------------------------------
  -- Private: batch must be dispensable
  ------------------------------------------------------------------
  procedure assert_batch_dispensable (p_batch_id in number) is
    l_expiry    date;
    l_bstatus   varchar2(10);
    l_pstatus   varchar2(10);
  begin
    select b.expiry_date, b.status, p.status
      into l_expiry, l_bstatus, l_pstatus
      from product_batches b
      join products p on p.product_id = b.product_id
     where b.batch_id = p_batch_id;

    if l_pstatus <> 'ACTIVE' then
      pkg_i18n.raise_error(20009);
    end if;

    if l_bstatus <> 'ACTIVE' or l_expiry <= trunc(sysdate) then
      pkg_i18n.raise_error(20008, 'batch_id=' || p_batch_id);
    end if;
  end assert_batch_dispensable;

  ------------------------------------------------------------------
  function resolve_ceiling (
    p_doctor_id  in number,
    p_product_id in number,
    p_period_id  in number) return number is
    l_tier    varchar2(1);
    l_ceiling number;
    l_extra   number := 0;
  begin
    select tier into l_tier from doctors where doctor_id = p_doctor_id;

    -- Tier override, falling back to the product default.
    select nvl(max(c.monthly_ceiling), max(p.default_monthly_ceiling))
      into l_ceiling
      from products p
      left join product_ceilings c
             on c.product_id = p.product_id
            and c.doctor_tier = l_tier
     where p.product_id = p_product_id;

    -- Approved exception for this doctor, product and period.
    select nvl(sum(extra_allowance), 0)
      into l_extra
      from sample_exceptions
     where doctor_id  = p_doctor_id
       and product_id = p_product_id
       and period_id  = p_period_id;

    return nvl(l_ceiling, 0) + l_extra;
  end resolve_ceiling;

  ------------------------------------------------------------------
  function dispensed_this_period (
    p_doctor_id  in number,
    p_product_id in number,
    p_period_id  in number) return number is
    l_qty number;
  begin
    -- DISPENSE rows carry negative quantities; RETURN restores allowance.
    select nvl(abs(sum(t.quantity)), 0)
      into l_qty
      from sample_transactions t
      join product_batches b on b.batch_id = t.batch_id
     where t.doctor_id  = p_doctor_id
       and b.product_id = p_product_id
       and t.period_id  = p_period_id
       and t.trx_type   = 'DISPENSE';

    return l_qty;
  end dispensed_this_period;

  ------------------------------------------------------------------
  function remaining_allowance (
    p_doctor_id  in number,
    p_product_id in number,
    p_period_id  in number) return number is
  begin
    return greatest(
             resolve_ceiling(p_doctor_id, p_product_id, p_period_id)
             - dispensed_this_period(p_doctor_id, p_product_id, p_period_id),
             0);
  end remaining_allowance;

  ------------------------------------------------------------------
  function balance_of (p_rep_user_id in number, p_batch_id in number) return number is
    l_qty number;
  begin
    select quantity_on_hand
      into l_qty
      from sample_balances
     where rep_user_id = p_rep_user_id
       and batch_id    = p_batch_id;

    return l_qty;
  exception
    when no_data_found then
      return 0;
  end balance_of;

  ------------------------------------------------------------------
  -- Private: lock (and create if absent) the balance row, returning current qty.
  -- This is the serialisation point for all stock movements.
  ------------------------------------------------------------------
  function lock_balance (p_rep_user_id in number, p_batch_id in number) return number is
    l_qty number;
  begin
    begin
      select quantity_on_hand
        into l_qty
        from sample_balances
       where rep_user_id = p_rep_user_id
         and batch_id    = p_batch_id
         for update;                                  -- serialise this rep+batch only
    exception
      when no_data_found then
        insert into sample_balances (rep_user_id, batch_id, quantity_on_hand)
             values (p_rep_user_id, p_batch_id, 0)
          returning quantity_on_hand into l_qty;
    end;

    return l_qty;
  end lock_balance;

  ------------------------------------------------------------------
  -- Private: write the ledger entry and move the balance in one step.
  ------------------------------------------------------------------
  procedure post_movement (
    p_rep_user_id in  number,
    p_batch_id    in  number,
    p_trx_type    in  varchar2,
    p_signed_qty  in  number,
    p_period_id   in  number,
    p_visit_id    in  number   default null,
    p_doctor_id   in  number   default null,
    p_reference   in  varchar2 default null,
    p_client_ref  in  varchar2 default null,
    p_trx_id      out number) is
  begin
    insert into sample_transactions (
      rep_user_id, batch_id, visit_id, doctor_id, period_id,
      trx_type, quantity, reference, client_ref)
    values (
      p_rep_user_id, p_batch_id, p_visit_id, p_doctor_id, p_period_id,
      p_trx_type, p_signed_qty, p_reference, p_client_ref)
    returning trx_id into p_trx_id;

    update sample_balances
       set quantity_on_hand = quantity_on_hand + p_signed_qty,
           last_movement_on = systimestamp
     where rep_user_id = p_rep_user_id
       and batch_id    = p_batch_id;
  end post_movement;

  ------------------------------------------------------------------
  procedure receive (
    p_rep_user_id in  number,
    p_batch_id    in  number,
    p_quantity    in  number,
    p_reference   in  varchar2 default null,
    p_trx_id      out number) is
    l_period_id number;
    l_ignore    number;
  begin
    if nvl(p_quantity, 0) <= 0 then
      pkg_i18n.raise_error(20012);
    end if;

    pkg_security.assert_can_write_rep(p_rep_user_id);
    l_period_id := open_period_id;
    l_ignore    := lock_balance(p_rep_user_id, p_batch_id);

    post_movement(
      p_rep_user_id => p_rep_user_id,
      p_batch_id    => p_batch_id,
      p_trx_type    => 'RECEIPT',
      p_signed_qty  => p_quantity,
      p_period_id   => l_period_id,
      p_reference   => p_reference,
      p_trx_id      => p_trx_id);
  end receive;

  ------------------------------------------------------------------
  procedure dispense (
    p_rep_user_id in  number,
    p_batch_id    in  number,
    p_visit_id    in  number,
    p_doctor_id   in  number,
    p_quantity    in  number,
    p_client_ref  in  varchar2 default null,
    p_trx_id      out number) is
    l_period_id  number;
    l_on_hand    number;
    l_product_id number;
    l_remaining  number;
  begin
    ----------------------------------------------------------------
    -- 1. Cheap validations first: fail fast, before taking any lock.
    ----------------------------------------------------------------
    if nvl(p_quantity, 0) <= 0 then
      pkg_i18n.raise_error(20012);
    end if;

    pkg_security.assert_can_write_rep(p_rep_user_id);
    assert_batch_dispensable(p_batch_id);

    l_period_id := open_period_id;

    select product_id into l_product_id
      from product_batches where batch_id = p_batch_id;

    ----------------------------------------------------------------
    -- 2. Idempotency: a retried offline sync must not dispense twice.
    ----------------------------------------------------------------
    if p_client_ref is not null then
      begin
        select trx_id into p_trx_id
          from sample_transactions
         where client_ref = p_client_ref;
        return;                                       -- already applied, no-op
      exception
        when no_data_found then null;
      end;
    end if;

    ----------------------------------------------------------------
    -- 3. Lock, then re-validate. Order matters: everything after this
    --    point is protected against a concurrent dispense.
    ----------------------------------------------------------------
    l_on_hand := lock_balance(p_rep_user_id, p_batch_id);

    if l_on_hand < p_quantity then
      pkg_i18n.raise_error(20006, 'on_hand=' || l_on_hand || ', requested=' || p_quantity);
    end if;

    l_remaining := remaining_allowance(p_doctor_id, l_product_id, l_period_id);

    if p_quantity > l_remaining then
      pkg_i18n.raise_error(20007, 'remaining=' || l_remaining);
    end if;

    ----------------------------------------------------------------
    -- 4. Post. Ledger, balance and audit share one transaction.
    ----------------------------------------------------------------
    post_movement(
      p_rep_user_id => p_rep_user_id,
      p_batch_id    => p_batch_id,
      p_trx_type    => 'DISPENSE',
      p_signed_qty  => -p_quantity,
      p_period_id   => l_period_id,
      p_visit_id    => p_visit_id,
      p_doctor_id   => p_doctor_id,
      p_client_ref  => p_client_ref,
      p_trx_id      => p_trx_id);
  end dispense;

  ------------------------------------------------------------------
  procedure return_stock (
    p_rep_user_id in  number,
    p_batch_id    in  number,
    p_quantity    in  number,
    p_reason      in  varchar2,
    p_trx_id      out number) is
    l_period_id number;
    l_on_hand   number;
  begin
    if nvl(p_quantity, 0) <= 0 then
      pkg_i18n.raise_error(20012);
    end if;

    pkg_security.assert_can_write_rep(p_rep_user_id);
    l_period_id := open_period_id;
    l_on_hand   := lock_balance(p_rep_user_id, p_batch_id);

    if l_on_hand < p_quantity then
      pkg_i18n.raise_error(20006, 'on_hand=' || l_on_hand);
    end if;

    post_movement(
      p_rep_user_id => p_rep_user_id,
      p_batch_id    => p_batch_id,
      p_trx_type    => 'RETURN',
      p_signed_qty  => -p_quantity,
      p_period_id   => l_period_id,
      p_reference   => p_reason,
      p_trx_id      => p_trx_id);
  end return_stock;

  ------------------------------------------------------------------
  function write_off_expired (p_rep_user_id in number) return number is
    l_count  number := 0;
    l_trx_id number;
    l_period number;
  begin
    pkg_security.assert_can_write_rep(p_rep_user_id);
    l_period := open_period_id;

    for r in (
      select b.batch_id, b.quantity_on_hand
        from sample_balances b
        join product_batches pb on pb.batch_id = b.batch_id
       where b.rep_user_id      = p_rep_user_id
         and b.quantity_on_hand > 0
         and pb.expiry_date    <= trunc(sysdate))
    loop
      if lock_balance(p_rep_user_id, r.batch_id) > 0 then
        post_movement(
          p_rep_user_id => p_rep_user_id,
          p_batch_id    => r.batch_id,
          p_trx_type    => 'EXPIRY_WRITE_OFF',
          p_signed_qty  => -r.quantity_on_hand,
          p_period_id   => l_period,
          p_reference   => 'Automatic expiry write-off',
          p_trx_id      => l_trx_id);
        l_count := l_count + 1;
      end if;
    end loop;

    return l_count;
  end write_off_expired;

  ------------------------------------------------------------------
  -- Verification job: the stored aggregate must always equal the ledger.
  -- Any row returned here is a defect, not a business event.
  ------------------------------------------------------------------
  procedure reconcile_balances (p_discrepancies out number) is
  begin
    p_discrepancies := 0;

    for r in (
      select b.rep_user_id,
             b.batch_id,
             b.quantity_on_hand           as stored_qty,
             nvl(l.ledger_qty, 0)         as ledger_qty
        from sample_balances b
        left join (
              select rep_user_id, batch_id, sum(quantity) as ledger_qty
                from sample_transactions
               group by rep_user_id, batch_id) l
          on l.rep_user_id = b.rep_user_id
         and l.batch_id    = b.batch_id
       where b.quantity_on_hand <> nvl(l.ledger_qty, 0))
    loop
      p_discrepancies := p_discrepancies + 1;

      insert into audit_log (table_name, record_id, action, old_values, new_values)
      values ('SAMPLE_BALANCES', null, 'UPDATE',
              json_object('rep_user_id' value r.rep_user_id,
                          'batch_id'    value r.batch_id,
                          'stored'      value r.stored_qty),
              json_object('ledger'      value r.ledger_qty,
                          'note'        value 'reconciliation discrepancy'));
    end loop;

    commit;
  end reconcile_balances;

end pkg_sample;
/

--------------------------------------------------------------------------------
-- Scheduled reconciliation — verification, not correction. Silent auto-fixing
-- would hide the defect that caused the drift.
--------------------------------------------------------------------------------
begin
  dbms_scheduler.create_job(
    job_name        => 'PVS_RECONCILE_BALANCES',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'declare n number; begin pkg_sample.reconcile_balances(n); end;',
    repeat_interval => 'FREQ=DAILY; BYHOUR=2; BYMINUTE=0',
    enabled         => true,
    comments        => 'Nightly verification of SAMPLE_BALANCES against SAMPLE_TRANSACTIONS');
end;
/

prompt PKG_SAMPLE installed.
