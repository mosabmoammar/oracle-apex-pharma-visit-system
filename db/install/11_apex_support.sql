--------------------------------------------------------------------------------
-- Pharma Visit System — 11_apex_support.sql
-- Everything the APEX application calls. Install before importing the app.
--
-- Principle
--   An APEX page in this application contains no SQL that writes and no
--   business rule. Every page process is a one-line call into a package.
--   The benefit is not tidiness: it is that the REST channel, the scheduler
--   and the UI cannot diverge in behaviour, because there is only one
--   implementation to diverge from.
--------------------------------------------------------------------------------
set define off

insert into error_messages values (20023,
  'Invalid username or password.',
  'اسم المستخدم أو كلمة المرور غير صحيحة.');
insert into error_messages values (20024,
  'Your account is inactive. Contact the system administrator.',
  'الحساب غير مفعّل. يرجى مراجعة مسؤول النظام.');
commit;

create or replace package pkg_apex as

  ------------------------------------------------------------------
  -- Authentication scheme: "Pharma Visit System Custom"
  --   Authentication function : pkg_apex.authenticate
  --   Post-authentication     : pkg_apex.post_authenticate
  --   Session sentry / verify : (default)
  ------------------------------------------------------------------
  function authenticate (p_username in varchar2, p_password in varchar2) return boolean;

  procedure post_authenticate;

  ------------------------------------------------------------------
  -- Error handling: set as the application-level Error Handling Function.
  ------------------------------------------------------------------
  function error_handler (p_error in apex_error.t_error) return apex_error.t_error_result;

  ------------------------------------------------------------------
  -- Language
  ------------------------------------------------------------------
  procedure switch_language (p_lang in varchar2);
  function  current_direction return varchar2;      -- 'rtl' | 'ltr', for the page template

  ------------------------------------------------------------------
  -- Page process wrappers.
  -- Thin on purpose: they convert APEX item values into typed arguments
  -- and nothing else.
  ------------------------------------------------------------------
  procedure page_dispense_sample (
    p_visit_id   in number,
    p_batch_id   in number,
    p_quantity   in number);

  procedure page_execute_visit (
    p_plan_item_id in number,
    p_start        in varchar2,     -- APEX date item value
    p_end          in varchar2,
    p_outcome      in varchar2,
    p_reason       in varchar2,
    p_notes        in varchar2);

  -- Feeds a "remaining allowance" display item via a dynamic action.
  function remaining_for_display (
    p_doctor_id  in number,
    p_product_id in number) return varchar2;

end pkg_apex;
/

