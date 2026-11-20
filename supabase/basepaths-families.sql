-- =====================================================================
-- Basepaths: families, fundraising per family, profiles on a shared
-- device, test sign-ups, and "who is this number?" lists for admins.
--
-- HOW TO RUN: Supabase > SQL Editor > paste all of this > Run.
-- Run it AFTER basepaths-kids.sql. Safe to run again.
--
--  * Payments are either team dues or fundraising (kind). Fundraising
--    shows on the family's own screen, like dues. Nobody else sees it.
--  * Money from someone whose player isn't in the app yet waits in a
--    coach-only "not matched yet" list until the coach matches it.
--  * One-time import of the BigDawgz Venmo tracker (Nov 19, 2026).
--  * A parent can switch to a kid's profile on the same phone.
--  * Admins can run a test sign-up that deletes itself afterwards.
-- =====================================================================

-- ---------- dues or fundraising ----------
alter table dg_payments_all add column if not exists kind text not null default 'dues';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'dg_payments_kind_ck') then
    alter table dg_payments_all add constraint dg_payments_kind_ck check (kind in ('dues','fund'));
  end if;
end $$;
create or replace view dg_payments as select * from dg_payments_all where org_id = dg_org() with local check option;
do $$ declare c text; d text; begin
  for c, d in select a.attname, pg_get_expr(x.adbin, x.adrelid) from pg_attribute a join pg_attrdef x on x.adrelid = a.attrelid and x.adnum = a.attnum
              where a.attrelid = 'dg_payments_all'::regclass and not a.attisdropped loop
    execute format('alter view dg_payments alter column %I set default %s', c, d);
  end loop;
end $$;
revoke all on dg_payments from public, anon, authenticated;

create or replace function dg_money(p_players uuid[]) returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'pay', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'player', p.player_id, 'amt', p.amount, 'd', p.paid_on, 'method', p.method, 'note', p.note, 'kind', p.kind) order by p.paid_on desc, p.at desc)
                     from dg_payments p where p.player_id = any(p_players)), '[]'::jsonb),
    'plans', coalesce((select jsonb_agg(jsonb_build_object('player', l.player_id, 'freq', l.freq, 'start', l.start_on, 'n', l.n, 'base', l.base))
                     from dg_plans l where l.player_id = any(p_players)), '[]'::jsonb));
$$;
revoke execute on function dg_money(uuid[]) from public, anon, authenticated;

-- a payment plan starts from what's already paid in dues (not fundraising)
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
      if it->>'kind' in ('plog','pain','cheer') then
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

-- coach records dues or fundraising for a player
create or replace function dz_money_add(p_tok text, p_player uuid, p_kind text, p_amt numeric, p_d date, p_method text, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; i uuid;
begin
  a := dg_coach(p_tok);
  if p_kind not in ('dues','fund') then raise exception 'bad_kind'; end if;
  if p_amt is null or p_amt <= 0 or p_amt > 100000 then raise exception 'bad_amount'; end if;
  if not exists (select 1 from dg_players where id = p_player) then raise exception 'no_player'; end if;
  insert into dg_payments(player_id, amount, paid_on, method, note, by_id, kind)
    values (p_player, round(p_amt, 2), coalesce(p_d, current_date), left(coalesce(nullif(p_method, ''), 'Venmo'), 20), left(coalesce(p_note, ''), 120), a.id, p_kind)
    returning id into i;
  return jsonb_build_object('ok', true, 'id', i);
end $$;

-- ---------- money that isn't matched to a player yet (coach only) ----------
create table if not exists dg_unmatched (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references dg_orgs(id) on delete cascade,
  payer text not null,
  kind text not null check (kind in ('dues','fund')),
  amount numeric(10,2) not null check (amount > 0),
  paid_on date not null,
  method text not null default 'Venmo',
  note text not null default '',
  at timestamptz not null default now()
);
create index if not exists dg_unmatched_org on dg_unmatched(org_id);
alter table dg_unmatched enable row level security;
revoke all on dg_unmatched from public, anon, authenticated;

create or replace function dz_unmatched(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts;
begin
  a := dg_coach(p_tok);
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'payer', payer, 'kind', kind, 'amt', amount, 'd', paid_on, 'method', method, 'note', note) order by payer, paid_on)
    from dg_unmatched where org_id = dg_org()), '[]'::jsonb));
end $$;

