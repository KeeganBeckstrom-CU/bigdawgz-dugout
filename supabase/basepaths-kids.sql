-- =====================================================================
-- Basepaths: kids' accounts are set up by a parent (COPPA), and anyone
-- can delete their account (App Store rule).
--
-- HOW TO RUN: Supabase > SQL Editor > paste all of this > Run.
-- Run it AFTER basepaths-orgs.sql. Safe to run again.
--
--  * Players under 13 don't sign themselves up. A parent signs up as a
--    Parent and taps "Add my player": they pick the kid's name, a username
--    and a password. That records the parent's OK (consent_at).
--  * Kids sign in with that username (no email needed).
--  * Parents can reset a kid's password or delete the kid's account and
--    everything on it. Kids already on a team before this show up for their
--    linked parent as "Confirm".
--  * Every account can delete itself from My teams.
-- =====================================================================

alter table dg_users add column if not exists kid boolean not null default false;
alter table dg_users add column if not exists parent_id uuid references dg_users(id) on delete cascade;
alter table dg_users add column if not exists consent_at timestamptz;
-- which wording the parent checked, so there's a record of exactly what they agreed to
alter table dg_users add column if not exists consent_ver text;
create index if not exists dg_users_parent on dg_users(parent_id);

-- kid usernames are stored as <username>@kid.basepaths so they can't clash with real emails
create or replace function dg_kid_email(p_user text) returns text
language sql immutable as $$ select lower(trim(coalesce(p_user, ''))) || '@kid.basepaths' $$;

