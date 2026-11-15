-- =====================================================================
-- BigDawgz Dugout backend v3 (fresh start)
-- Email + password accounts (no email verification), roster players
-- that players claim, parent links approved by a coach, private family
-- payments and payment plans.
--
-- HOW TO RUN: Supabase dashboard > SQL Editor > New query > paste all of
-- this > Run. Then sign up in the app as Coach FIRST: the first coach
-- account is approved automatically, every coach after that waits for you.
--
-- This replaces the old dz_* functions. Old tables are left alone (they
-- are not used anymore); delete them later if you want.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- Remove every old dz_* function (any signature) so the app only sees the new ones.
do $$ declare r record; begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'dz\_%' or p.proname like 'dg\_%') loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;
end $$;

-- ---------- tables ----------
create table if not exists dg_accounts (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  pw text not null,
  name text not null default '',
  role text not null check (role in ('player','parent','coach')),
  status text not null default 'active' check (status in ('active','pending')),
  created_at timestamptz not null default now()
);
create table if not exists dg_sessions (
  token text primary key,
  account_id uuid not null references dg_accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  last_at timestamptz not null default now()
);
create table if not exists dg_players (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  num int,
  pos text not null default '',
  doc jsonb,
  claimed_by uuid unique references dg_accounts(id) on delete set null,
  sample boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists dg_links (
  parent_id uuid not null references dg_accounts(id) on delete cascade,
  player_id uuid not null references dg_players(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','active')),
  created_at timestamptz not null default now(),
  primary key (parent_id, player_id)
);
create table if not exists dg_inbox (
  aid text primary key,
  player_id uuid not null references dg_players(id) on delete cascade,
  item jsonb not null,
  at timestamptz not null default now()
);
create table if not exists dg_team (
  id int primary key default 1 check (id = 1),
  doc jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
insert into dg_team (id) values (1) on conflict do nothing;
create table if not exists dg_payments (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references dg_players(id) on delete cascade,
  amount numeric(10,2) not null check (amount > 0),
  paid_on date not null default current_date,
  method text not null default 'Venmo',
  note text not null default '',
  by_id uuid,
  at timestamptz not null default now()
);
create table if not exists dg_plans (
  player_id uuid primary key references dg_players(id) on delete cascade,
  freq text not null check (freq in ('weekly','biweekly','semimonthly','monthly','once','none')),
  start_on date,
  n int check (n is null or (n between 1 and 52)),
  base numeric(10,2) not null default 0,
  set_by uuid,
  set_at timestamptz not null default now()
);
create index if not exists dg_inbox_player on dg_inbox(player_id);
create index if not exists dg_pay_player on dg_payments(player_id);
create index if not exists dg_sessions_acct on dg_sessions(account_id);

-- Lock every table: the app can only reach data through the functions below.
alter table dg_accounts enable row level security;
alter table dg_sessions enable row level security;
alter table dg_players  enable row level security;
alter table dg_links    enable row level security;
alter table dg_inbox    enable row level security;
alter table dg_team     enable row level security;
alter table dg_payments enable row level security;
alter table dg_plans    enable row level security;
revoke all on dg_accounts, dg_sessions, dg_players, dg_links, dg_inbox, dg_team, dg_payments, dg_plans from anon, authenticated;

-- ---------- sample roster (only if the roster is empty) ----------
do $$ declare i int; pid uuid;
  nums int[] := array[7,12,3,21,9,2,15,24,8,11,5,19];
  poss text[] := array['P / SS','C','1B','2B','3B / P','SS','LF','CF / P','RF','P / 1B','2B / OF','C / 3B'];
begin
  if not exists (select 1 from dg_players) then
    for i in 1..12 loop
      insert into dg_players(name, num, pos, sample) values ('Player ' || i, nums[i], poss[i], true) returning id into pid;
      -- sample payments and plans so the screens have something to show
      if i = 1 then
        insert into dg_payments(player_id, amount, paid_on, method) values (pid, 3000, current_date - 40, 'Venmo');
      elsif i = 2 then
        insert into dg_payments(player_id, amount, paid_on, method) values (pid, 750, current_date - 35, 'Venmo'), (pid, 750, current_date - 5, 'Check');
        insert into dg_plans(player_id, freq, start_on, n, base) values (pid, 'monthly', current_date - 35, 4, 0);
      elsif i = 3 then
        insert into dg_payments(player_id, amount, paid_on, method) values (pid, 375, current_date - 42, 'Venmo'), (pid, 375, current_date - 28, 'Venmo'), (pid, 375, current_date - 14, 'Venmo');
        insert into dg_plans(player_id, freq, start_on, n, base) values (pid, 'biweekly', current_date - 42, 8, 0);
      elsif i = 5 then
        insert into dg_payments(player_id, amount, paid_on, method) values (pid, 200, current_date - 20, 'Cash');
        insert into dg_plans(player_id, freq, start_on, n, base) values (pid, 'weekly', current_date - 21, 14, 0);
      elsif i = 7 then
        insert into dg_payments(player_id, amount, paid_on, method) values (pid, 250, current_date - 18, 'Cash'), (pid, 100, current_date - 3, 'Venmo');
        insert into dg_plans(player_id, freq, base) values (pid, 'none', 0);
      end if;
    end loop;
  end if;
end $$;

-- ---------- helpers (not callable from the app) ----------
create or replace function dg_me(p_tok text) returns dg_accounts
language plpgsql security definer set search_path = public as $$
declare a dg_accounts;
begin
  select acc.* into a from dg_sessions s join dg_accounts acc on acc.id = s.account_id where s.token = p_tok;
  if a.id is null then raise exception 'signed_out'; end if;
  update dg_sessions set last_at = now() where token = p_tok;
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

create or replace function dg_new_session(p_acct uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare t text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  insert into dg_sessions(token, account_id) values (t, p_acct);
  delete from dg_sessions where account_id = p_acct and last_at < now() - interval '120 days';
  return t;
end $$;

create or replace function dg_inbox_of(p_player uuid) returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(i.item || jsonb_build_object('aid', i.aid) order by i.at), '[]'::jsonb)
  from dg_inbox i where i.player_id = p_player;
$$;

create or replace function dg_money(p_players uuid[]) returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'pay', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'player', p.player_id, 'amt', p.amount, 'd', p.paid_on, 'method', p.method, 'note', p.note) order by p.paid_on desc, p.at desc)
                     from dg_payments p where p.player_id = any(p_players)), '[]'::jsonb),
    'plans', coalesce((select jsonb_agg(jsonb_build_object('player', l.player_id, 'freq', l.freq, 'start', l.start_on, 'n', l.n, 'base', l.base))
                     from dg_plans l where l.player_id = any(p_players)), '[]'::jsonb));
