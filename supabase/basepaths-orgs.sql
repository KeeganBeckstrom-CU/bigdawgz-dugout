-- =====================================================================
-- Basepaths: many teams ("organizations") in one app
--
-- HOW TO RUN: Supabase dashboard > SQL Editor > New query > paste all of
-- this > Run. Run it AFTER every dugout-*.sql file. Safe to run again.
--
-- What it does
--  * Accounts become Basepaths-wide. One email/password works for every
--    team a person belongs to.
--  * New tables: dg_orgs (each team: name, age group, season year, look)
--    and dg_members (who belongs to which team, as what, approved or not).
--  * Every team table (roster, payments, inbox, team settings, games, ...)
--    gets an org_id. The old table names now point at the open team only,
--    so all the existing app functions keep working, one team at a time.
--  * Your current BigDawgz data becomes the first team, and your coach
--    account (the first coach that was approved) becomes the Basepaths
--    admin. To make another account an admin later:
--      update dg_users set is_admin = true where email = 'you@email.com';
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- The team (org) a request is working in. Set by dg_me() for each request.
create or replace function dg_org() returns uuid
language sql stable as $$ select nullif(current_setting('dg.org', true), '')::uuid $$;

-- ---------- accounts become Basepaths-wide ----------
do $$ begin
  if to_regclass('public.dg_users') is null then
    alter table dg_accounts rename to dg_users;
  end if;
end $$;
alter table dg_users add column if not exists is_admin boolean not null default false;
alter table dg_users add column if not exists last_org uuid;
alter table dg_sessions add column if not exists org_id uuid;

