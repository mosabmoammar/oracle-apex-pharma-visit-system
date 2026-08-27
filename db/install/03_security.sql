--------------------------------------------------------------------------------
-- Pharma Visit System — 03_security.sql
-- Application context, PKG_SECURITY and the secure view layer.
--
-- Design note
--   Row scoping is centralised in ONE place. Every reporting query selects from
--   the V_SEC_* views, never from base tables. A new page therefore cannot
--   accidentally leak another team's data — the failure mode of per-page WHERE
--   clauses, which is the most common data-leak defect in APEX applications.
--
--   Oracle Label Security / VPD (DBMS_RLS) would express this more elegantly,
--   but both are Enterprise Edition features. This implementation runs on
--   Oracle XE and states the licensing trade-off explicitly.
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- 1. Application context, writable only by PKG_SECURITY
--------------------------------------------------------------------------------
create or replace context ctx_pvs using pkg_security;

--------------------------------------------------------------------------------
-- 2. Package specification
--------------------------------------------------------------------------------
create or replace package pkg_security as
  /**
   * Session identity and data scoping.
   *
   * set_context is called once per APEX session from the application process
   * "Initialise Security Context" (Point: On New Instance) and again by
   * PKG_API for every REST request, so both channels resolve identity
   * identically.
   */

  subtype t_role is varchar2(30);

  gc_role_rep        constant t_role := 'REP';
  gc_role_supervisor constant t_role := 'SUPERVISOR';
  gc_role_manager    constant t_role := 'SALES_MANAGER';
  gc_role_admin      constant t_role := 'SYS_ADMIN';

  procedure set_context (p_username in varchar2, p_lang in varchar2 default null);
  procedure clear_context;

  function current_user_id return number;
  function current_username return varchar2;
  function has_role (p_role_code in t_role) return varchar2;   -- 'Y' / 'N', for APEX authorization schemes
  function is_privileged return boolean;                        -- manager or admin

  -- Representatives visible to the current user, as a table for use in SQL.
  function visible_rep_ids return sys.odcinumberlist pipelined;

  -- Guard used by write APIs before touching another user's data.
  procedure assert_can_write_rep (p_rep_user_id in number);

  -- Assignment overlap check (BR: one active supervisor per rep at a time).
  procedure assert_no_assignment_overlap (
    p_rep_user_id   in number,
    p_valid_from    in date,
    p_valid_to      in date,
    p_assignment_id in number default null);
end pkg_security;
/

--------------------------------------------------------------------------------
-- 3. Package body
--------------------------------------------------------------------------------
create or replace package body pkg_security as

  gc_ctx constant varchar2(30) := 'CTX_PVS';

  ------------------------------------------------------------------
  procedure set_context (p_username in varchar2, p_lang in varchar2 default null) is
    l_user  app_users%rowtype;
    l_roles varchar2(400);
  begin
    select * into l_user
      from app_users
     where upper(username) = upper(p_username)
       and status = 'ACTIVE';

    -- Highest privilege wins when a user holds several roles.
    select listagg(r.role_code, ',') within group (order by
             case r.role_code
               when gc_role_admin      then 1
               when gc_role_manager    then 2
               when gc_role_supervisor then 3
               else 4
             end)
      into l_roles
      from user_roles ur
      join roles r on r.role_id = ur.role_id
     where ur.user_id = l_user.user_id;

    dbms_session.set_context(gc_ctx, 'USER_ID',  l_user.user_id);
    dbms_session.set_context(gc_ctx, 'USERNAME', l_user.username);
    dbms_session.set_context(gc_ctx, 'ROLES',    nvl(l_roles, 'NONE'));
    dbms_session.set_context(gc_ctx, 'LANG',
      lower(coalesce(p_lang, l_user.preferred_lang, 'en')));
  exception
    when no_data_found then
      pkg_i18n.raise_error(20001, p_username);
  end set_context;

  ------------------------------------------------------------------
  procedure clear_context is
  begin
    dbms_session.clear_context(gc_ctx);
  end clear_context;

  ------------------------------------------------------------------
  function current_user_id return number is
  begin
    return to_number(sys_context(gc_ctx, 'USER_ID'));
  end current_user_id;

  ------------------------------------------------------------------
  function current_username return varchar2 is
  begin
    return sys_context(gc_ctx, 'USERNAME');
  end current_username;

  ------------------------------------------------------------------
  function has_role (p_role_code in t_role) return varchar2 is
  begin
    return case
             when ',' || sys_context(gc_ctx, 'ROLES') || ',' like '%,' || p_role_code || ',%'
               then 'Y'
             else 'N'
           end;
  end has_role;

  ------------------------------------------------------------------
  function is_privileged return boolean is
  begin
    return has_role(gc_role_admin) = 'Y' or has_role(gc_role_manager) = 'Y';
  end is_privileged;

  ------------------------------------------------------------------
  function visible_rep_ids return sys.odcinumberlist pipelined is
    l_me number := current_user_id;
  begin
    if l_me is null then
      pkg_i18n.raise_error(20001);
    end if;

    if is_privileged then
      for r in (select user_id from app_users) loop
        pipe row (r.user_id);
      end loop;

    elsif has_role(gc_role_supervisor) = 'Y' then
      pipe row (l_me);
      for r in (
        select distinct a.rep_user_id
          from rep_assignments a
         where a.supervisor_user_id = l_me
           and trunc(sysdate) between a.valid_from and nvl(a.valid_to, date '4000-01-01'))
      loop
        pipe row (r.rep_user_id);
      end loop;

    else
      pipe row (l_me);
    end if;

    return;
  end visible_rep_ids;

  ------------------------------------------------------------------
  procedure assert_can_write_rep (p_rep_user_id in number) is
    l_ok number;
  begin
    if is_privileged then
      return;
    end if;

    -- A rep writes only own records; a supervisor writes for the current team.
    select count(*)
      into l_ok
      from table(visible_rep_ids)
     where column_value = p_rep_user_id;

    if l_ok = 0 then
      pkg_i18n.raise_error(20002, 'rep_id=' || p_rep_user_id);
    end if;
  end assert_can_write_rep;

  ------------------------------------------------------------------
  procedure assert_no_assignment_overlap (
    p_rep_user_id   in number,
    p_valid_from    in date,
    p_valid_to      in date,
    p_assignment_id in number default null) is
    l_cnt number;
  begin
    -- Two ranges overlap when each starts before the other ends.
    select count(*)
      into l_cnt
      from rep_assignments a
     where a.rep_user_id = p_rep_user_id
       and (p_assignment_id is null or a.assignment_id <> p_assignment_id)
       and a.valid_from <= nvl(p_valid_to, date '4000-01-01')
       and nvl(a.valid_to, date '4000-01-01') >= p_valid_from;

    if l_cnt > 0 then
      pkg_i18n.raise_error(20002, 'overlapping assignment');
    end if;
  end assert_no_assignment_overlap;

