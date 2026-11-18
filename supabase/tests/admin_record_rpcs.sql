-- Smoke test for admin attendance RPCs used by the report/review panel.
-- All writes are rolled back; no test employee or attendance row remains.
begin;

do $tests$
declare
  v_employee jsonb;
  v_employee_id uuid;
  v_record jsonb;
  v_record_id uuid;
begin
  perform set_config('request.jwt.claim.sub', 'edc8fe57-81af-4672-bb3b-ca1a6bad161a', true);
  perform set_config('request.jwt.claims',
    '{"sub":"edc8fe57-81af-4672-bb3b-ca1a6bad161a","email":"mahdi.alaei64@gmail.com","role":"authenticated"}', true);

  v_employee := public.admin_create_employee('TEST — rollback only', '1234');
  v_employee_id := (v_employee ->> 'id')::uuid;

  v_record := public.admin_add_record(
    v_employee_id,
    now() - interval '3 hours',
    now() - interval '2 hours',
    'Automated rollback smoke test'
  );
  v_record_id := (v_record ->> 'id')::uuid;

  v_record := public.admin_edit_record(
    v_record_id,
    now() - interval '4 hours',
    now() - interval '2 hours',
    'Automated edit rollback test'
  );

  if (v_record ->> 'edited')::boolean is not true then
    raise exception 'admin_edit_record_did_not_mark_edited';
  end if;

  perform public.admin_delete_record(v_record_id, 'Automated delete rollback test');
end
$tests$;

rollback;