$$;

revoke execute on function dg_me(text), dg_coach(text), dg_new_session(uuid), dg_inbox_of(uuid), dg_money(uuid[]) from public, anon, authenticated;

-- ---------- sign up / sign in ----------
create or replace function dz_signup(p_email text, p_pw text, p_name text, p_role text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare e text := lower(trim(coalesce(p_email, ''))); nm text := trim(coalesce(p_name, '')); st text := 'active'; aid uuid;
begin
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'bad_email'; end if;
  if length(coalesce(p_pw, '')) < 6 then raise exception 'short_password'; end if;
  if nm = '' then raise exception 'need_name'; end if;
  if p_role not in ('player','parent','coach') then raise exception 'bad_role'; end if;
  if exists (select 1 from dg_accounts where email = e) then raise exception 'taken'; end if;
  if p_role = 'coach' and exists (select 1 from dg_accounts where role = 'coach' and status = 'active') then st := 'pending'; end if;
  insert into dg_accounts(email, pw, name, role, status)
    values (e, extensions.crypt(p_pw, extensions.gen_salt('bf')), left(nm, 40), p_role, st) returning id into aid;
  return jsonb_build_object('token', dg_new_session(aid));
end $$;

create or replace function dz_login(p_email text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare a dg_accounts;
begin
  select * into a from dg_accounts where email = lower(trim(coalesce(p_email, '')));
  if a.id is null or a.pw <> extensions.crypt(coalesce(p_pw, ''), a.pw) then raise exception 'bad_login'; end if;
  return jsonb_build_object('token', dg_new_session(a.id));
end $$;

create or replace function dz_logout(p_tok text) returns jsonb
language sql security definer set search_path = public as $$
  delete from dg_sessions where token = p_tok returning jsonb_build_object('ok', true);
$$;

-- ---------- everything the signed-in person is allowed to see ----------
create or replace function dz_sync(p_tok text, p_doc jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; me jsonb; pl dg_players; kids uuid[]; team jsonb;
begin
  a := dg_me(p_tok);
  me := jsonb_build_object('id', a.id, 'email', a.email, 'name', a.name, 'role', a.role, 'status', a.status);
  if a.status = 'pending' then return jsonb_build_object('user', me); end if;
  select doc into team from dg_team where id = 1;

  if a.role = 'player' then
    select * into pl from dg_players where claimed_by = a.id;
    if pl.id is null then
      return jsonb_build_object('user', me, 'team', team,
        'roster', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'num', p.num, 'taken', p.claimed_by is not null) order by p.num nulls last, p.name) from dg_players p), '[]'::jsonb));
    end if;
    if p_doc is not null then update dg_players set doc = p_doc where id = pl.id; pl.doc := p_doc; end if;
    return jsonb_build_object('user', me, 'team', team,
      'player', jsonb_build_object('id', pl.id, 'name', pl.name, 'num', pl.num, 'pos', pl.pos),
      'doc', pl.doc, 'inbox', dg_inbox_of(pl.id),
      'parents', coalesce((select jsonb_agg(x.name) from dg_links l join dg_accounts x on x.id = l.parent_id where l.player_id = pl.id and l.status = 'active'), '[]'::jsonb));
  end if;

  if a.role = 'parent' then
    select coalesce(array_agg(player_id), '{}') into kids from dg_links where parent_id = a.id and status = 'active';
    return jsonb_build_object('user', me, 'team', team,
      'kids', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'num', p.num, 'pos', p.pos, 'doc', p.doc, 'inbox', dg_inbox_of(p.id)) order by p.num) from dg_players p where p.id = any(kids)), '[]'::jsonb),
      'waiting', coalesce((select jsonb_agg(p.name) from dg_links l join dg_players p on p.id = l.player_id where l.parent_id = a.id and l.status = 'pending'), '[]'::jsonb),
      'roster', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'num', p.num) order by p.num nulls last, p.name) from dg_players p), '[]'::jsonb),
      'money', dg_money(kids));
  end if;

  -- coach: everything
  return jsonb_build_object('user', me, 'team', team,
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'email', x.email, 'name', x.name, 'role', x.role, 'status', x.status, 'at', x.created_at) order by x.role, x.name) from dg_accounts x), '[]'::jsonb),
    'players', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'num', p.num, 'pos', p.pos, 'doc', p.doc, 'inbox', dg_inbox_of(p.id), 'claimed_by', p.claimed_by, 'sample', p.sample) order by p.num nulls last, p.name) from dg_players p), '[]'::jsonb),
    'links', coalesce((select jsonb_agg(jsonb_build_object('parent', l.parent_id, 'kid', l.player_id, 'status', l.status)) from dg_links l), '[]'::jsonb),
    'money', dg_money(array(select id from dg_players)));
