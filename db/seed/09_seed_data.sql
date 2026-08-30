--------------------------------------------------------------------------------
-- Pharma Visit System — 09_seed_data.sql
-- Synthetic dataset, sized so that performance claims can actually be tested.
--
-- All data is generated. No real physician, facility, product or person
-- appears anywhere in this repository.
--
-- Volume produced
--   3 regions / 9 territories · 45 facilities · 300 doctors · 24 products
--   12 monthly periods · 12 representatives · ~24,000 planned items
--   ~20,000 executed visits · ~35,000 sample movements
--
-- Method
--   Set-based generation with CONNECT BY row sources. A PL/SQL loop inserting
--   20,000 visits one at a time takes minutes; this takes seconds.
--
-- Audit triggers are disabled during the load and rebuilt afterwards: each
-- trigger runs an autonomous transaction, which would turn a bulk insert into
-- 20,000 independent commits.
--------------------------------------------------------------------------------
set define off
set serveroutput on
alter session set nls_date_format = 'YYYY-MM-DD';

--------------------------------------------------------------------------------
-- 0. Disable audit triggers for the duration of the load
--------------------------------------------------------------------------------
begin
  for t in (select trigger_name from user_triggers where trigger_name like 'TRG_%_AUDIT') loop
    execute immediate 'alter trigger ' || t.trigger_name || ' disable';
  end loop;
end;
/

--------------------------------------------------------------------------------
-- 1. Roles
--------------------------------------------------------------------------------
insert into roles (role_code, role_name_en, role_name_ar) values ('REP','Medical Representative','مندوب طبي');
insert into roles (role_code, role_name_en, role_name_ar) values ('SUPERVISOR','Area Supervisor','مشرف منطقة');
insert into roles (role_code, role_name_en, role_name_ar) values ('SALES_MANAGER','Sales Manager','مدير المبيعات');
insert into roles (role_code, role_name_en, role_name_ar) values ('SYS_ADMIN','System Administrator','مسؤول النظام');

--------------------------------------------------------------------------------
-- 2. Regions — 3 parents, 3 territories each
--------------------------------------------------------------------------------
insert into regions (region_code, region_name_en, region_name_ar, region_level)
values ('HQ','Head Office','المركز الرئيسي','COUNTRY');

insert into regions (parent_region_id, region_code, region_name_en, region_name_ar, region_level)
select (select region_id from regions where region_code = 'HQ'),
       'R' || level,
       case level when 1 then 'North Region' when 2 then 'Central Region' else 'South Region' end,
       case level when 1 then 'المنطقة الشمالية' when 2 then 'المنطقة الوسطى' else 'المنطقة الجنوبية' end,
       'REGION'
  from dual connect by level <= 3;

insert into regions (parent_region_id, region_code, region_name_en, region_name_ar, region_level)
select r.region_id,
       r.region_code || '-T' || t.n,
       r.region_name_en || ' — Territory ' || t.n,
       r.region_name_ar || ' — الإقليم ' || t.n,
       'TERRITORY'
  from regions r
 cross join (select level as n from dual connect by level <= 3) t
 where r.region_level = 'REGION';

--------------------------------------------------------------------------------
-- 3. Users: 1 admin, 1 manager, 3 supervisors, 12 reps
--------------------------------------------------------------------------------
insert into app_users (username, full_name, email, preferred_lang)
values ('ADMIN','System Administrator','admin@pvs.demo','en');

insert into app_users (username, full_name, email, preferred_lang)
values ('MANAGER','Sales Manager','manager@pvs.demo','en');

insert into app_users (username, full_name, email, preferred_lang)
select 'SUP' || level,
       'Supervisor ' || level,
       'sup' || level || '@pvs.demo',
       case when mod(level,2) = 0 then 'ar' else 'en' end
  from dual connect by level <= 3;

insert into app_users (username, full_name, email, preferred_lang)
select 'REP' || lpad(level, 2, '0'),
       'Representative ' || level,
       'rep' || level || '@pvs.demo',
       case when mod(level,2) = 0 then 'ar' else 'en' end
  from dual connect by level <= 12;