-- sign in with an email, or with the username a parent made
create or replace function dz_login(p_email text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u dg_users; t text; e text := lower(trim(coalesce(p_email, '')));
begin
  if position('@' in e) = 0 then e := dg_kid_email(e); end if;
  select * into u from dg_users where email = e;
  if u.id is null or u.pw <> extensions.crypt(coalesce(p_pw, ''), u.pw) then raise exception 'bad_login'; end if;
  t := dg_new_session(u.id);
  if u.last_org is not null and exists (select 1 from dg_members m join dg_orgs o on o.id = m.org_id
       where m.org_id = u.last_org and m.account_id = u.id and m.status = 'active' and o.status = 'active') then
    update dg_sessions set org_id = u.last_org where token = t;
  end if;
  return jsonb_build_object('token', t);
end $$;

-- kids a parent is responsible for: ones they made, plus players linked to them on a team who have no parent OK yet
create or replace function dg_my_kids(p uuid) returns setof dg_users
language sql stable security definer set search_path = public as $$
  select * from dg_users where parent_id = p
  union
  select k.* from dg_links_all l join dg_players_all pl on pl.id = l.player_id and pl.org_id = l.org_id
    join dg_users k on k.id = pl.claimed_by
  where l.parent_id = p and l.status = 'active' and k.role = 'player' and k.parent_id is null and not k.is_admin;
$$;
revoke execute on function dg_my_kids(uuid) from public, anon, authenticated;

create or replace function dz_kids(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users;
begin
  u := dg_user(p_tok);
  return jsonb_build_object('kids', coalesce((select jsonb_agg(jsonb_build_object(
      'id', k.id, 'name', k.name, 'user', case when k.kid then split_part(k.email, '@', 1) else k.email end, 'kid', k.kid,
      'ok', k.parent_id = u.id and k.consent_at is not null, 'at', k.consent_at,
      'teams', coalesce((select jsonb_agg(trim(o.name || ' ' || o.age) order by o.year desc nulls last) from dg_members m join dg_orgs o on o.id = m.org_id
                         where m.account_id = k.id and m.status = 'active'), '[]'::jsonb)) order by k.name)
    from dg_my_kids(u.id) k), '[]'::jsonb));
end $$;

-- the box parents check. Change the version if you change the wording in the app.
create or replace function dg_consent_ver() returns text language sql immutable as $$ select 'parent-ok-v1' $$;

drop function if exists dz_kid_add(text, text, text, text);
drop function if exists dz_kid_ok(text, uuid);

-- a parent makes a login for their player. They must check the permission box (p_consent).
create or replace function dz_kid_add(p_tok text, p_name text, p_user text, p_pw text, p_consent boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u dg_users; nm text := left(trim(coalesce(p_name, '')), 40); un text := lower(trim(coalesce(p_user, ''))); kid_id uuid;
begin
  u := dg_user(p_tok);
  if u.kid or u.role = 'player' then raise exception 'parents_only'; end if;
  if nm = '' then raise exception 'need_name'; end if;
  if un !~ '^[a-z0-9][a-z0-9._-]{2,19}$' then raise exception 'bad_username'; end if;
  if length(coalesce(p_pw, '')) < 6 then raise exception 'short_password'; end if;
  if exists (select 1 from dg_users where email = dg_kid_email(un)) then raise exception 'username_taken'; end if;
  if (select count(*) from dg_users where parent_id = u.id) >= 8 then raise exception 'too_many_kids'; end if;
  if p_consent is not true then raise exception 'need_consent'; end if;
  insert into dg_users(email, pw, name, role, status, kid, parent_id, consent_at, consent_ver)
    values (dg_kid_email(un), extensions.crypt(p_pw, extensions.gen_salt('bf')), nm, 'player', 'active', true, u.id, now(), dg_consent_ver())
    returning dg_users.id into kid_id;
  return jsonb_build_object('ok', true, 'id', kid_id, 'user', un);
end $$;

-- a parent OKs a player account that was made before parents set them up (must check the box too)
create or replace function dz_kid_ok(p_tok text, p_kid uuid, p_consent boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users;
begin
  u := dg_user(p_tok);
  if not exists (select 1 from dg_my_kids(u.id) k where k.id = p_kid) then raise exception 'not_your_player'; end if;
  if p_consent is not true then raise exception 'need_consent'; end if;
  update dg_users set parent_id = u.id, consent_at = now(), consent_ver = dg_consent_ver() where id = p_kid;
  return jsonb_build_object('ok', true);
end $$;

create or replace function dz_kid_pw(p_tok text, p_kid uuid, p_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u dg_users;
begin
  u := dg_user(p_tok);
  if not exists (select 1 from dg_users where id = p_kid and parent_id = u.id) then raise exception 'not_your_player'; end if;
  if length(coalesce(p_pw, '')) < 6 then raise exception 'short_password'; end if;
  update dg_users set pw = extensions.crypt(p_pw, extensions.gen_salt('bf')) where id = p_kid;
  delete from dg_sessions where account_id = p_kid;
  return jsonb_build_object('ok', true);
end $$;

-- a parent deletes their player's account and everything tied to it
create or replace function dz_kid_delete(p_tok text, p_kid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users;
begin
  u := dg_user(p_tok);
  if not exists (select 1 from dg_my_kids(u.id) k where k.id = p_kid) then raise exception 'not_your_player'; end if;
  delete from dg_users where id = p_kid;
  return jsonb_build_object('ok', true);
end $$;

-- anyone deletes their own account (needs their password). Their kids' accounts go with it.
create or replace function dz_account_delete(p_tok text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u dg_users; t text;
begin
  u := dg_user(p_tok);
  if u.pw <> extensions.crypt(coalesce(p_pw, ''), u.pw) then raise exception 'bad_password'; end if;
  select o.name || coalesce(' ' || nullif(o.age, ''), '') into t from dg_members m join dg_orgs o on o.id = m.org_id
    where m.account_id = u.id and m.role = 'coach' and m.status = 'active'
      and not exists (select 1 from dg_members x where x.org_id = m.org_id and x.account_id <> u.id and x.role = 'coach' and x.status = 'active')
      and exists (select 1 from dg_members x where x.org_id = m.org_id and x.account_id <> u.id)
    limit 1;
  if t is not null then raise exception 'only_coach:%', t; end if;
  if u.is_admin and (select count(*) from dg_users where is_admin) <= 1 then raise exception 'only_admin'; end if;
  delete from dg_users where id = u.id;
  return jsonb_build_object('ok', true);
end $$;

-- kid accounts join teams as players only, and can't make teams
create or replace function dz_org_join(p_tok text, p_org uuid, p_role text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users; o dg_orgs;
begin
  u := dg_user(p_tok);
  if p_role not in ('player','parent','coach') then raise exception 'bad_role'; end if;
  if u.kid and p_role <> 'player' then raise exception 'kids_join_as_player'; end if;
  select * into o from dg_orgs where id = p_org;
  if o.id is null or o.status <> 'active' then raise exception 'no_team_found'; end if;
  if exists (select 1 from dg_members where org_id = o.id and account_id = u.id) then raise exception 'already_asked'; end if;
  insert into dg_members(org_id, account_id, role, status) values (o.id, u.id, p_role, 'pending');
  return jsonb_build_object('ok', true);
end $$;

-- My teams also says whether this is a kid account and how many players a parent still needs to confirm
create or replace function dz_home(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users; cur uuid;
begin
  u := dg_user(p_tok);
  select org_id into cur from dg_sessions where token = p_tok;
  return jsonb_build_object(
    'user', jsonb_build_object('id', u.id, 'name', u.name, 'email', case when u.kid then split_part(u.email, '@', 1) else u.email end,
      'role', u.role, 'admin', u.is_admin, 'kid', u.kid,
      'kids', (select count(*) from dg_my_kids(u.id)),
      'confirm', (select count(*) from dg_my_kids(u.id) k where k.parent_id is distinct from u.id or k.consent_at is null)),
    'cur', cur, 'season', dg_season(),
    'orgs', coalesce((select jsonb_agg(dg_org_card(o) || jsonb_build_object('role', m.role, 'status', m.status, 'head', m.head,
                        'pending', case when m.role = 'coach' and m.status = 'active'
                                   then (select count(*) from dg_members x where x.org_id = o.id and x.status = 'pending') else 0 end)
                        order by o.year desc nulls last, o.name)
                      from dg_members m join dg_orgs o on o.id = m.org_id where m.account_id = u.id), '[]'::jsonb));
end $$;

grant execute on function dz_login(text,text), dz_kids(text), dz_kid_add(text,text,text,text,boolean), dz_kid_ok(text,uuid,boolean),
  dz_kid_pw(text,uuid,text), dz_kid_delete(text,uuid), dz_account_delete(text,text), dz_org_join(text,uuid,text), dz_home(text)
  to anon, authenticated;
revoke execute on function dg_kid_email(text) from public, anon, authenticated;

do $$ declare r record; begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'dz\_%' or p.proname like 'dg\_%') and p.prokind = 'f' loop
    execute 'alter function ' || r.sig || ' set search_path = public, extensions';
  end loop;
end $$;

notify pgrst, 'reload schema';