create or replace package body pkg_apex as

  ------------------------------------------------------------------
  -- Credentials are verified by APEX_UTIL against the workspace account
  -- repository. This application deliberately does NOT store password
  -- hashes: re-implementing credential storage is a liability, not a
  -- feature. APP_USERS holds identity and authorisation only.
  ------------------------------------------------------------------
  function authenticate (p_username in varchar2, p_password in varchar2) return boolean is
    l_status varchar2(10);
  begin
    if not apex_util.is_login_password_valid(p_username => upper(p_username),
                                             p_password => p_password) then
      return false;
    end if;

    select status into l_status
      from app_users
     where upper(username) = upper(p_username);

    return l_status = 'ACTIVE';
  exception
    when no_data_found then
      return false;                      -- authenticated to APEX, unknown to this app
  end authenticate;

  ------------------------------------------------------------------
  procedure post_authenticate is
  begin
    -- Establishes CTX_PVS for the session. Every secure view depends on
    -- this having run, which is why it lives in post-authentication rather
    -- than in a page process that some page might skip.
    pkg_security.set_context(p_username => v('APP_USER'));

    -- Align the APEX session language with the stored preference.
    for r in (select preferred_lang from app_users where upper(username) = upper(v('APP_USER'))) loop
      if nvl(apex_util.get_session_lang, 'en') <> r.preferred_lang then
        apex_util.set_session_lang(r.preferred_lang);
      end if;
    end loop;
  end post_authenticate;

  ------------------------------------------------------------------
  -- Error handler.
  --
  -- Three behaviours that matter:
  --   1. Catalogued -200xx errors become clean bilingual messages.
  --   2. Constraint violations become the business message behind the
  --      constraint, not "ORA-00001: unique constraint (PVS.X) violated".
  --   3. Anything unexpected is logged with a reference number and shown
  --      to the user as a generic message — internal detail never leaks.
  ------------------------------------------------------------------
  function error_handler (p_error in apex_error.t_error) return apex_error.t_error_result is
    l_result    apex_error.t_error_result;
    l_reference number;
    l_code      number;
    l_constraint varchar2(255);
  begin
    l_result := apex_error.init_error_result(p_error => p_error);

    -- 1. Catalogued application errors
    if p_error.ora_sqlcode between -20999 and -20000 then
      l_code := abs(p_error.ora_sqlcode);

      begin
        select pkg_i18n.label(message_en, message_ar)
          into l_result.message
          from error_messages
         where error_code = l_code;

        l_result.display_location := case
          when p_error.display_location = apex_error.c_on_error_page
            then apex_error.c_inline_in_notification
          else p_error.display_location end;

        l_result.additional_info := null;
        return l_result;
      exception
        when no_data_found then null;    -- fall through to generic handling
      end;
    end if;

    -- 2. Constraint violations mapped to business language
    if p_error.ora_sqlcode in (-1, -2091, -2290, -2291, -2292) then
      l_constraint := apex_error.extract_constraint_name(p_error => p_error);

      l_result.message := case
        when l_constraint like '%PLANS_UK1%'
          then pkg_i18n.label('A plan already exists for this representative and period.',
                              'توجد خطة مسجلة مسبقًا لهذا المندوب وهذه الفترة.')
        when l_constraint like '%TARGETS_UK1%'
          then pkg_i18n.message(20011)
        when l_constraint like '%SAMPLE_BAL_CK_QTY%'
          then pkg_i18n.message(20006)
        when l_constraint like '%VISITS_UK_REF%' or l_constraint like '%SAMPLE_TRX_UK_REF%'
          then pkg_i18n.label('This record has already been submitted.',
                              'تم إرسال هذا السجل مسبقًا.')
        when l_constraint like '%_FK_%'
          then pkg_i18n.label('This record is referenced elsewhere and cannot be removed.',
                              'هذا السجل مرتبط بسجلات أخرى ولا يمكن حذفه.')
        else pkg_i18n.label('The operation violates a data rule.',
                            'العملية تخالف أحد قيود البيانات.')
      end;

      l_result.display_location := apex_error.c_inline_in_notification;
      l_result.additional_info  := null;
      return l_result;
    end if;

    -- 3. Unexpected errors: log, reference, generalise
    if p_error.is_internal_error then
      l_reference := apex_error.add_error_to_error_log(p_error => p_error);

      l_result.message := pkg_i18n.label(
        'An unexpected error occurred. Reference: ',
        'حدث خطأ غير متوقع. الرقم المرجعي: ') || l_reference;

      l_result.additional_info := null;   -- never expose internals to the browser
    end if;

    return l_result;
  end error_handler;

  ------------------------------------------------------------------
  procedure switch_language (p_lang in varchar2) is
    l_lang varchar2(2) := case when lower(p_lang) = 'ar' then 'ar' else 'en' end;
  begin
    update app_users
       set preferred_lang = l_lang,
           updated_by     = v('APP_USER'),
           updated_on     = systimestamp
     where upper(username) = upper(v('APP_USER'));

    -- Both layers must move together: APEX chrome and the data-layer labels.
    apex_util.set_session_lang(l_lang);
    pkg_security.set_context(p_username => v('APP_USER'), p_lang => l_lang);
  end switch_language;

  ------------------------------------------------------------------
  function current_direction return varchar2 is
  begin
    return case when pkg_i18n.current_lang = 'ar' then 'rtl' else 'ltr' end;
  end current_direction;

  ------------------------------------------------------------------
  procedure page_dispense_sample (
    p_visit_id in number,
    p_batch_id in number,
    p_quantity in number) is
    l_rep    number;
    l_doctor number;
    l_trx    number;
  begin
    select rep_user_id, doctor_id
      into l_rep, l_doctor
      from visits
     where visit_id = p_visit_id;

    pkg_sample.dispense(
      p_rep_user_id => l_rep,
      p_batch_id    => p_batch_id,
      p_visit_id    => p_visit_id,
      p_doctor_id   => l_doctor,
      p_quantity    => p_quantity,
      p_client_ref  => null,
      p_trx_id      => l_trx);
  end page_dispense_sample;

  ------------------------------------------------------------------
  procedure page_execute_visit (
    p_plan_item_id in number,
    p_start        in varchar2,
    p_end          in varchar2,
    p_outcome      in varchar2,
    p_reason       in varchar2,
    p_notes        in varchar2) is
    l_visit_id number;
    l_fmt      varchar2(40) := 'YYYY-MM-DD HH24:MI';
  begin
    pkg_visit.execute_planned(
      p_plan_item_id => p_plan_item_id,
      p_actual_start => cast(to_date(p_start, l_fmt) as timestamp with local time zone),
      p_actual_end   => cast(to_date(p_end,   l_fmt) as timestamp with local time zone),
      p_outcome      => p_outcome,
      p_reason       => p_reason,
      p_notes        => p_notes,
      p_client_ref   => null,
      p_visit_id     => l_visit_id);

    -- Hand the new id back to the page for a redirect.
    apex_util.set_session_state('P30_VISIT_ID', l_visit_id);
  end page_execute_visit;

  ------------------------------------------------------------------
  function remaining_for_display (
    p_doctor_id  in number,
    p_product_id in number) return varchar2 is
    l_period number;
    l_left   number;
  begin
    select period_id into l_period from periods where status = 'OPEN';
    l_left := pkg_sample.remaining_allowance(p_doctor_id, p_product_id, l_period);

    return pkg_i18n.label('Remaining this month: ', 'المتبقي هذا الشهر: ') || l_left;
  exception
    when no_data_found then
      return null;
  end remaining_for_display;

end pkg_apex;
/

--------------------------------------------------------------------------------
-- Authorization scheme helper views/functions used by APEX
--   Scheme "Is Supervisor"     -> PL/SQL: return pkg_security.has_role('SUPERVISOR') = 'Y';
--   Scheme "Is Manager"        -> PL/SQL: return pkg_security.is_privileged;
--   Scheme "Can Approve Plans" -> PL/SQL: return pkg_security.has_role('SUPERVISOR') = 'Y'
--                                              or pkg_security.is_privileged;
--
-- Evaluation point for all three: "Once per session". Roles do not change
-- mid-session, and per-page evaluation costs a query on every request.
--------------------------------------------------------------------------------

prompt APEX support layer installed.