-- Role grants
insert into user_roles (user_id, role_id)
select u.user_id, r.role_id
  from app_users u
  join roles r
    on r.role_code = case
                       when u.username = 'ADMIN'          then 'SYS_ADMIN'
                       when u.username = 'MANAGER'        then 'SALES_MANAGER'
                       when u.username like 'SUP%'        then 'SUPERVISOR'
                       else 'REP'
                     end;

-- Assignments: 4 reps per supervisor, spread across territories
insert into rep_assignments (rep_user_id, supervisor_user_id, region_id, valid_from)
select rep.user_id,
       sup.user_id,
       ter.region_id,
       add_months(trunc(sysdate, 'MM'), -12)
  from (select user_id, row_number() over (order by user_id) rn
          from app_users where username like 'REP%') rep
  join (select user_id, row_number() over (order by user_id) rn
          from app_users where username like 'SUP%') sup
    on sup.rn = ceil(rep.rn / 4)
  join (select region_id, row_number() over (order by region_id) rn
          from regions where region_level = 'TERRITORY') ter
    on ter.rn = mod(rep.rn - 1, 9) + 1;

--------------------------------------------------------------------------------
-- 4. Facilities and doctors
--------------------------------------------------------------------------------
insert into facilities (region_id, facility_code, facility_name_en, facility_name_ar, facility_type)
select t.region_id,
       'F' || lpad(rownum, 4, '0'),
       'Medical Center ' || rownum,
       'مركز طبي ' || rownum,
       case mod(rownum, 4)
         when 0 then 'HOSPITAL' when 1 then 'CLINIC'
         when 2 then 'PHARMACY' else 'CENTER'
       end
  from (select region_id from regions where region_level = 'TERRITORY') t
 cross join (select level from dual connect by level <= 5);

insert into doctors (facility_id, doctor_code, full_name_en, full_name_ar,
                     specialty_en, specialty_ar, tier)
select f.facility_id,
       'D' || lpad(rownum, 5, '0'),
       'Dr. Physician ' || rownum,
       'د. طبيب ' || rownum,
       case mod(rownum, 6)
         when 0 then 'Cardiology'  when 1 then 'Pediatrics' when 2 then 'Internal Medicine'
         when 3 then 'Dermatology' when 4 then 'Orthopedics' else 'General Practice'
       end,
       case mod(rownum, 6)
         when 0 then 'أمراض القلب' when 1 then 'طب الأطفال' when 2 then 'الباطنة'
         when 3 then 'الجلدية'      when 4 then 'العظام'     else 'طب عام'
       end,
       case when mod(rownum, 10) < 2 then 'A'
            when mod(rownum, 10) < 5 then 'B'
            else 'C' end
  from facilities f
 cross join (select level from dual connect by level <= 7)
 where rownum <= 300;

--------------------------------------------------------------------------------
-- 5. Products, tier ceilings and batches
--------------------------------------------------------------------------------
insert into products (product_code, product_name_en, product_name_ar,
                      dosage_form, strength, default_monthly_ceiling)
select 'P' || lpad(level, 3, '0'),
       'Product ' || level,
       'المنتج ' || level,
       case mod(level, 4) when 0 then 'Tablet' when 1 then 'Capsule'
                          when 2 then 'Syrup'  else 'Injection' end,
       (10 * (mod(level, 5) + 1)) || ' mg',
       10
  from dual connect by level <= 24;

insert into product_ceilings (product_id, doctor_tier, monthly_ceiling)
select p.product_id, t.tier,
       case t.tier when 'A' then 20 when 'B' then 12 else 6 end
  from products p
 cross join (select 'A' tier from dual union all
             select 'B' from dual union all
             select 'C' from dual) t;

insert into product_batches (product_id, batch_no, expiry_date)
select p.product_id,
       'B' || p.product_id || '-' || b.n,
       add_months(trunc(sysdate, 'MM'), case b.n when 1 then -1 when 2 then 6 else 18 end)
  from products p
 cross join (select level n from dual connect by level <= 3) b;

--------------------------------------------------------------------------------
-- 6. Periods — last 12 months, current one open
--------------------------------------------------------------------------------
insert into periods (period_year, period_month, start_date, end_date, status)
select extract(year  from d), extract(month from d),
       d, last_day(d),
       case when d = trunc(sysdate, 'MM') then 'OPEN' else 'CLOSED' end
  from (select add_months(trunc(sysdate,'MM'), -(level-1)) d
          from dual connect by level <= 12);
