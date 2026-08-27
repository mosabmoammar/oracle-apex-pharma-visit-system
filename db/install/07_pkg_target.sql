--------------------------------------------------------------------------------
-- Pharma Visit System — 07_pkg_target.sql
-- Targets, achievement calculation and the dashboard aggregate layer.
--
-- Performance position
--   Achievement is NOT computed per row on the dashboard. It is computed in one
--   set-based statement per period, written to ACHIEVEMENT_SNAPSHOTS with
--   FORALL, and read from there. A dashboard that recalculates on every page
--   view looks fine on 100 rows and collapses on 100,000.
--------------------------------------------------------------------------------
set define off

insert into error_messages values (20021,
  'Achievement cannot be recalculated for a closed period.',
  'لا يمكن إعادة احتساب الإنجاز لفترة مغلقة.');
insert into error_messages values (20022,
  'Setting targets requires the sales manager role.',
  'تحديد الأهداف يتطلب صلاحية مدير المبيعات.');
commit;

--------------------------------------------------------------------------------
-- Package specification
--------------------------------------------------------------------------------
create or replace package pkg_target as

  -- Weighting used when target_unit = 'POINTS'
  gc_weight_tier_a constant number := 3;
  gc_weight_tier_b constant number := 2;
  gc_weight_tier_c constant number := 1;

  procedure set_target (
    p_rep_user_id in  number,
    p_product_id  in  number,
    p_period_id   in  number,
    p_target_value in number,
    p_target_unit in  varchar2 default 'VISITS',
    p_target_id   out number);

  procedure copy_targets (p_from_period_id in number, p_to_period_id in number, p_factor in number default 1);

  -- Recalculates every snapshot for the period. Safe to re-run.
  procedure calculate_achievement (p_period_id in number, p_rows out number);

  function coverage_pct (p_rep_user_id in number, p_period_id in number) return number;

  procedure refresh_dashboards;

end pkg_target;
/

