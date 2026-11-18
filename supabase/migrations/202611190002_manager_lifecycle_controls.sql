-- Owner controls for manager lifecycle: list managers/invitations, revoke a manager, revoke an invitation.
create or replace function public.owner_list_store_managers()
returns table(user_id uuid, email text, assigned_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner_id uuid := (select auth.uid());
begin
  if v_owner_id is null or not exists (
    select 1 from public.app_user_roles r
    where r.user_id = v_owner_id and r.role = 'owner'
  ) then
    raise exception 'owner_role_required' using errcode = '42501';
  end if;

  return query
  select r.user_id, u.email::text, r.created_at
  from public.app_user_roles r
  join auth.users u on u.id = r.user_id
  where r.role = 'store_manager'
  order by r.created_at, lower(u.email);
end;
$$;

create or replace function public.owner_list_manager_invites()
returns table(
  invite_id uuid,
  invite_email text,
  created_at timestamptz,
  expires_at timestamptz,
  invited_by_email text,
  accepted_at timestamptz,
  revoked_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner_id uuid := (select auth.uid());
begin
  if v_owner_id is null or not exists (
    select 1 from public.app_user_roles r
    where r.user_id = v_owner_id and r.role = 'owner'
  ) then
    raise exception 'owner_role_required' using errcode = '42501';
  end if;

  return query
  select i.id, i.email, i.created_at, i.expires_at, u.email::text,
         i.accepted_at, i.revoked_at
  from public.manager_invites i
  left join auth.users u on u.id = i.invited_by
  order by i.created_at desc
  limit 100;
end;
$$;

create or replace function public.owner_revoke_store_manager(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner_id uuid := (select auth.uid());
  v_target_email text;
begin
  if v_owner_id is null or not exists (
    select 1 from public.app_user_roles r
    where r.user_id = v_owner_id and r.role = 'owner'
  ) then
    raise exception 'owner_role_required' using errcode = '42501';
  end if;
  if p_user_id is null or p_user_id = v_owner_id then
    raise exception 'invalid_manager_target';
  end if;

  select u.email into v_target_email
  from auth.users u
  join public.app_user_roles r on r.user_id = u.id
  where u.id = p_user_id and r.role = 'store_manager'
  for update of r;

  if v_target_email is null then
    raise exception 'store_manager_not_found';
  end if;

  delete from public.app_user_roles
  where user_id = p_user_id and role = 'store_manager';

  insert into public.audit_log(admin_email, action, new_data, reason)
  values (
    lower(coalesce(auth.jwt() ->> 'email', '')),
    'revoke_store_manager',
    jsonb_build_object('email', lower(v_target_email), 'user_id', p_user_id),
    'Owner revoked store-manager access'
  );

  return true;
end;
$$;

create or replace function public.revoke_manager_invite(p_invite_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := (select auth.uid());
  v_actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_invite public.manager_invites%rowtype;
  v_is_owner boolean;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select exists (
    select 1 from public.app_user_roles r
    where r.user_id = v_actor_id and r.role = 'owner'
  ) into v_is_owner;

  select * into v_invite
  from public.manager_invites i
  where i.id = p_invite_id
  for update;

  if not found then raise exception 'invite_not_found'; end if;
  if v_invite.accepted_at is not null then raise exception 'invite_already_accepted'; end if;
  if v_invite.revoked_at is not null then raise exception 'invite_already_revoked'; end if;

  if not v_is_owner and v_invite.invited_by <> v_actor_id then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  update public.manager_invites set revoked_at = now() where id = p_invite_id;

  insert into public.audit_log(admin_email, action, new_data, reason)
  values (
    v_actor_email,
    'revoke_manager_invite',
    jsonb_build_object('invite_id', p_invite_id, 'email', v_invite.email),
    'Invitation revoked'
  );

  return true;
end;
$$;

revoke all on function public.owner_list_store_managers() from public, anon;
revoke all on function public.owner_list_manager_invites() from public, anon;
revoke all on function public.owner_revoke_store_manager(uuid) from public, anon;
revoke all on function public.revoke_manager_invite(uuid) from public, anon;
grant execute on function public.owner_list_store_managers() to authenticated;
grant execute on function public.owner_list_manager_invites() to authenticated;
grant execute on function public.owner_revoke_store_manager(uuid) to authenticated;
grant execute on function public.revoke_manager_invite(uuid) to authenticated;