-- move everything from one payer onto a player
create or replace function dz_unmatched_match(p_tok text, p_payer text, p_player uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; n int;
begin
  a := dg_coach(p_tok);
  if not exists (select 1 from dg_players where id = p_player) then raise exception 'no_player'; end if;
  insert into dg_payments(player_id, amount, paid_on, method, note, by_id, kind)
    select p_player, amount, paid_on, method, case when note = '' then 'From ' || payer else note end, a.id, kind
    from dg_unmatched where org_id = dg_org() and payer = p_payer;
  get diagnostics n = row_count;
  delete from dg_unmatched where org_id = dg_org() and payer = p_payer;
  return jsonb_build_object('ok', true, 'moved', n);
end $$;

create or replace function dz_unmatched_del(p_tok text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts;
begin
  a := dg_coach(p_tok);
  delete from dg_unmatched where id = p_id and org_id = dg_org();
  return jsonb_build_object('ok', true);
end $$;

-- ---------- one-time import: BigDawgz Venmo tracker, Nov 19 2026 ----------
create table if not exists dg_imports (key text primary key, at timestamptz not null default now());
alter table dg_imports enable row level security;
revoke all on dg_imports from public, anon, authenticated;

do $$ declare o uuid; r record; pid uuid;
begin
  select id into o from dg_orgs where lower(replace(name, ' ', '')) like 'bigdawgz%' order by created_at limit 1;
  if o is null then return; end if;
  insert into dg_imports(key) values ('venmo-2026-11-19') on conflict do nothing;
  if not found then return; end if;
  for r in select * from (values
      ('Samantha Everitt', 'Blake Everitt',  'dues', 350,  '2026-11-17'), ('Samantha Everitt', 'Blake Everitt',  'fund', 190,  '2026-10-05'),
      ('Matt Satchell',    'Liam S',         'dues', 900,  '2026-10-27'),
      ('Melvin Moss',      'Mac Moss',       'dues', 350,  '2026-11-07'), ('Melvin Moss', 'Mac Moss', 'dues', 350, '2026-10-06'), ('Melvin Moss', 'Mac Moss', 'fund', 87, '2026-10-05'),
      ('Mark Wesley',      'Lucas Wesley',   'dues', 350,  '2026-11-06'), ('Mark Wesley', 'Lucas Wesley', 'dues', 350, '2026-10-03'),
      ('Mark Wesley',      'Lucas Wesley',   'fund', 50,   '2026-10-27'), ('Mark Wesley', 'Lucas Wesley', 'fund', 1950, '2026-10-03'),
      ('Korey Klann',      'BK',             'dues', 350,  '2026-10-11'),
      ('Chris Ballnik',    'Emmett Ballnik', 'dues', 350,  '2026-10-05'), ('Chris Ballnik', 'Emmett Ballnik', 'fund', 131, '2026-10-05'),
      ('Christina Hammond', '',              'dues', 350,  '2026-10-10'), ('Christina Hammond', '', 'fund', 60, '2026-10-10'), ('Christina Hammond', '', 'fund', 25, '2026-11-07'),
      ('Jeff Stanbury',    '',               'dues', 350,  '2026-10-12'), ('Jeff Stanbury', '', 'fund', 59, '2026-10-12'),
      ('Miguel Estrada',   '',               'dues', 350,  '2026-10-15'), ('Miguel Estrada', '', 'fund', 100, '2026-10-05')
    ) v(payer, player, kind, amt, d) loop
    select id into pid from dg_players_all where org_id = o and r.player <> '' and lower(name) = lower(r.player) limit 1;
    if pid is not null then
      insert into dg_payments_all(org_id, player_id, amount, paid_on, method, note, kind)
        values (o, pid, r.amt, r.d::date, 'Venmo', 'From ' || r.payer, r.kind);
    else
      insert into dg_unmatched(org_id, payer, kind, amount, paid_on, method)
        values (o, r.payer, r.kind, r.amt, r.d::date, 'Venmo');
    end if;
  end loop;
  -- team totals: $2,652 from families + $611 can drive cash; $3,012 moved to the bank for Cooperstown
  update dg_team_all set doc = doc || jsonb_build_object('fund', jsonb_build_object(
      'raised', 3263, 'goal', coalesce((doc->'fund'->>'goal')::numeric, 23000), 'spent', 3012,
      'team', jsonb_build_array(jsonb_build_object('d', '2026-11-19', 'a', 611, 'n', 'Cash from the can drive')),
      'out', jsonb_build_array(jsonb_build_object('d', '2026-11-02', 'a', 3012, 'n', 'Moved to the bank for Cooperstown')))),
    updated_at = now()
  where org_id = o;
end $$;

-- ---------- profiles: a parent and their kids on one phone ----------
create or replace function dz_profiles(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users;
begin
  u := dg_user(p_tok);
  return jsonb_build_object('me', jsonb_build_object('id', u.id, 'name', u.name, 'role', u.role, 'kid', u.kid),
    'kids', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'user', case when k.kid then split_part(k.email, '@', 1) else k.email end) order by k.name)
      from dg_users k where k.parent_id = u.id and k.consent_at is not null), '[]'::jsonb));
end $$;

