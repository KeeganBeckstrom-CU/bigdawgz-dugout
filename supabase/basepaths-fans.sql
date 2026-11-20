-- =====================================================================
-- Basepaths: fans (a brother or sister on the team, schedule only),
-- who can join as what, auto-approve for admins and test sign-ups,
-- and a one-time $300 dues credit for every BigDawgz family.
--
-- HOW TO RUN: Supabase > SQL Editor > paste all of this > Run.
-- Run it AFTER basepaths-families.sql. Safe to run again.
--
--  * Player accounts (and kids) join a team as a Player or a Fan.
--    Grown-ups join as a Parent or a Coach.
--  * Fans see the team's schedule only.
--  * A Basepaths admin who asks to join a team is in right away.
-- =====================================================================

do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'dg_members'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%role%' loop
    execute format('alter table dg_members drop constraint %I', c);
  end loop;
  alter table dg_members add constraint dg_members_role_check check (role in ('player','parent','coach','fan'));
end $$;

-- who can join as what: player accounts are Players or Fans, grown-ups are Parents or Coaches.
-- A Basepaths admin is let in right away.
create or replace function dz_org_join(p_tok text, p_org uuid, p_role text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users; o dg_orgs; st text;
begin
  u := dg_user(p_tok);
  if p_role not in ('player','parent','coach','fan') then raise exception 'bad_role'; end if;
  if (u.kid or u.role = 'player') and p_role not in ('player','fan') then raise exception 'players_join_as_player_or_fan'; end if;
  if not (u.kid or u.role = 'player') and p_role not in ('parent','coach') then raise exception 'grownups_join_as_parent_or_coach'; end if;
  select * into o from dg_orgs where id = p_org;
  if o.id is null or o.status <> 'active' then raise exception 'no_team_found'; end if;
  if exists (select 1 from dg_members where org_id = o.id and account_id = u.id) then raise exception 'already_asked'; end if;
  st := case when u.is_admin then 'active' else 'pending' end;
  insert into dg_members(org_id, account_id, role, status) values (o.id, u.id, p_role, st);
  return jsonb_build_object('ok', true, 'status', st);
end $$;

-- parents' screen-time limits and bonus minutes reach the kid's app (they were being dropped)
create or replace function dz_parent(p_tok text, p_action text, p_kid uuid, p_val jsonb default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare a dg_accounts; ok boolean; it jsonb; f text; n int;
begin
  a := dg_me(p_tok);
  if a.role <> 'parent' then raise exception 'bad_role'; end if;
  if p_action = 'pick' then
    if not exists (select 1 from dg_players where id = p_kid) then raise exception 'no_player'; end if;
    insert into dg_links(parent_id, player_id) values (a.id, p_kid) on conflict do nothing;
    return jsonb_build_object('ok', true);
  end if;
  if p_action = 'unlink' then
    delete from dg_links where parent_id = a.id and player_id = p_kid;
    return jsonb_build_object('ok', true);
  end if;
  select exists (select 1 from dg_links where parent_id = a.id and player_id = p_kid and status = 'active') into ok;
  if not ok then raise exception 'not_linked'; end if;
  if p_action = 'push' then
    for it in select * from jsonb_array_elements(coalesce(p_val, '[]'::jsonb)) loop
      if it->>'kind' in ('plog','pain','cheer','scr','scrb') then
        insert into dg_inbox(aid, player_id, item) values (coalesce(it->>'aid', gen_random_uuid()::text), p_kid, (it - 'aid') || jsonb_build_object('from', a.name)) on conflict (aid) do nothing;
      end if;
    end loop;
  elsif p_action = 'plan' then
    f := p_val->>'freq';
    if f is null then delete from dg_plans where player_id = p_kid; return jsonb_build_object('ok', true); end if;
    if f not in ('weekly','biweekly','semimonthly','monthly','once','none') then raise exception 'bad_plan'; end if;
    n := case when f in ('once','none') then case when f = 'once' then 1 else null end else (p_val->>'n')::int end;
    if f not in ('none') and (n is null or n < 1 or n > 52 or (p_val->>'start') is null) then raise exception 'bad_plan'; end if;
    insert into dg_plans(player_id, freq, start_on, n, base, set_by, set_at)
      values (p_kid, f, case when f = 'none' then null else (p_val->>'start')::date end, n,
              coalesce((select sum(amount) from dg_payments where player_id = p_kid and kind = 'dues'), 0), a.id, now())
      on conflict (player_id) do update set freq = excluded.freq, start_on = excluded.start_on, n = excluded.n, base = excluded.base, set_by = excluded.set_by, set_at = now();
  elsif p_action = 'kidpw' then
    if length(coalesce(p_val->>'pw', '')) < 6 then raise exception 'short_password'; end if;
    update dg_accounts set pw = extensions.crypt(p_val->>'pw', extensions.gen_salt('bf'))
      where id = (select claimed_by from dg_players where id = p_kid);
    if not found then raise exception 'no_login'; end if;
    delete from dg_sessions where account_id = (select claimed_by from dg_players where id = p_kid);
  else
    raise exception 'bad_action';
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- a fan's view of the team: name and schedule, nothing else
create or replace function dz_fan(p_tok text, p_org uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users; o dg_orgs;
begin
  u := dg_user(p_tok);
  select * into o from dg_orgs where id = p_org;
  if o.id is null then raise exception 'no_team_found'; end if;
  if not exists (select 1 from dg_members where org_id = o.id and account_id = u.id and status = 'active') and not u.is_admin then raise exception 'not_on_team'; end if;
  update dg_users set last_org = o.id where id = u.id;
  update dg_sessions set org_id = o.id where token = p_tok;
  return jsonb_build_object('id', o.id, 'name', o.name, 'age', o.age, 'year', o.year, 'preset', o.brand->>'preset',
    'sched', (select t.doc->'sched' from dg_team_all t where t.org_id = o.id));
end $$;

-- an admin's test sign-up gets let in to the team it asked to join
create or replace function dz_test_approve(p_tok text, p_test text, p_org uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_users; t uuid;
begin
  a := dg_admin(p_tok);
  select account_id into t from dg_sessions where token = p_test;
  if t is null then raise exception 'signed_out'; end if;
  update dg_members set status = 'active' where org_id = p_org and account_id = t;
  return jsonb_build_object('ok', true);
end $$;

-- one-time: $300 toward the season fee for every BigDawgz family (Nov 19, 2026)
do $$ declare o uuid;
begin
  select id into o from dg_orgs where lower(replace(name, ' ', '')) like 'bigdawgz%' order by created_at limit 1;
  if o is null then return; end if;
  insert into dg_imports(key) values ('credit300-2026-11-19') on conflict do nothing;
  if not found then return; end if;
  insert into dg_payments_all(org_id, player_id, amount, paid_on, method, note, kind)
    select o, p.id, 300, date '2026-11-19', 'Other', '$300 added by Coach', 'dues' from dg_players_all p where p.org_id = o and not p.sample;
  insert into dg_unmatched(org_id, payer, kind, amount, paid_on, method, note)
    select distinct on (payer) o, payer, 'dues', 300, date '2026-11-19', 'Other', '$300 added by Coach' from dg_unmatched where org_id = o;
end $$;

grant execute on function dz_org_join(text,uuid,text), dz_fan(text,uuid), dz_test_approve(text,text,uuid) to anon, authenticated;

do $$ declare r record; begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'dz\_%' or p.proname like 'dg\_%') and p.prokind = 'f' loop
    execute 'alter function ' || r.sig || ' set search_path = public, extensions';
  end loop;
end $$;

notify pgrst, 'reload schema';
