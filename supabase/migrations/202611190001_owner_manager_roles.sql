-- 202611190001_owner_manager_roles.sql
-- Draft migration for review. This file has NOT been applied to the live Supabase project.
-- Roles are keyed by auth.uid(); email is used only for invitation matching/display.

do $$
begin
  create type public.app_role as enum ('owner', 'store_manager');
exception
  when duplicate_object then null;
end
$$;

create table if not exists public.app_user_roles (
  user_id uuid primary key references auth.users(id) on delete restrict,
  role public.app_role not null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null
);

create unique index if not exists app_user_roles_single_owner
  on public.app_user_roles (role)
  where role = 'owner';

create table if not exists public.manager_invites (
  id uuid primary key default gen_random_uuid(),
  email text not null check (email = lower(btrim(email))),
  invited_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  accepted_by uuid references auth.users(id) on delete restrict,
  accepted_at timestamptz,
  revoked_at timestamptz,
  check (expires_at > created_at),
  check ((accepted_by is null) = (accepted_at is null))
);

create unique index if not exists manager_invites_one_pending_per_email
  on public.manager_invites (email)
  where accepted_at is null and revoked_at is null;

alter table public.app_user_roles enable row level security;
alter table public.manager_invites enable row level security;

-- The application cannot directly read/write role assignments or invitations.
-- The Edge Function uses the service-role client; SECURITY DEFINER functions
-- below expose only the narrow operations needed by authenticated users.
revoke all on public.app_user_roles from anon, authenticated, public;
revoke all on public.manager_invites from anon, authenticated, public;

create or replace function public.has_app_role(p_role public.app_role)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.app_user_roles r
    where r.user_id = (select auth.uid())
      and r.role = p_role
  );
$$;

revoke all on function public.has_app_role(public.app_role) from public, anon;
grant execute on function public.has_app_role(public.app_role) to authenticated;

create or replace function public.claim_store_manager_invite()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_invite public.manager_invites%rowtype;
begin
  if v_user_id is null or v_email = '' then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  -- Require a confirmed email on the authenticated Supabase user.
  if not exists (
    select 1
    from auth.users u
    where u.id = v_user_id
      and lower(coalesce(u.email, '')) = v_email
      and u.email_confirmed_at is not null
  ) then
    raise exception 'verified_email_required' using errcode = '42501';
  end if;

  select *
    into v_invite
  from public.manager_invites i
  where i.email = v_email
    and i.accepted_at is null
    and i.revoked_at is null
    and i.expires_at > now()
  order by i.created_at desc
  limit 1
  for update;

  if not found then
    raise exception 'valid_manager_invite_not_found' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.app_user_roles r
    where r.user_id = v_user_id and r.role = 'owner'
  ) then
    raise exception 'owner_role_cannot_be_changed';
  end if;

  insert into public.app_user_roles(user_id, role, created_by)
  values (v_user_id, 'store_manager', v_invite.invited_by)
  on conflict (user_id) do update
    set role = case
      when public.app_user_roles.role = 'owner' then 'owner'::public.app_role
      else 'store_manager'::public.app_role
    end;

  update public.manager_invites
  set accepted_by = v_user_id,
      accepted_at = now()
  where id = v_invite.id;

  return true;
end;
$$;

revoke all on function public.claim_store_manager_invite() from public, anon;
grant execute on function public.claim_store_manager_invite() to authenticated;

-- Seed the known owner using the existing Auth identity.
-- Abort rather than silently create an incomplete owner setup.
do $$
declare
  v_owner_id uuid;
begin
  select u.id
    into v_owner_id
  from auth.users u
  where lower(u.email) = 'mahdi.alaei64@gmail.com'
    and u.email_confirmed_at is not null;

  if v_owner_id is null then
    raise exception 'confirmed_owner_auth_user_not_found';
  end if;

  insert into public.app_user_roles(user_id, role)
  values (v_owner_id, 'owner')
  on conflict (user_id) do update
    set role = 'owner';
end
$$;

comment on table public.app_user_roles is
  'Application roles keyed by Supabase Auth user UUID. Only controlled server-side flows may modify this table.';
comment on table public.manager_invites is
  'Pending store-manager invitations created by the authenticated invite-manager Edge Function.';


-- Preserve the existing admin panel and RPCs during the role-system rollout.
-- New owner/store_manager accounts are recognized as administrators for the
-- current operational RPCs. Fine-grained owner-only actions are separate.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    exists (
      select 1
      from public.app_user_roles r
      where r.user_id = (select auth.uid())
        and r.role in ('owner'::public.app_role, 'store_manager'::public.app_role)
    )
    or exists (
      select 1
      from public.admins a
      where a.email = lower(coalesce(auth.jwt() ->> 'email', ''))
    );
$$;

revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

create or replace function public._require_admin()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return lower(coalesce(auth.jwt() ->> 'email', ''));
end;
$$;

revoke all on function public._require_admin() from public, anon, authenticated;


-- Owner-only assignment for a pre-existing, email-verified Auth user.
-- Useful when the first store manager already has a Supabase account.
create or replace function public.owner_assign_store_manager(p_email text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner_id uuid := (select auth.uid());
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_target_id uuid;
begin
  if v_owner_id is null or not exists (
    select 1 from public.app_user_roles r
    where r.user_id = v_owner_id and r.role = 'owner'
  ) then
    raise exception 'owner_role_required' using errcode = '42501';
  end if;

  if v_email = '' or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'valid_email_required';
  end if;
  if v_email = 'mahdi.alaei64@gmail.com' then
    raise exception 'owner_account_cannot_be_assigned_as_manager';
  end if;

  select u.id into v_target_id
  from auth.users u
  where lower(u.email) = v_email
    and u.email_confirmed_at is not null;

  if v_target_id is null then
    raise exception 'verified_auth_user_not_found';
  end if;

  insert into public.app_user_roles(user_id, role, created_by)
  values (v_target_id, 'store_manager', v_owner_id)
  on conflict (user_id) do update
    set role = case
      when public.app_user_roles.role = 'owner' then 'owner'::public.app_role
      else 'store_manager'::public.app_role
    end;

  insert into public.audit_log(admin_email, action, new_data)
  values (
    lower(coalesce(auth.jwt() ->> 'email', '')),
    'assign_store_manager',
    jsonb_build_object('email', v_email, 'user_id', v_target_id)
  );

  return true;
end;
$$;

revoke all on function public.owner_assign_store_manager(text) from public, anon;
grant execute on function public.owner_assign_store_manager(text) to authenticated;