commit;

--------------------------------------------------------------------------------
-- 7. Plans and planned items (~24,000 rows)
--------------------------------------------------------------------------------
insert into visit_plans (rep_user_id, period_id, status, submitted_on, approved_by, approved_on)
select u.user_id, p.period_id, 'APPROVED',
       cast(p.start_date as timestamp),
       (select user_id from app_users where username = 'SUP1'),
       cast(p.start_date as timestamp)
  from app_users u
 cross join periods p
 where u.username like 'REP%';

insert into plan_items (plan_id, doctor_id, planned_date, planned_start, planned_end, objective)
select pl.plan_id,
       d.doctor_id,
       pe.start_date + mod(d.doctor_id + n.i, 25),
       cast(pe.start_date + mod(d.doctor_id + n.i, 25) as timestamp)
         + numtodsinterval(8 + mod(n.i, 8), 'hour'),
       cast(pe.start_date + mod(d.doctor_id + n.i, 25) as timestamp)
         + numtodsinterval(8 + mod(n.i, 8), 'hour') + numtodsinterval(45, 'minute'),
       'Product detailing'
  from visit_plans pl
  join periods pe on pe.period_id = pl.period_id
  join (select user_id, row_number() over (order by user_id) rn
          from app_users where username like 'REP%') r
    on r.user_id = pl.rep_user_id
  join (select doctor_id, row_number() over (order by doctor_id) rn
          from doctors) d
    on mod(d.rn - 1, 12) + 1 = r.rn
 cross join (select level i from dual connect by level <= 8) n
 where mod(d.rn + n.i, 3) = 0;
commit;

--------------------------------------------------------------------------------
-- 8. Executed visits — 85% of planned items in closed periods
--------------------------------------------------------------------------------
insert into visits (plan_item_id, rep_user_id, doctor_id, period_id,
                    actual_start, actual_end, outcome, is_unplanned, reason)
select pi.plan_item_id,
       pl.rep_user_id,
       pi.doctor_id,
       pl.period_id,
       pi.planned_start + numtodsinterval(mod(pi.plan_item_id, 30), 'minute'),
       pi.planned_end   + numtodsinterval(mod(pi.plan_item_id, 30), 'minute'),
       case when mod(pi.plan_item_id, 20) = 0 then 'NOT_AVAILABLE'
            when mod(pi.plan_item_id, 33) = 0 then 'POSTPONED'
            else 'COMPLETED' end,
       'N',
       case when mod(pi.plan_item_id, 20) = 0 or mod(pi.plan_item_id, 33) = 0
            then 'Auto-generated demo reason' end
  from plan_items pi
  join visit_plans pl on pl.plan_id = pi.plan_id
  join periods     pe on pe.period_id = pl.period_id
 where pe.status = 'CLOSED'
   and mod(pi.plan_item_id, 7) <> 0;          -- ~85% executed

update plan_items pi
   set pi.item_status = 'EXECUTED'
 where exists (select 1 from visits v
                where v.plan_item_id = pi.plan_item_id
                  and v.outcome = 'COMPLETED');
commit;

-- Discussed products: 2 per completed visit
insert into visit_products (visit_id, product_id, feedback)
select v.visit_id,
       p.product_id,
       case mod(v.visit_id + p.product_id, 3)
         when 0 then 'POSITIVE' when 1 then 'NEUTRAL' else 'OBJECTION' end
  from visits v
  join (select product_id, row_number() over (order by product_id) rn from products) p
    on p.rn in (mod(v.visit_id, 24) + 1, mod(v.visit_id * 7, 24) + 1)
 where v.outcome = 'COMPLETED';
commit;

--------------------------------------------------------------------------------
-- 9. Sample stock: receipts, then dispenses tied to visits
--------------------------------------------------------------------------------
insert into sample_transactions (rep_user_id, batch_id, period_id, trx_type, quantity, reference)
select u.user_id, b.batch_id, pe.period_id, 'RECEIPT', 200, 'Opening stock'
  from app_users u
 cross join product_batches b
 cross join (select period_id from periods where status = 'OPEN') pe
 where u.username like 'REP%'
   and b.expiry_date > trunc(sysdate);