create table if not exists dg_orgs (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  age text not null default '',
  year int,
  city text not null default '',
  status text not null default 'active' check (status in ('active','suspended')),
  brand jsonb not null default '{}'::jsonb,
  brand_v int not null default 0,
  created_by uuid references dg_users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists dg_members (
  org_id uuid not null references dg_orgs(id) on delete cascade,
  account_id uuid not null references dg_users(id) on delete cascade,
  role text not null check (role in ('player','parent','coach')),
  status text not null default 'pending' check (status in ('active','pending')),
  head boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (org_id, account_id)
);
create index if not exists dg_members_acct on dg_members(account_id);
alter table dg_orgs enable row level security;
alter table dg_members enable row level security;
revoke all on dg_orgs, dg_members from anon, authenticated;

-- ---------- the first team: everything already in the database ----------
do $$ declare oid uuid; tn text; nm text; ag text; yr int; c dg_users;
begin
  if exists (select 1 from dg_orgs) then return; end if;
  if not exists (select 1 from dg_users) and not exists (select 1 from dg_players) then return; end if;
  select coalesce(nullif(doc->>'team', ''), 'BigDawgz 12U') into tn from dg_team limit 1;
  tn := coalesce(tn, 'BigDawgz 12U');
  ag := coalesce(substring(tn from '(\d{1,2}U)\s*$'), '');
  nm := trim(case when ag <> '' then left(tn, length(tn) - length(ag)) else tn end);
  yr := extract(year from now())::int + case when extract(month from now()) >= 8 then 1 else 0 end;
  select * into c from dg_users where role = 'coach' and status = 'active' order by created_at limit 1;
  insert into dg_orgs(name, age, year, brand, brand_v, created_by)
    values (coalesce(nullif(nm, ''), tn), ag, yr,
            jsonb_build_object('preset', 'bigdawgz', 'primary', '#5C2B89', 'accent', '#E0BE58', 'dark', '#0B0B0D',
                               'logo', 'builtin:bigdawgz', 'venmo', 'keeganbeckstrom', 'legacy', true),
            1, c.id)
    returning id into oid;
  insert into dg_members(org_id, account_id, role, status, head)
    select oid, u.id, u.role, u.status, u.id = c.id from dg_users u;
  update dg_users set last_org = oid;
  update dg_sessions set org_id = oid;
  if c.id is not null then update dg_users set is_admin = true where id = c.id; end if;
end $$;

-- ---------- every team table gets an org_id ----------
-- dg_xxx becomes dg_xxx_all (every team) and a view named dg_xxx shows only
-- the open team, so existing functions keep working unchanged.
do $$ declare t text; legacy uuid; cols text;
begin
  select id into legacy from dg_orgs order by created_at limit 1;
  foreach t in array array['dg_players','dg_links','dg_inbox','dg_payments','dg_plans','dg_team',
                           'dg_live','dg_live_p','dg_live_a','dg_duel','dg_trades','dg_chal'] loop
    if to_regclass('public.' || t || '_all') is null and to_regclass('public.' || t) is not null then
      execute format('alter table %I rename to %I', t, t || '_all');
      execute format('alter table %I add column if not exists org_id uuid', t || '_all');
      if legacy is not null then
        execute format('update %I set org_id = %L where org_id is null', t || '_all', legacy);
      else
        execute format('delete from %I where org_id is null', t || '_all');
      end if;
      execute format('alter table %I alter column org_id set default dg_org()', t || '_all');
      execute format('alter table %I alter column org_id set not null', t || '_all');
      execute format('alter table %I add constraint %I foreign key (org_id) references dg_orgs(id) on delete cascade', t || '_all', t || '_org_fk');
      execute format('create index if not exists %I on %I(org_id)', t || '_org_ix', t || '_all');
    end if;
  end loop;
end $$;

-- one team-settings row per team (it used to be a single row with id 1)
do $$ begin
  if exists (select 1 from pg_constraint where conname = 'dg_team_id_check') then
    alter table dg_team_all drop constraint dg_team_id_check;
  end if;
  if exists (select 1 from pg_constraint where conname = 'dg_team_pkey') then
    alter table dg_team_all drop constraint dg_team_pkey;
    alter table dg_team_all add constraint dg_team_all_pkey primary key (org_id);
  end if;
  -- a player account can be on more than one team
  if exists (select 1 from pg_constraint where conname = 'dg_players_claimed_by_key') then
    alter table dg_players_all drop constraint dg_players_claimed_by_key;
    alter table dg_players_all add constraint dg_players_org_claim unique (org_id, claimed_by);
  end if;
end $$;

-- views: the open team only
do $$ declare t text; c text; cols text;
begin
  foreach t in array array['dg_players','dg_links','dg_inbox','dg_payments','dg_plans','dg_team',
                           'dg_live','dg_live_p','dg_live_a','dg_duel','dg_trades','dg_chal'] loop
    execute format('create or replace view %I as select * from %I where org_id = dg_org() with local check option', t, t || '_all');
    -- inserts through the view get the same defaults as the table
    for c, cols in select a.attname, pg_get_expr(d.adbin, d.adrelid)
                   from pg_attribute a join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                   where a.attrelid = (t || '_all')::regclass and not a.attisdropped loop
      execute format('alter view %I alter column %I set default %s', t, c, cols);
    end loop;
    execute format('revoke all on %I from public, anon, authenticated', t);
  end loop;
end $$;

-- accounts as seen inside the open team: the role and approval are the
-- person's membership on THIS team
create or replace view dg_accounts as
  select u.id, u.email, u.pw, u.name, m.role, m.status, u.created_at
  from dg_users u join dg_members m on m.account_id = u.id
  where m.org_id = dg_org();
revoke all on dg_accounts from public, anon, authenticated;

create or replace function dg_accounts_write() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then raise exception 'use_signup'; end if;
  if tg_op = 'DELETE' then
    -- "remove" takes the person off this team only; their account stays
    update dg_players_all set claimed_by = null where org_id = dg_org() and claimed_by = old.id;
    delete from dg_links_all where org_id = dg_org() and parent_id = old.id;
    delete from dg_members where org_id = dg_org() and account_id = old.id;
    update dg_sessions set org_id = null where account_id = old.id and org_id = dg_org();
    return old;
  end if;
  if new.pw is distinct from old.pw then
    -- a coach can only reset passwords of people who are on no other team
    if exists (select 1 from dg_members where account_id = old.id and org_id <> dg_org()) then
      raise exception 'pw_other_team';
    end if;
    update dg_users set pw = new.pw where id = old.id;
  end if;
  if new.name is distinct from old.name then update dg_users set name = left(new.name, 40) where id = old.id; end if;
  update dg_members set role = new.role, status = new.status where org_id = dg_org() and account_id = old.id;
  return new;
end $$;
drop trigger if exists dg_accounts_write on dg_accounts;
create trigger dg_accounts_write instead of insert or update or delete on dg_accounts
  for each row execute function dg_accounts_write();

-- ---------- who is calling, and on which team ----------
drop function if exists dg_coach(text);
drop function if exists dg_me(text);

-- signed-in person (no team needed)
create or replace function dg_user(p_tok text) returns dg_users
language plpgsql security definer set search_path = public as $$
declare u dg_users;
begin
  select x.* into u from dg_sessions s join dg_users x on x.id = s.account_id where s.token = p_tok;
  if u.id is null then raise exception 'signed_out'; end if;
  update dg_sessions set last_at = now() where token = p_tok;
  return u;
end $$;

-- signed-in person inside the team their session has open
create or replace function dg_me(p_tok text) returns dg_accounts
language plpgsql security definer set search_path = public as $$
declare s dg_sessions; u dg_users; m dg_members; o dg_orgs; a dg_accounts;
begin
  select * into s from dg_sessions where token = p_tok;
  if s.token is null then raise exception 'signed_out'; end if;
  update dg_sessions set last_at = now() where token = p_tok;
  select * into u from dg_users where id = s.account_id;
  if s.org_id is null then raise exception 'no_team'; end if;
  select * into o from dg_orgs where id = s.org_id;
  if o.id is null then update dg_sessions set org_id = null where token = p_tok; raise exception 'no_team'; end if;
  select * into m from dg_members where org_id = o.id and account_id = u.id;
  if m.account_id is null and not u.is_admin then raise exception 'not_on_team'; end if;
  if o.status <> 'active' and not u.is_admin then raise exception 'team_off'; end if;
  perform set_config('dg.org', o.id::text, true);
  a.id := u.id; a.email := u.email; a.pw := u.pw; a.name := u.name; a.created_at := u.created_at;
  a.role := coalesce(m.role, 'coach');      -- the Basepaths admin can open any team as a coach
  a.status := coalesce(m.status, 'active');
  return a;
end $$;

create or replace function dg_coach(p_tok text) returns dg_accounts
language plpgsql security definer set search_path = public as $$
declare a dg_accounts;
begin
  a := dg_me(p_tok);
  if a.role <> 'coach' or a.status <> 'active' then raise exception 'not_coach'; end if;
  return a;
end $$;

-- dg_duel_me returned the old table type; rebuild it on the view
drop function if exists dg_duel_me(text);
create or replace function dg_duel_me(p_tok text) returns dg_players
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; pl dg_players;
begin
  a := dg_me(p_tok);
  if a.role <> 'player' or a.status <> 'active' then raise exception 'players_only'; end if;
  select * into pl from dg_players where claimed_by = a.id;
  if pl.id is null then raise exception 'not_claimed'; end if;
  return pl;
end $$;

create or replace function dg_admin(p_tok text) returns dg_users
language plpgsql security definer set search_path = public as $$
declare u dg_users;
begin
  u := dg_user(p_tok);
  if not u.is_admin then raise exception 'not_admin'; end if;
  return u;
end $$;

-- the season a team plays in: fall counts toward next year
create or replace function dg_season() returns int
language sql stable as $$ select extract(year from now())::int + case when extract(month from now()) >= 8 then 1 else 0 end $$;

revoke execute on function dg_user(text), dg_me(text), dg_coach(text), dg_duel_me(text), dg_admin(text) from public, anon, authenticated;

-- ---------- sign up / sign in (Basepaths-wide) ----------
create or replace function dz_signup(p_email text, p_pw text, p_name text, p_role text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare e text := lower(trim(coalesce(p_email, ''))); nm text := trim(coalesce(p_name, '')); uid uuid;
begin
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'bad_email'; end if;
  if length(coalesce(p_pw, '')) < 6 then raise exception 'short_password'; end if;
  if nm = '' then raise exception 'need_name'; end if;
  if p_role not in ('player','parent','coach') then raise exception 'bad_role'; end if;
  if exists (select 1 from dg_users where email = e) then raise exception 'taken'; end if;
  insert into dg_users(email, pw, name, role, status)
    values (e, extensions.crypt(p_pw, extensions.gen_salt('bf')), left(nm, 40), p_role, 'active') returning id into uid;
  return jsonb_build_object('token', dg_new_session(uid));
end $$;

create or replace function dz_login(p_email text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u dg_users; t text;
begin
  select * into u from dg_users where email = lower(trim(coalesce(p_email, '')));
  if u.id is null or u.pw <> extensions.crypt(coalesce(p_pw, ''), u.pw) then raise exception 'bad_login'; end if;
  t := dg_new_session(u.id);
  -- reopen the last team they were in (keeps older app versions working)
  if u.last_org is not null and exists (select 1 from dg_members m join dg_orgs o on o.id = m.org_id
       where m.org_id = u.last_org and m.account_id = u.id and m.status = 'active' and o.status = 'active') then
    update dg_sessions set org_id = u.last_org where token = t;
  end if;
  return jsonb_build_object('token', t);
end $$;

create or replace function dz_logout(p_tok text) returns jsonb
language sql security definer set search_path = public as $$
  delete from dg_sessions where token = p_tok returning jsonb_build_object('ok', true);
$$;

-- ---------- the Basepaths home page: my teams ----------
create or replace function dg_org_card(o dg_orgs) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', o.id, 'name', o.name, 'age', o.age, 'year', o.year, 'city', o.city,
    'org_status', o.status, 'brand_v', o.brand_v,
    'colors', jsonb_build_object('primary', o.brand->>'primary', 'accent', o.brand->>'accent', 'dark', o.brand->>'dark'),
    'logo', case when length(coalesce(o.brand->>'logo', '')) < 120000 then o.brand->>'logo' else null end,
    'coaches', coalesce((select jsonb_agg(u.name order by m.head desc, m.created_at) from dg_members m join dg_users u on u.id = m.account_id
                         where m.org_id = o.id and m.role = 'coach' and m.status = 'active'), '[]'::jsonb));
$$;
revoke execute on function dg_org_card(dg_orgs) from public, anon, authenticated;

create or replace function dz_home(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users; cur uuid;
begin
  u := dg_user(p_tok);
  select org_id into cur from dg_sessions where token = p_tok;
  return jsonb_build_object(
    'user', jsonb_build_object('id', u.id, 'name', u.name, 'email', u.email, 'role', u.role, 'admin', u.is_admin),
    'cur', cur, 'season', dg_season(),
    'orgs', coalesce((select jsonb_agg(dg_org_card(o) || jsonb_build_object('role', m.role, 'status', m.status, 'head', m.head,
                        'pending', case when m.role = 'coach' and m.status = 'active'
                                   then (select count(*) from dg_members x where x.org_id = o.id and x.status = 'pending') else 0 end)
                        order by o.year desc nulls last, o.name)
                      from dg_members m join dg_orgs o on o.id = m.org_id where m.account_id = u.id), '[]'::jsonb));
end $$;

create or replace function dz_org_search(p_tok text, p_q text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users; q text := lower(trim(coalesce(p_q, ''))); w text[];
begin
  u := dg_user(p_tok);
  if length(q) < 2 then return jsonb_build_object('orgs', '[]'::jsonb); end if;
  w := regexp_split_to_array(q, '\s+');
  return jsonb_build_object('orgs', coalesce((
    select jsonb_agg(dg_org_card(o) || jsonb_build_object('mine', m.status, 'role', m.role) order by o.year desc nulls last, o.name)
    from dg_orgs o
    left join dg_members m on m.org_id = o.id and m.account_id = u.id
    where o.id in (select o2.id from dg_orgs o2 where o2.status = 'active'
            and not exists (select 1 from unnest(w) x
                            where position(x in lower(o2.name || ' ' || o2.age || ' ' || coalesce(o2.year::text, '') || ' ' || o2.city)) = 0)
          order by o2.year desc nulls last, o2.name limit 30)), '[]'::jsonb));
end $$;

-- ask to join a team as a player, parent or coach. A coach on that team approves.
create or replace function dz_org_join(p_tok text, p_org uuid, p_role text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users; o dg_orgs;
begin
  u := dg_user(p_tok);
  if p_role not in ('player','parent','coach') then raise exception 'bad_role'; end if;
  select * into o from dg_orgs where id = p_org;
  if o.id is null or o.status <> 'active' then raise exception 'no_team_found'; end if;
  if exists (select 1 from dg_members where org_id = o.id and account_id = u.id) then raise exception 'already_asked'; end if;
  insert into dg_members(org_id, account_id, role, status) values (o.id, u.id, p_role, 'pending');
  return jsonb_build_object('ok', true);
end $$;

-- take back a request, or leave a team
create or replace function dz_org_leave(p_tok text, p_org uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users; m dg_members;
begin
  u := dg_user(p_tok);
  select * into m from dg_members where org_id = p_org and account_id = u.id;
  if m.account_id is null then return jsonb_build_object('ok', true); end if;
  if m.role = 'coach' and m.status = 'active'
     and (select count(*) from dg_members where org_id = p_org and role = 'coach' and status = 'active') <= 1
     and exists (select 1 from dg_members where org_id = p_org and account_id <> u.id) then
    raise exception 'last_coach';
  end if;
  update dg_players_all set claimed_by = null where org_id = p_org and claimed_by = u.id;
  delete from dg_links_all where org_id = p_org and parent_id = u.id;
  delete from dg_members where org_id = p_org and account_id = u.id;
  update dg_sessions set org_id = null where account_id = u.id and org_id = p_org;
  return jsonb_build_object('ok', true);
end $$;

-- a head coach makes a new team
create or replace function dz_org_create(p_tok text, p_name text, p_age text, p_year int, p_city text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users; oid uuid; nm text := left(trim(coalesce(p_name, '')), 40); ag text := upper(left(trim(coalesce(p_age, '')), 12));
begin
  u := dg_user(p_tok);
  if u.role <> 'coach' and not u.is_admin then raise exception 'coach_makes_team'; end if;
  if nm = '' then raise exception 'need_name'; end if;
  if p_year is not null and (p_year < 2000 or p_year > 2100) then raise exception 'bad_year'; end if;
  if exists (select 1 from dg_orgs where lower(name) = lower(nm) and lower(age) = lower(ag) and year is not distinct from p_year) then
    raise exception 'team_exists';
  end if;
  insert into dg_orgs(name, age, year, city, created_by, brand)
    values (nm, ag, p_year, left(trim(coalesce(p_city, '')), 40), u.id, '{}'::jsonb) returning id into oid;
  insert into dg_members(org_id, account_id, role, status, head) values (oid, u.id, 'coach', 'active', true);
  insert into dg_team_all(org_id, id, doc) values (oid, 1, jsonb_build_object(
    'team', trim(nm || ' ' || ag), 'sched', '[]'::jsonb, 'dues', jsonb_build_object('total', 0, 'due', ''),
    'fund', jsonb_build_object('raised', 0, 'goal', 0)));
  update dg_sessions set org_id = oid where token = p_tok;
  update dg_users set last_org = oid where id = u.id;
  return jsonb_build_object('ok', true, 'id', oid);
end $$;

-- open a team (null = back to the Basepaths home page)
create or replace function dz_org_open(p_tok text, p_org uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users; o dg_orgs; m dg_members;
begin
  u := dg_user(p_tok);
  if p_org is null then update dg_sessions set org_id = null where token = p_tok; return jsonb_build_object('ok', true); end if;
  select * into o from dg_orgs where id = p_org;
  if o.id is null then raise exception 'no_team_found'; end if;
  select * into m from dg_members where org_id = o.id and account_id = u.id;
  if not u.is_admin then
    if m.account_id is null then raise exception 'not_on_team'; end if;
    if m.status <> 'active' then raise exception 'still_pending'; end if;
    if o.status <> 'active' then raise exception 'team_off'; end if;
  end if;
  update dg_sessions set org_id = o.id where token = p_tok;
  update dg_users set last_org = o.id where id = u.id;
  return jsonb_build_object('ok', true, 'org', dg_org_card(o) || jsonb_build_object('role', coalesce(m.role, 'coach'), 'status', coalesce(m.status, 'active')));
end $$;

-- the open team's look (logo, pictures, colors) for everyone on the team
-- p_have: the version the app already has saved; the pictures only come back when they changed
drop function if exists dz_brand(text);
create or replace function dz_brand(p_tok text, p_have int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; o dg_orgs;
begin
  a := dg_me(p_tok);
  select * into o from dg_orgs where id = dg_org();
  if p_have is not null and p_have = o.brand_v then
    return jsonb_build_object('org', dg_org_card(o), 'brand_v', o.brand_v);
  end if;
  return jsonb_build_object('org', dg_org_card(o), 'brand', o.brand, 'brand_v', o.brand_v);
end $$;

-- coach: save the team's look and details. Everyone's app updates on its next sync.
create or replace function dz_brand_save(p_tok text, p_brand jsonb, p_org jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; nm text; v int;
begin
  a := dg_coach(p_tok);
  if p_brand is not null then
    if jsonb_typeof(p_brand) <> 'object' then raise exception 'bad_brand'; end if;
    if octet_length(p_brand::text) > 1500000 then raise exception 'brand_too_big'; end if;
    update dg_orgs set brand = p_brand, brand_v = brand_v + 1 where id = dg_org() returning brand_v into v;
  end if;
  if p_org is not null then
    nm := left(trim(coalesce(p_org->>'name', '')), 40);
    if nm = '' then raise exception 'need_name'; end if;
    update dg_orgs set name = nm, age = upper(left(trim(coalesce(p_org->>'age', '')), 12)),
      year = nullif(p_org->>'year', '')::int, city = left(trim(coalesce(p_org->>'city', '')), 40), brand_v = brand_v + 1
      where id = dg_org() returning brand_v into v;
  end if;
  return jsonb_build_object('ok', true, 'brand_v', v);
end $$;

-- ---------- Basepaths admin (you) ----------
create or replace function dz_sa(p_tok text, p_action text, p_id uuid default null, p_val jsonb default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u dg_users; v text := p_val #>> '{}'; q text; o dg_orgs;
begin
  u := dg_admin(p_tok);

  if p_action = 'overview' then
    return jsonb_build_object(
      'totals', jsonb_build_object(
        'orgs', (select count(*) from dg_orgs), 'active', (select count(*) from dg_orgs where status = 'active'),
        'users', (select count(*) from dg_users), 'players', (select count(*) from dg_players_all where not sample),
        'pending', (select count(*) from dg_members where status = 'pending'),
        'new7', (select count(*) from dg_users where created_at > now() - interval '7 days'),
        'live7', (select count(distinct account_id) from dg_sessions where last_at > now() - interval '7 days')),
      'orgs', coalesce((select jsonb_agg(dg_org_card(o2) || jsonb_build_object(
          'created_at', o2.created_at,
          'made_by', (select x.email from dg_users x where x.id = o2.created_by),
          'members', (select count(*) from dg_members m where m.org_id = o2.id and m.status = 'active'),
          'pending', (select count(*) from dg_members m where m.org_id = o2.id and m.status = 'pending'),
          'players', (select count(*) from dg_players_all p where p.org_id = o2.id and not p.sample),
          'last_at', (select max(s.last_at) from dg_sessions s where s.org_id = o2.id)) order by o2.created_at desc)
        from dg_orgs o2), '[]'::jsonb));
  end if;

  if p_action = 'members' then
    return jsonb_build_object('members', coalesce((select jsonb_agg(jsonb_build_object(
        'id', x.id, 'name', x.name, 'email', x.email, 'role', m.role, 'status', m.status, 'head', m.head, 'at', m.created_at)
        order by m.status desc, m.role, x.name)
      from dg_members m join dg_users x on x.id = m.account_id where m.org_id = p_id), '[]'::jsonb));
  end if;

  if p_action = 'users' then
    q := lower(trim(coalesce(p_val->>'q', '')));
    return jsonb_build_object('users', coalesce((select jsonb_agg(jsonb_build_object(
        'id', x.id, 'name', x.name, 'email', x.email, 'role', x.role, 'admin', x.is_admin, 'at', x.created_at,
        'last_at', (select max(s.last_at) from dg_sessions s where s.account_id = x.id),
        'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', o3.id, 'name', trim(o3.name || ' ' || o3.age), 'year', o3.year, 'role', m.role, 'status', m.status))
                          from dg_members m join dg_orgs o3 on o3.id = m.org_id where m.account_id = x.id), '[]'::jsonb))
        order by x.created_at desc)
      from (select * from dg_users y where q = '' or position(q in lower(y.name || ' ' || y.email)) > 0 order by y.created_at desc limit 200) x), '[]'::jsonb));
  end if;

  if p_action = 'org_status' then
    if v not in ('active','suspended') then raise exception 'bad_action'; end if;
    update dg_orgs set status = v where id = p_id;
  elsif p_action = 'org_edit' then
    if trim(coalesce(p_val->>'name', '')) = '' then raise exception 'need_name'; end if;
    update dg_orgs set name = left(trim(p_val->>'name'), 40), age = upper(left(trim(coalesce(p_val->>'age', '')), 12)),
      year = nullif(p_val->>'year', '')::int, city = left(trim(coalesce(p_val->>'city', '')), 40), brand_v = brand_v + 1 where id = p_id;
  elsif p_action = 'org_delete' then
    if v is distinct from 'DELETE' then raise exception 'type_delete'; end if;
    update dg_sessions set org_id = null where org_id = p_id;
    update dg_users set last_org = null where last_org = p_id;
    delete from dg_orgs where id = p_id;
  elsif p_action = 'member_set' then
    if p_val->>'role' not in ('player','parent','coach') or p_val->>'status' not in ('active','pending') then raise exception 'bad_role'; end if;
    insert into dg_members(org_id, account_id, role, status) values (p_id, (p_val->>'account')::uuid, p_val->>'role', p_val->>'status')
      on conflict (org_id, account_id) do update set role = excluded.role, status = excluded.status;
  elsif p_action = 'member_head' then
    update dg_members set head = (account_id = (p_val->>'account')::uuid) where org_id = p_id;
  elsif p_action = 'member_remove' then
    update dg_players_all set claimed_by = null where org_id = p_id and claimed_by = (p_val->>'account')::uuid;
    delete from dg_links_all where org_id = p_id and parent_id = (p_val->>'account')::uuid;
    delete from dg_members where org_id = p_id and account_id = (p_val->>'account')::uuid;
    update dg_sessions set org_id = null where org_id = p_id and account_id = (p_val->>'account')::uuid;
  elsif p_action = 'user_pw' then
    if length(coalesce(v, '')) < 6 then raise exception 'short_password'; end if;
    update dg_users set pw = extensions.crypt(v, extensions.gen_salt('bf')) where id = p_id;
    delete from dg_sessions where account_id = p_id;
  elsif p_action = 'user_role' then
    if v not in ('player','parent','coach') then raise exception 'bad_role'; end if;
    update dg_users set role = v where id = p_id;
  elsif p_action = 'user_admin' then
    if p_id = u.id then raise exception 'not_yourself'; end if;
    update dg_users set is_admin = (v = 'true') where id = p_id;
  elsif p_action = 'user_delete' then
    if p_id = u.id then raise exception 'not_yourself'; end if;
    delete from dg_users where id = p_id;
  else
    raise exception 'bad_action';
  end if;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function dz_signup(text,text,text,text), dz_login(text,text), dz_logout(text),
  dz_home(text), dz_org_search(text,text), dz_org_join(text,uuid,text), dz_org_leave(text,uuid),
  dz_org_create(text,text,text,int,text), dz_org_open(text,uuid), dz_brand(text,int), dz_brand_save(text,jsonb,jsonb),
  dz_sa(text,text,uuid,jsonb)
  to anon, authenticated;

-- every app function re-reads the tables by name on its next call
do $$ declare r record; begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'dz\_%' or p.proname like 'dg\_%') and p.prokind = 'f' loop
    execute 'alter function ' || r.sig || ' set search_path = public, extensions';
  end loop;
end $$;

notify pgrst, 'reload schema';