end pkg_security;
/

--------------------------------------------------------------------------------
-- 4. Secure views — the only objects APEX pages and reports select from.
--    Labels are already language-resolved, so no page repeats i18n logic either.
--------------------------------------------------------------------------------

create or replace view v_sec_visits as
select v.visit_id,
       v.rep_user_id,
       u.full_name                                              as rep_name,
       v.doctor_id,
       pkg_i18n.label(d.full_name_en, d.full_name_ar)            as doctor_name,
       pkg_i18n.label(d.specialty_en, d.specialty_ar)            as specialty,
       d.tier                                                    as doctor_tier,
       f.facility_id,
       pkg_i18n.label(f.facility_name_en, f.facility_name_ar)    as facility_name,
       f.region_id,
       pkg_i18n.label(r.region_name_en, r.region_name_ar)        as region_name,
       v.period_id,
       v.actual_start,
       v.actual_end,
       round((cast(v.actual_end as date) - cast(v.actual_start as date)) * 24 * 60) as duration_minutes,
       v.outcome,
       (select dv.display_value
          from v_lov_domain dv
         where dv.domain_code = 'VISIT_OUTCOME'
           and dv.return_value = v.outcome)                      as outcome_label,
       v.is_unplanned,
       v.plan_item_id,
       v.notes
  from visits v
  join app_users  u on u.user_id     = v.rep_user_id
  join doctors    d on d.doctor_id   = v.doctor_id
  join facilities f on f.facility_id = d.facility_id
  join regions    r on r.region_id   = f.region_id
 where v.rep_user_id in (select column_value from table(pkg_security.visible_rep_ids));


create or replace view v_sec_sample_balances as
select b.balance_id,
       b.rep_user_id,
       u.full_name                                            as rep_name,
       b.batch_id,
       pb.batch_no,
       pb.expiry_date,
       p.product_id,
       p.product_code,
       pkg_i18n.label(p.product_name_en, p.product_name_ar)    as product_name,
       b.quantity_on_hand,
       case when pb.expiry_date <= trunc(sysdate) then 'Y' else 'N' end as is_expired,
       case when pb.expiry_date <= add_months(trunc(sysdate), 3) then 'Y' else 'N' end as expiring_soon,
       b.last_movement_on
  from sample_balances  b
  join product_batches pb on pb.batch_id   = b.batch_id
  join products         p on p.product_id  = pb.product_id
  join app_users        u on u.user_id     = b.rep_user_id
 where b.rep_user_id in (select column_value from table(pkg_security.visible_rep_ids));


create or replace view v_sec_plans as
select pl.plan_id,
       pl.rep_user_id,
       u.full_name                          as rep_name,
       pl.period_id,
       pe.period_year,
       pe.period_month,
       pe.status                            as period_status,
       pl.status,
       (select dv.display_value
          from v_lov_domain dv
         where dv.domain_code = 'PLAN_STATUS'
           and dv.return_value = pl.status)  as status_label,
       pl.submitted_on,
       pl.approved_by,
       ap.full_name                         as approver_name,
       pl.approved_on,
       pl.reject_reason,
       (select count(*) from plan_items pi where pi.plan_id = pl.plan_id)                       as planned_visits,
       (select count(*) from plan_items pi
         where pi.plan_id = pl.plan_id and pi.item_status = 'EXECUTED')                          as executed_visits
  from visit_plans pl
  join app_users    u on u.user_id  = pl.rep_user_id
  join periods     pe on pe.period_id = pl.period_id
  left join app_users ap on ap.user_id = pl.approved_by
 where pl.rep_user_id in (select column_value from table(pkg_security.visible_rep_ids));


create or replace view v_sec_achievement as
select t.target_id,
       t.rep_user_id,
       u.full_name                                           as rep_name,
       t.product_id,
       pkg_i18n.label(p.product_name_en, p.product_name_ar)   as product_name,
       t.period_id,
       pe.period_year,
       pe.period_month,
       t.target_value,
       t.target_unit,
       nvl(a.achieved_value, 0)                              as achieved_value,
       case when t.target_value > 0
            then round(nvl(a.achieved_value,0) / t.target_value * 100, 2)
       end                                                    as achievement_pct,
       a.coverage_pct,
       a.calculated_on
  from targets  t
  join app_users u on u.user_id    = t.rep_user_id
  join products  p on p.product_id = t.product_id
  join periods  pe on pe.period_id = t.period_id
  left join achievement_snapshots a
         on a.target_id = t.target_id and a.period_id = t.period_id
 where t.rep_user_id in (select column_value from table(pkg_security.visible_rep_ids));

prompt Security layer installed.