end $$;

-- ---------- a player picks their name from the roster ----------
create or replace function dz_claim(p_tok text, p_player uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; cur uuid;
begin
  a := dg_me(p_tok);
  if a.role <> 'player' then raise exception 'bad_role'; end if;
  select id into cur from dg_players where claimed_by = a.id;
  if cur is not null then raise exception 'already_claimed'; end if;
  update dg_players set claimed_by = a.id where id = p_player and claimed_by is null;
  if not found then raise exception 'claimed'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- coach sends homework / shout-outs / pitch logs ----------
create or replace function dz_push(p_tok text, p_uids uuid[], p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; u uuid; it jsonb;
begin
  a := dg_coach(p_tok);
  foreach u in array p_uids loop
    for it in select * from jsonb_array_elements(p_items) loop
      insert into dg_inbox(aid, player_id, item) values (coalesce(it->>'aid', gen_random_uuid()::text), u, it - 'aid') on conflict (aid) do nothing;
    end loop;
  end loop;
  return jsonb_build_object('ok', true);
end $$;

create or replace function dz_team_save(p_tok text, p_team jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform dg_coach(p_tok);
  update dg_team set doc = coalesce(p_team, '{}'::jsonb), updated_at = now() where id = 1;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- parents ----------
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
              coalesce((select sum(amount) from dg_payments where player_id = p_kid), 0), a.id, now())
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

-- ---------- coach admin: masterfile, payments, roles ----------
create or replace function dz_admin(p_tok text, p_action text, p_uid uuid default null, p_val jsonb default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare a dg_accounts; v text := p_val #>> '{}'; t dg_accounts; amt numeric; pid uuid;
begin
  a := dg_coach(p_tok);

  if p_action = 'role' then
    if v not in ('player','parent','coach') then raise exception 'bad_role'; end if;
    select * into t from dg_accounts where id = p_uid;
    if t.role = 'coach' and v <> 'coach' and (select count(*) from dg_accounts where role = 'coach' and status = 'active') <= 1 then raise exception 'last_coach'; end if;
    if v <> 'player' then update dg_players set claimed_by = null where claimed_by = p_uid; end if;
    if v <> 'parent' then delete from dg_links where parent_id = p_uid; end if;
    update dg_accounts set role = v where id = p_uid;
  elsif p_action = 'approve' then
    update dg_accounts set status = 'active' where id = p_uid;
  elsif p_action = 'pw' then
    if length(coalesce(v, '')) < 6 then raise exception 'short_password'; end if;
    update dg_accounts set pw = extensions.crypt(v, extensions.gen_salt('bf')) where id = p_uid;
    delete from dg_sessions where account_id = p_uid;
  elsif p_action = 'remove' then
    if p_uid = a.id then raise exception 'not_yourself'; end if;
    delete from dg_accounts where id = p_uid;
  elsif p_action in ('link','linkok') then
    insert into dg_links(parent_id, player_id, status) values (p_uid, v::uuid, 'active')
      on conflict (parent_id, player_id) do update set status = 'active';
  elsif p_action = 'unlink' then
    delete from dg_links where parent_id = p_uid and player_id = v::uuid;
  elsif p_action = 'unclaim' then
    update dg_players set claimed_by = null where id = p_uid;
  elsif p_action = 'claim' then
    select * into t from dg_accounts where id = v::uuid;
    if t.id is null or t.role <> 'player' then raise exception 'bad_role'; end if;
    update dg_players set claimed_by = null where claimed_by = t.id;
    update dg_players set claimed_by = t.id where id = p_uid;
  elsif p_action = 'player_add' then
    if trim(coalesce(p_val->>'name', '')) = '' then raise exception 'need_name'; end if;
    insert into dg_players(name, num, pos) values (left(trim(p_val->>'name'), 40), nullif(p_val->>'num', '')::int, left(coalesce(p_val->>'pos', ''), 20));
  elsif p_action = 'player_edit' then
    if trim(coalesce(p_val->>'name', '')) = '' then raise exception 'need_name'; end if;
    update dg_players set name = left(trim(p_val->>'name'), 40), num = nullif(p_val->>'num', '')::int, pos = left(coalesce(p_val->>'pos', ''), 20), sample = false where id = p_uid;
  elsif p_action = 'player_del' then
    delete from dg_players where id = p_uid;
  elsif p_action = 'clear_samples' then
    delete from dg_players where sample;
  elsif p_action = 'pay_add' then
    amt := (p_val->>'amt')::numeric;
    if amt is null or amt <= 0 or amt > 100000 then raise exception 'bad_amount'; end if;
    insert into dg_payments(player_id, amount, paid_on, method, note, by_id)
      values (p_uid, round(amt, 2), coalesce(nullif(p_val->>'d', '')::date, current_date), left(coalesce(nullif(p_val->>'method', ''), 'Venmo'), 20), left(coalesce(p_val->>'note', ''), 120), a.id);
  elsif p_action = 'pay_del' then
    delete from dg_payments where id = p_uid;
  elsif p_action = 'plan_clear' then
    delete from dg_plans where player_id = p_uid;
  else
    raise exception 'bad_action';
  end if;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function dz_signup(text,text,text,text), dz_login(text,text), dz_logout(text), dz_sync(text,jsonb),
  dz_claim(text,uuid), dz_push(text,uuid[],jsonb), dz_team_save(text,jsonb), dz_parent(text,text,uuid,jsonb), dz_admin(text,text,uuid,jsonb)
  to anon, authenticated;

notify pgrst, 'reload schema';