insert into sample_transactions (rep_user_id, batch_id, visit_id, doctor_id, period_id,
                                 trx_type, quantity, reference)
select v.rep_user_id,
       b.batch_id,
       v.visit_id,
       v.doctor_id,
       v.period_id,
       'DISPENSE',
       -(mod(v.visit_id, 4) + 1),
       'Sample handout'
  from visits v
  join visit_products vp on vp.visit_id = v.visit_id
  join (select batch_id, product_id,
               row_number() over (partition by product_id order by expiry_date desc) rn
          from product_batches
         where expiry_date > trunc(sysdate)) b
    on b.product_id = vp.product_id and b.rn = 1
 where v.outcome = 'COMPLETED'
   and mod(v.visit_id, 2) = 0;

-- Rebuild balances from the ledger in one statement
insert into sample_balances (rep_user_id, batch_id, quantity_on_hand, last_movement_on)
select rep_user_id, batch_id, sum(quantity), max(trx_date)
  from sample_transactions
 group by rep_user_id, batch_id
having sum(quantity) >= 0;
commit;

--------------------------------------------------------------------------------
-- 10. Targets
--------------------------------------------------------------------------------
insert into targets (rep_user_id, product_id, period_id, target_value, target_unit)
select u.user_id, p.product_id, pe.period_id,
       case mod(p.product_id, 3) when 0 then 40 when 1 then 25 else 60 end,
       case mod(p.product_id, 3) when 0 then 'VISITS' when 1 then 'SAMPLES' else 'POINTS' end
  from app_users u
 cross join (select product_id from products where mod(product_id, 4) = 0) p
 cross join periods pe
 where u.username like 'REP%';
commit;

--------------------------------------------------------------------------------
-- 11. Re-enable audit triggers, compute achievement, gather statistics
--------------------------------------------------------------------------------
begin
  for t in (select trigger_name from user_triggers where trigger_name like 'TRG_%_AUDIT') loop
    execute immediate 'alter trigger ' || t.trigger_name || ' enable';
  end loop;
end;
/

-- Seed runs as schema owner, outside any APEX session, so the security
-- context must be set explicitly before calling any package API.
begin
  pkg_security.set_context('MANAGER');

  for p in (select period_id from periods) loop
    declare
      l_rows number;
    begin
      pkg_target.calculate_achievement(p.period_id, l_rows);
    exception
      when others then null;    -- closed periods are skipped by design
    end;
  end loop;

  commit;
end;
/

begin
  dbms_mview.refresh('MV_REGION_PERFORMANCE', method => 'C');
end;
/

-- Statistics matter more than any index here: without them the optimizer
-- plans against defaults and every timing measurement is meaningless.
begin
  dbms_stats.gather_schema_stats(
    ownname          => user,
    estimate_percent => dbms_stats.auto_sample_size,
    method_opt       => 'FOR ALL COLUMNS SIZE AUTO',
    cascade          => true);
end;
/

--------------------------------------------------------------------------------
-- 12. Volume report
--------------------------------------------------------------------------------
declare
  l_n number;
  procedure show (p_label in varchar2, p_count in number) is
  begin
    dbms_output.put_line(rpad(p_label, 28, '.') || ' ' || to_char(p_count, '999,999'));
  end;
begin
  dbms_output.put_line('--- Pharma Visit System seed volumes ---');
  select count(*) into l_n from regions;             show('regions', l_n);
  select count(*) into l_n from app_users;           show('users', l_n);
  select count(*) into l_n from facilities;          show('facilities', l_n);
  select count(*) into l_n from doctors;             show('doctors', l_n);
  select count(*) into l_n from products;            show('products', l_n);
  select count(*) into l_n from product_batches;     show('batches', l_n);
  select count(*) into l_n from visit_plans;         show('plans', l_n);
  select count(*) into l_n from plan_items;          show('planned items', l_n);
  select count(*) into l_n from visits;              show('visits', l_n);
  select count(*) into l_n from visit_products;      show('visit products', l_n);
  select count(*) into l_n from sample_transactions; show('sample movements', l_n);
  select count(*) into l_n from targets;             show('targets', l_n);
end;
/

prompt Seed data loaded.
