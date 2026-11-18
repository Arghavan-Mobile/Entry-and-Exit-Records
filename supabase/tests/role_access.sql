-- Safe regression checks for the production role model.
-- Run inside a transaction; no persistent data is changed.
begin;

do $tests$
declare
  v_owner_id uuid := 'edc8fe57-81af-4672-bb3b-ca1a6bad161a';
  v_manager_id uuid := 'c0e814d2-971e-40c2-b8ee-bebf0fefb1d0';
  v_unknown_id uuid := '00000000-0000-0000-0000-000000000001';
  v_count integer;
begin
  -- Owner can enter the admin surface and list managers/invitations.
  perform set_config('request.jwt.claim.sub', v_owner_id::text, true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_owner_id,'email','mahdi.alaei64@gmail.com','role','authenticated')::text, true);
  if not public.is_admin() or not public.has_app_role('owner'::public.app_role) then
    raise exception 'owner_role_test_failed';
  end if;
  select count(*) into v_count from public.owner_list_store_managers();
  if v_count < 1 then raise exception 'owner_manager_list_test_failed'; end if;
  perform count(*) from public.owner_list_manager_invites();

  -- Store manager is an admin, but must not get owner-only lifecycle powers.
  perform set_config('request.jwt.claim.sub', v_manager_id::text, true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_manager_id,'email','ahoora7000@gmail.com','role','authenticated')::text, true);
  if not public.is_admin() or not public.has_app_role('store_manager'::public.app_role) then
    raise exception 'manager_role_test_failed';
  end if;
  begin
    perform * from public.owner_list_store_managers();
    raise exception 'manager_owner_list_should_be_denied';
  exception when insufficient_privilege then
    null;
  end;
  begin
    perform public.owner_revoke_store_manager(v_manager_id);
    raise exception 'manager_owner_revoke_should_be_denied';
  exception when insufficient_privilege then
    null;
  end;

  -- An authenticated account without a role is not an administrator.
  perform set_config('request.jwt.claim.sub', v_unknown_id::text, true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_unknown_id,'email','nobody@example.com','role','authenticated')::text, true);
  if public.is_admin() then raise exception 'unassigned_user_admin_test_failed'; end if;
end
$tests$;

rollback;