-- open a kid's profile from the parent's sign-in (only kids the parent gave permission for)
create or replace function dz_profile_open(p_tok text, p_kid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u dg_users; k dg_users; t text;
begin
  u := dg_user(p_tok);
  select * into k from dg_users where id = p_kid and parent_id = u.id and consent_at is not null;
  if k.id is null then raise exception 'not_your_player'; end if;
  t := dg_new_session(k.id);
  if k.last_org is not null and exists (select 1 from dg_members m join dg_orgs o on o.id = m.org_id
       where m.org_id = k.last_org and m.account_id = k.id and m.status = 'active' and o.status = 'active') then
    update dg_sessions set org_id = k.last_org where token = t;
  end if;
  return jsonb_build_object('token', t, 'name', k.name);
end $$;

-- the parent's password, to get back to the parent's profile
create or replace function dz_pw_check(p_tok text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u dg_users;
begin
  u := dg_user(p_tok);
  if u.pw <> extensions.crypt(coalesce(p_pw, ''), u.pw) then raise exception 'bad_password'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- admin: test sign-up that deletes itself ----------
-- the test starts on the server's clock, so only accounts made after it can be deleted
create or replace function dz_test_start(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_users;
begin
  a := dg_admin(p_tok);
  return jsonb_build_object('since', now());
end $$;

create or replace function dz_test_end(p_tok text, p_test text, p_since timestamptz) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_users; t dg_users; n int := 0;
begin
  a := dg_admin(p_tok);
  select x.* into t from dg_sessions s join dg_users x on x.id = s.account_id where s.token = p_test;
  if t.id is null then return jsonb_build_object('ok', true, 'deleted', false); end if;
  -- only accounts made during this test, never an admin or the person running the test
  if t.is_admin or t.id = a.id or p_since is null or t.created_at < p_since then
    delete from dg_sessions where token = p_test;
    return jsonb_build_object('ok', true, 'deleted', false);
  end if;
  delete from dg_orgs where created_by = t.id or created_by in (select id from dg_users where parent_id = t.id);
  get diagnostics n = row_count;
  delete from dg_users where id = t.id;
  return jsonb_build_object('ok', true, 'deleted', true, 'teams', n);
end $$;

-- ---------- admin: the people behind each number on the overview ----------
create or replace function dz_sa_who(p_tok text, p_what text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_users; r jsonb;
begin
  a := dg_admin(p_tok);
  if p_what in ('orgs','active') then
    select jsonb_agg(jsonb_build_object('n', trim(o.name || ' ' || o.age), 's', coalesce(o.year::text, '') || case when o.status <> 'active' then ' · paused' else '' end
             || ' · ' || (select count(*) from dg_members m where m.org_id = o.id and m.status = 'active') || ' members') order by o.name)
      into r from dg_orgs o where p_what = 'orgs' or o.status = 'active';
  elsif p_what in ('users','new7','live7') then
    select jsonb_agg(jsonb_build_object('n', x.name, 's', case when x.kid then 'Kid account' else x.email end || ' · ' || x.role) order by x.created_at desc)
      into r from (select * from dg_users u where p_what = 'users'
                     or (p_what = 'new7' and u.created_at > now() - interval '7 days')
                     or (p_what = 'live7' and exists (select 1 from dg_sessions s where s.account_id = u.id and s.last_at > now() - interval '7 days'))
                   order by u.created_at desc limit 500) x;
  elsif p_what = 'players' then
    select jsonb_agg(jsonb_build_object('n', p.name, 's', trim(o.name || ' ' || o.age) || case when p.claimed_by is null then ' · no sign-in yet' else '' end) order by o.name, p.name)
      into r from dg_players_all p join dg_orgs o on o.id = p.org_id where not p.sample;
  elsif p_what = 'pending' then
    select jsonb_agg(jsonb_build_object('n', x.name, 's', m.role || ' · wants to join ' || trim(o.name || ' ' || o.age)) order by m.created_at)
      into r from dg_members m join dg_users x on x.id = m.account_id join dg_orgs o on o.id = m.org_id where m.status = 'pending';
  else
    raise exception 'bad_action';
  end if;
  return jsonb_build_object('rows', coalesce(r, '[]'::jsonb));
end $$;

grant execute on function dz_money_add(text,uuid,text,numeric,date,text,text), dz_unmatched(text), dz_unmatched_match(text,text,uuid),
  dz_unmatched_del(text,uuid), dz_profiles(text), dz_profile_open(text,uuid), dz_pw_check(text,text), dz_test_end(text,text,timestamptz), dz_test_start(text),
  dz_sa_who(text,text) to anon, authenticated;

do $$ declare r record; begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'dz\_%' or p.proname like 'dg\_%') and p.prokind = 'f' loop
    execute 'alter function ' || r.sig || ' set search_path = public, extensions';
  end loop;
end $$;

notify pgrst, 'reload schema';