--------------------------------------------------------------------------------
-- Package body
--------------------------------------------------------------------------------
create or replace package body pkg_target as

  ------------------------------------------------------------------
  procedure assert_manager is
  begin
    if not pkg_security.is_privileged then
      pkg_i18n.raise_error(20022);
    end if;
  end assert_manager;

  ------------------------------------------------------------------
  procedure set_target (
    p_rep_user_id  in  number,
    p_product_id   in  number,
    p_period_id    in  number,
    p_target_value in  number,
    p_target_unit  in  varchar2 default 'VISITS',
    p_target_id    out number) is
    l_status varchar2(10);
  begin
    assert_manager;

    if nvl(p_target_value, 0) <= 0 then
      pkg_i18n.raise_error(20012);
    end if;

    select status into l_status from periods where period_id = p_period_id;
    if l_status <> 'OPEN' then
      pkg_i18n.raise_error(20003);
    end if;

    -- The unique constraint is the real guard against duplicate targets;
    -- catching it here turns an ORA-00001 into a business message.
    begin
      insert into targets (rep_user_id, product_id, period_id, target_value, target_unit)
           values (p_rep_user_id, p_product_id, p_period_id, p_target_value, p_target_unit)
        returning target_id into p_target_id;
    exception
      when dup_val_on_index then
        pkg_i18n.raise_error(20011);
    end;
  end set_target;

  ------------------------------------------------------------------
  -- Bulk copy of a period's targets, optionally uplifted by a factor.
  -- Written as a single INSERT ... SELECT: a row-by-row loop here would be
  -- the classic "slow by slow" anti-pattern.
  ------------------------------------------------------------------
  procedure copy_targets (
    p_from_period_id in number,
    p_to_period_id   in number,
    p_factor         in number default 1) is
    l_status varchar2(10);
  begin
    assert_manager;

    select status into l_status from periods where period_id = p_to_period_id;
    if l_status <> 'OPEN' then
      pkg_i18n.raise_error(20003);
    end if;

    insert into targets (rep_user_id, product_id, period_id, target_value, target_unit)
    select t.rep_user_id,
           t.product_id,
           p_to_period_id,
           round(t.target_value * nvl(p_factor, 1), 2),
           t.target_unit
      from targets t
     where t.period_id = p_from_period_id
       and not exists (select 1
                         from targets x
                        where x.rep_user_id = t.rep_user_id
                          and x.product_id  = t.product_id
                          and x.period_id   = p_to_period_id);
  end copy_targets;

  ------------------------------------------------------------------
  function coverage_pct (p_rep_user_id in number, p_period_id in number) return number is
    l_planned  number;
    l_executed number;
  begin
    select count(*),
           count(case when pi.item_status = 'EXECUTED' then 1 end)
      into l_planned, l_executed
      from plan_items pi
      join visit_plans pl on pl.plan_id = pi.plan_id
     where pl.rep_user_id = p_rep_user_id
       and pl.period_id   = p_period_id
       and pl.status      = 'APPROVED'
       and pi.item_status <> 'CANCELLED';

    return case when l_planned > 0
                then round(l_executed / l_planned * 100, 2)
           end;
  end coverage_pct;

  ------------------------------------------------------------------
  -- Achievement per target, by unit:
  --   VISITS  -> completed visits where the product was discussed
  --   SAMPLES -> quantity dispensed of that product
  --   POINTS  -> completed visits weighted by doctor tier
  ------------------------------------------------------------------
  procedure calculate_achievement (p_period_id in number, p_rows out number) is

    type t_id_tab  is table of number index by pls_integer;
    type t_val_tab is table of number index by pls_integer;

    l_target_ids t_id_tab;
    l_values     t_val_tab;
    l_coverage   t_val_tab;

    l_status varchar2(10);
  begin
    assert_manager;

    select status into l_status from periods where period_id = p_period_id;
    if l_status = 'CLOSED' then
      pkg_i18n.raise_error(20021);
    end if;

    -- One pass over the period, all three units resolved in the same statement.
    select t.target_id,
           nvl(a.achieved, 0),
           nvl(c.cov, 0)
      bulk collect into l_target_ids, l_values, l_coverage
      from targets t
      left join (
            select t2.target_id,
                   case t2.target_unit
                     when 'VISITS' then
                       (select count(distinct v.visit_id)
                          from visits v
                          join visit_products vp on vp.visit_id = v.visit_id
                         where v.rep_user_id = t2.rep_user_id
                           and v.period_id   = t2.period_id
                           and v.outcome     = 'COMPLETED'
                           and vp.product_id = t2.product_id)
                     when 'SAMPLES' then
                       (select nvl(abs(sum(st.quantity)), 0)
                          from sample_transactions st
                          join product_batches b on b.batch_id = st.batch_id
                         where st.rep_user_id = t2.rep_user_id
                           and st.period_id   = t2.period_id
                           and st.trx_type    = 'DISPENSE'
                           and b.product_id   = t2.product_id)
                     when 'POINTS' then
                       (select nvl(sum(case d.tier
                                         when 'A' then gc_weight_tier_a
                                         when 'B' then gc_weight_tier_b
                                         else gc_weight_tier_c
                                       end), 0)
                          from visits v
                          join doctors d on d.doctor_id = v.doctor_id
                          join visit_products vp on vp.visit_id = v.visit_id
                         where v.rep_user_id = t2.rep_user_id
                           and v.period_id   = t2.period_id
                           and v.outcome     = 'COMPLETED'
                           and vp.product_id = t2.product_id)
                   end as achieved
              from targets t2
             where t2.period_id = p_period_id) a
        on a.target_id = t.target_id
      left join (
            select pl.rep_user_id,
                   round(count(case when pi.item_status = 'EXECUTED' then 1 end)
                         / nullif(count(*), 0) * 100, 2) as cov
              from visit_plans pl
              join plan_items  pi on pi.plan_id = pl.plan_id
             where pl.period_id = p_period_id
               and pl.status    = 'APPROVED'
               and pi.item_status <> 'CANCELLED'
             group by pl.rep_user_id) c
        on c.rep_user_id = t.rep_user_id
     where t.period_id = p_period_id;

    -- Single round trip to the SQL engine for the whole period.
    forall i in 1 .. l_target_ids.count
      merge into achievement_snapshots s
      using (select l_target_ids(i) as target_id, p_period_id as period_id from dual) x
         on (s.target_id = x.target_id and s.period_id = x.period_id)
       when matched then
         update set s.achieved_value = l_values(i),
                    s.coverage_pct   = l_coverage(i),
                    s.calculated_on  = systimestamp
       when not matched then
         insert (target_id, period_id, achieved_value, coverage_pct)
         values (x.target_id, x.period_id, l_values(i), l_coverage(i));

    p_rows := l_target_ids.count;
  end calculate_achievement;

  ------------------------------------------------------------------
  procedure refresh_dashboards is
  begin
    dbms_mview.refresh('MV_REGION_PERFORMANCE', method => 'C');
  end refresh_dashboards;

