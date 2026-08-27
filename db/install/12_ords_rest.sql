--------------------------------------------------------------------------------
-- Pharma Visit System — 12_ords_rest.sql
-- REST API for the mobile client, defined as code rather than clicked into
-- the ORDS UI. A REST layer that exists only in a dev instance's metadata is
-- not deployable and not reviewable.
--
-- Contract
--   Base      : /ords/pvs/v1/
--   Auth      : OAuth2 client credentials, privilege PVS_MOBILE
--   Envelope  : { "status": "...", "data": ..., "error": ... }
--   Idempotency: every write accepts client_ref; replay returns the original
--                result instead of creating a second record.
--------------------------------------------------------------------------------
set define off

begin
  ords.enable_schema(
    p_enabled             => true,
    p_schema              => user,
    p_url_mapping_type    => 'BASE_PATH',
    p_url_mapping_pattern => 'pvs',
    p_auto_rest_auth      => true);       -- never expose objects automatically
  commit;
end;
/

--------------------------------------------------------------------------------
-- Module
--------------------------------------------------------------------------------
begin
  ords.define_module(
    p_module_name    => 'pvs.v1',
    p_base_path      => '/v1/',
    p_items_per_page => 100,
    p_status         => 'PUBLISHED',
    p_comments       => 'Pharma Visit System mobile API v1');

  ------------------------------------------------------------------
  -- GET /v1/plan/current — the representative's approved plan
  ------------------------------------------------------------------
  ords.define_template(
    p_module_name => 'pvs.v1',
    p_pattern     => 'plan/current');

  ords.define_handler(
    p_module_name => 'pvs.v1',
    p_pattern     => 'plan/current',
    p_method      => 'GET',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      declare
        l_json clob;
      begin
        pkg_security.set_context(:current_user);

        select json_object(
                 'status' value 'OK',
                 'data'   value json_arrayagg(
                   json_object(
                     'plan_item_id' value pi.plan_item_id,
                     'doctor_id'    value pi.doctor_id,
                     'doctor_name'  value pkg_i18n.label(d.full_name_en, d.full_name_ar),
                     'facility'     value pkg_i18n.label(f.facility_name_en, f.facility_name_ar),
                     'tier'         value d.tier,
                     'planned_start' value to_char(pi.planned_start, 'YYYY-MM-DD"T"HH24:MI:SS'),
                     'planned_end'   value to_char(pi.planned_end,   'YYYY-MM-DD"T"HH24:MI:SS'),
                     'objective'    value pi.objective,
                     'status'       value pi.item_status
                   ) order by pi.planned_start returning clob)
                 returning clob)
          into l_json
          from plan_items  pi
          join visit_plans pl on pl.plan_id    = pi.plan_id
          join periods     pe on pe.period_id  = pl.period_id
          join doctors     d  on d.doctor_id   = pi.doctor_id
          join facilities  f  on f.facility_id = d.facility_id
         where pl.rep_user_id = pkg_security.current_user_id
           and pl.status      = 'APPROVED'
           and pe.status      = 'OPEN';

        owa_util.mime_header('application/json', true);
        htp.prn(nvl(l_json, '{"status":"OK","data":[]}'));
      exception
        when others then
          :status_code := 400;
          owa_util.mime_header('application/json', true);
          htp.prn(json_object('status' value 'ERROR',
                              'error'  value substr(sqlerrm, 1, 400)));
      end;]');

  ------------------------------------------------------------------
  -- GET /v1/reference — master data for offline caching
  ------------------------------------------------------------------
  ords.define_template(
    p_module_name => 'pvs.v1',
    p_pattern     => 'reference');

  ords.define_handler(
    p_module_name => 'pvs.v1',
    p_pattern     => 'reference',
    p_method      => 'GET',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      declare
        l_doctors  clob;
        l_products clob;
      begin
        pkg_security.set_context(:current_user);

        select json_arrayagg(json_object(
                 'doctor_id' value d.doctor_id,
                 'name'      value pkg_i18n.label(d.full_name_en, d.full_name_ar),
                 'specialty' value pkg_i18n.label(d.specialty_en, d.specialty_ar),
                 'tier'      value d.tier,
                 'facility'  value pkg_i18n.label(f.facility_name_en, f.facility_name_ar)
               ) returning clob)
          into l_doctors
          from doctors d
          join facilities f on f.facility_id = d.facility_id
          join rep_assignments a
            on a.region_id = f.region_id
           and a.rep_user_id = pkg_security.current_user_id
           and trunc(sysdate) between a.valid_from and nvl(a.valid_to, date '4000-01-01')
         where d.status = 'ACTIVE';

        select json_arrayagg(json_object(
                 'product_id' value p.product_id,
                 'code'       value p.product_code,
                 'name'       value pkg_i18n.label(p.product_name_en, p.product_name_ar),
                 'batches'    value (
                    select json_arrayagg(json_object(
                             'batch_id' value b.batch_id,
                             'batch_no' value b.batch_no,
                             'expiry'   value to_char(b.expiry_date, 'YYYY-MM-DD'),
                             'on_hand'  value nvl(pkg_sample.balance_of(
                                                    pkg_security.current_user_id, b.batch_id), 0)))
                      from product_batches b
                     where b.product_id = p.product_id
                       and b.status = 'ACTIVE'
                       and b.expiry_date > trunc(sysdate))
               ) returning clob)
          into l_products
          from products p
         where p.status = 'ACTIVE';

        owa_util.mime_header('application/json', true);
        htp.prn(json_object('status'   value 'OK',
                            'doctors'  value l_doctors  format json,
                            'products' value l_products format json
                            returning clob));
      exception
        when others then
          :status_code := 400;
          owa_util.mime_header('application/json', true);
          htp.prn(json_object('status' value 'ERROR', 'error' value substr(sqlerrm,1,400)));
      end;]');

  ------------------------------------------------------------------
  -- POST /v1/visits/sync — batch upload of offline-captured visits
  --
  -- Returns 207-style per-item results: the client must know exactly which
  -- of its queued items were accepted, which were duplicates, and which
  -- were rejected and why. A single 200/400 for the whole batch would force
  -- the client to either re-send everything or lose data.
  ------------------------------------------------------------------
  ords.define_template(
    p_module_name => 'pvs.v1',
    p_pattern     => 'visits/sync');

  ords.define_handler(
    p_module_name => 'pvs.v1',
    p_pattern     => 'visits/sync',
    p_method      => 'POST',
    p_mimes_allowed => 'application/json',
    p_source_type => ords.source_type_plsql,
    p_source      => q'[
      declare
        l_payload clob := :body_text;
        l_results clob;
        l_rejected number := 0;
      begin
        pkg_security.set_context(:current_user);

        select json_arrayagg(json_object(
                 'client_ref' value client_ref,
                 'status'     value status,
                 'visit_id'   value visit_id,
                 'error_code' value error_code,
                 'error'      value error_text) returning clob),
               count(case when status = 'REJECTED' then 1 end)
          into l_results, l_rejected
          from table(pkg_visit.sync_batch(l_payload));

        commit;

        :status_code := case when l_rejected > 0 then 207 else 200 end;
        owa_util.mime_header('application/json', true);
        htp.prn(json_object('status'  value case when l_rejected > 0 then 'PARTIAL' else 'OK' end,
                            'rejected' value l_rejected,
                            'data'    value l_results format json returning clob));
      exception
        when others then
          rollback;
          :status_code := 400;
          owa_util.mime_header('application/json', true);
          htp.prn(json_object('status' value 'ERROR', 'error' value substr(sqlerrm,1,400)));
      end;]');

  ------------------------------------------------------------------
  -- POST /v1/samples/dispense — single dispense, same rules as the UI
  ------------------------------------------------------------------
  ords.define_template(
    p_module_name => 'pvs.v1',
    p_pattern     => 'samples/dispense');

  ords.define_handler(
    p_module_name   => 'pvs.v1',
    p_pattern       => 'samples/dispense',
    p_method        => 'POST',
    p_mimes_allowed => 'application/json',
    p_source_type   => ords.source_type_plsql,
    p_source        => q'[
      declare
        l_body  clob := :body_text;
        l_trx   number;
        l_visit number;
        l_batch number;
        l_qty   number;
        l_ref   varchar2(64);
        l_rep   number;
        l_doc   number;
      begin
        pkg_security.set_context(:current_user);

        select visit_id, batch_id, quantity, client_ref
          into l_visit, l_batch, l_qty, l_ref
          from json_table(l_body, '$'
               columns (visit_id   number       path '$.visit_id',
                        batch_id   number       path '$.batch_id',
                        quantity   number       path '$.quantity',
                        client_ref varchar2(64) path '$.client_ref'));

        select rep_user_id, doctor_id into l_rep, l_doc
          from visits where visit_id = l_visit;

        pkg_sample.dispense(l_rep, l_batch, l_visit, l_doc, l_qty, l_ref, l_trx);
        commit;

        :status_code := 201;
        owa_util.mime_header('application/json', true);
        htp.prn(json_object('status' value 'OK',
                            'data'   value json_object('trx_id' value l_trx,
                                                       'remaining' value
                                                        pkg_sample.balance_of(l_rep, l_batch))));
      exception
        when others then
          rollback;
          -- Business errors are the client's fault (422); anything else is 400.
          :status_code := case when sqlcode between -20999 and -20000 then 422 else 400 end;
          owa_util.mime_header('application/json', true);
          htp.prn(json_object('status' value 'ERROR',
                              'code'   value abs(sqlcode),
                              'error'  value substr(sqlerrm, 12, 400)));
      end;]');

  commit;
end;
/

--------------------------------------------------------------------------------
-- OAuth2 protection
--   Privilege first, then the client. A module published before its privilege
--   exists is briefly public — order matters here.
--------------------------------------------------------------------------------
begin
  ords.create_role(p_role_name => 'Pharma Visit System Mobile');

  ords.create_privilege(
    p_name        => 'pvs.mobile',
    p_role_name   => 'Pharma Visit System Mobile',
    p_label       => 'Pharma Visit System Mobile Access',
    p_description => 'Access to the Pharma Visit System mobile API');

  ords.create_privilege_mapping(
    p_privilege_name => 'pvs.mobile',
    p_pattern        => '/v1/*');

  ords.create_client(
    p_name             => 'pvs_mobile_client',
    p_grant_type       => 'client_credentials',
    p_owner            => 'Pharma Visit System',
    p_description      => 'Mobile application for medical representatives',
    p_support_email    => 'admin@pvs.demo',
    p_privilege_names  => 'pvs.mobile');

  ords.grant_client_role(
    p_client_name => 'pvs_mobile_client',
    p_role_name   => 'Pharma Visit System Mobile');

  commit;
end;
/

--------------------------------------------------------------------------------
-- Retrieve credentials for the client application:
--
--   select client_id, client_secret
--     from user_ords_clients
--    where name = 'pvs_mobile_client';
--
-- Token:
--   curl -i -X POST --user <client_id>:<client_secret> \
--        -d "grant_type=client_credentials" \
--        https://<host>/ords/pvs/oauth/token
--
-- Call:
--   curl -H "Authorization: Bearer <token>" \
--        https://<host>/ords/pvs/v1/plan/current
--
-- Credentials are never committed to this repository.
--------------------------------------------------------------------------------

prompt ORDS REST layer defined.