end pkg_target;
/

--------------------------------------------------------------------------------
-- Dashboard layer
--
-- Two different shapes on purpose:
--   * per-user KPIs  -> a view, because it is filtered to a handful of rows
--   * regional roll-up -> a materialized view, because it scans the full period
--------------------------------------------------------------------------------

create or replace view v_dash_rep_kpi as
select r.rep_user_id,
       r.rep_name,
       r.period_id,
       r.visits_completed,
       r.visits_planned,
       case when r.visits_planned > 0
            then round(r.visits_completed / r.visits_planned * 100, 2)
       end                                        as coverage_pct,
       r.doctors_reached,
       r.samples_dispensed,
       r.avg_duration_minutes
  from (
    select v.rep_user_id,
           max(v.rep_name)                                                as rep_name,
           v.period_id,
           count(case when v.outcome = 'COMPLETED' then 1 end)            as visits_completed,
           (select count(*)
              from plan_items pi
              join visit_plans pl on pl.plan_id = pi.plan_id
             where pl.rep_user_id = v.rep_user_id
               and pl.period_id   = v.period_id
               and pl.status      = 'APPROVED'
               and pi.item_status <> 'CANCELLED')                          as visits_planned,
           count(distinct v.doctor_id)                                    as doctors_reached,
           (select nvl(abs(sum(st.quantity)), 0)
              from sample_transactions st
             where st.rep_user_id = v.rep_user_id
               and st.period_id   = v.period_id
               and st.trx_type    = 'DISPENSE')                            as samples_dispensed,
           round(avg(v.duration_minutes))                                 as avg_duration_minutes
      from v_sec_visits v
     group by v.rep_user_id, v.period_id) r;


create materialized view log on visits with rowid (rep_user_id, doctor_id, period_id, outcome) including new values;

create materialized view mv_region_performance
build immediate
refresh complete on demand
as
select f.region_id,
       r.region_name_en,
       r.region_name_ar,
       v.period_id,
       count(*)                                                as total_visits,
       count(case when v.outcome = 'COMPLETED' then 1 end)     as completed_visits,
       count(distinct v.doctor_id)                             as doctors_visited,
       count(distinct v.rep_user_id)                           as active_reps,
       count(case when d.tier = 'A' and v.outcome = 'COMPLETED' then 1 end) as tier_a_visits
  from visits     v
  join doctors    d on d.doctor_id   = v.doctor_id
  join facilities f on f.facility_id = d.facility_id
  join regions    r on r.region_id   = f.region_id
 group by f.region_id, r.region_name_en, r.region_name_ar, v.period_id;

create unique index mv_region_perf_uk on mv_region_performance (region_id, period_id);

-- Language resolution happens at read time so one MV serves both languages.
create or replace view v_dash_region_performance as
select m.region_id,
       pkg_i18n.label(m.region_name_en, m.region_name_ar) as region_name,
       m.period_id,
       p.period_year,
       p.period_month,
       m.total_visits,
       m.completed_visits,
       m.doctors_visited,
       m.active_reps,
       m.tier_a_visits,
       round(m.completed_visits / nullif(m.total_visits, 0) * 100, 2) as completion_rate
  from mv_region_performance m
  join periods p on p.period_id = m.period_id;

--------------------------------------------------------------------------------
-- Scheduled recalculation for the current open period
--------------------------------------------------------------------------------
begin
  dbms_scheduler.create_job(
    job_name        => 'PVS_CALC_ACHIEVEMENT',
    job_type        => 'PLSQL_BLOCK',
    job_action      => q'[
      declare
        l_period number;
        l_rows   number;
      begin
        select period_id into l_period from periods where status = 'OPEN'
           and trunc(sysdate) between start_date and end_date;
        pkg_target.calculate_achievement(l_period, l_rows);
        pkg_target.refresh_dashboards;
      exception
        when no_data_found then null;
      end;]',
    repeat_interval => 'FREQ=HOURLY; BYMINUTE=15',
    enabled         => true,
    comments        => 'Hourly achievement recalculation and dashboard refresh');
end;
/

prompt PKG_TARGET and dashboard layer installed.
