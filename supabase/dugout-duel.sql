-- =====================================================================
-- BigDawgz Dugout: "Head-to-Head" live duels (adds to dugout-backend.sql)
-- Two players play the same game at the same time on their own phones.
-- Both get the exact same questions / pitches (shared seed), see each
-- other's progress live, and the winner gets bonus XP.
--
-- HOW TO RUN: Supabase dashboard > SQL Editor > New query > paste all of
-- this > Run. Safe to run more than once.
-- Coaches can turn duels off for the whole team in the app.
-- =====================================================================

create table if not exists dg_duel (
  id uuid primary key default gen_random_uuid(),
  from_acct uuid not null references dg_accounts(id) on delete cascade,
  from_player uuid not null references dg_players(id) on delete cascade,
  to_player uuid not null references dg_players(id) on delete cascade,
  to_acct uuid references dg_accounts(id) on delete cascade,
  game text not null check (game ~ '^[a-z]{2,12}$'),
  lv int not null default 0 check (lv between 0 and 3),
  seed int not null,
  status text not null default 'invite' check (status in ('invite','live','done','declined','cancelled','expired')),
  start_at timestamptz,
  f_i int not null default 0, f_n int not null default 0, f_score int not null default 0, f_done boolean not null default false, f_at timestamptz,
  t_i int not null default 0, t_n int not null default 0, t_score int not null default 0, t_done boolean not null default false, t_at timestamptz,
  winner uuid,
  awarded boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists dg_duel_to on dg_duel(to_player, status);
create index if not exists dg_duel_from on dg_duel(from_acct, status);
alter table dg_duel enable row level security;
revoke all on dg_duel from anon, authenticated;

-- the signed-in account's own roster player (players only)
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

create or replace function dg_duels_off() returns boolean
language sql security definer set search_path = public as $$
  select coalesce((select (doc->>'duelsOff')::boolean from dg_team where id = 1), false);
$$;

-- tidy up: invites expire after 2 minutes, live games after 20
create or replace function dg_duel_sweep() returns void
language plpgsql security definer set search_path = public as $$
declare d dg_duel;
begin
  update dg_duel set status = 'expired' where status = 'invite' and created_at < now() - interval '2 minutes';
  for d in select * from dg_duel where status = 'live' and start_at < now() - interval '20 minutes' loop
    update dg_duel set f_done = true, t_done = true, f_at = coalesce(f_at, now()), t_at = coalesce(t_at, now()) where id = d.id;
    perform dg_duel_finish(d.id);
  end loop;
  delete from dg_duel where created_at < now() - interval '60 days';
end $$;

-- both finished: pick the winner (higher score, then faster finish) and pay out XP
create or replace function dg_duel_finish(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d dg_duel; w uuid; l uuid; fn text; tn text;
begin
  select * into d from dg_duel where id = p_id for update;
  if d.awarded or not (d.f_done and d.t_done) then return; end if;
  if d.f_score > d.t_score or (d.f_score = d.t_score and d.f_at < d.t_at - interval '1 second') then w := d.from_player; l := d.to_player;
  elsif d.t_score > d.f_score or (d.f_score = d.t_score and d.t_at < d.f_at - interval '1 second') then w := d.to_player; l := d.from_player;
  end if;
  select name into fn from dg_players where id = d.from_player;
  select name into tn from dg_players where id = d.to_player;
  if w is null then
    insert into dg_inbox(aid, player_id, item) values
      ('duel-' || d.id || '-f', d.from_player, jsonb_build_object('kind','coins','n',20,'t','Head-to-Head: tied with ' || tn,'at',current_date)),
      ('duel-' || d.id || '-t', d.to_player, jsonb_build_object('kind','coins','n',20,'t','Head-to-Head: tied with ' || fn,'at',current_date))
    on conflict (aid) do nothing;
  else
    insert into dg_inbox(aid, player_id, item) values
      ('duel-' || d.id || '-w', w, jsonb_build_object('kind','coins','n',30,'t','Head-to-Head win vs ' || case when w = d.from_player then tn else fn end || '!','at',current_date)),
      ('duel-' || d.id || '-l', l, jsonb_build_object('kind','coins','n',10,'t','Head-to-Head vs ' || case when l = d.from_player then tn else fn end || ': thanks for playing','at',current_date))
    on conflict (aid) do nothing;
  end if;
  update dg_duel set status = 'done', winner = w, awarded = true where id = d.id;
end $$;

-- teammates you can challenge (first name + number only), and who's on right now
create or replace function dz_duel_team(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl dg_players;
begin
  pl := dg_duel_me(p_tok);
  return jsonb_build_object('off', dg_duels_off(), 'me', pl.id,
    'team', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'num', p.num,
       'on', exists (select 1 from dg_sessions s where s.account_id = p.claimed_by and s.last_at > now() - interval '90 seconds'))
       order by p.num nulls last, p.name)
     from dg_players p where p.claimed_by is not null and p.id <> pl.id and not p.sample), '[]'::jsonb));
end $$;

create or replace function dz_duel_invite(p_tok text, p_to uuid, p_game text, p_lv int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl dg_players; tgt dg_players; gid uuid;
begin
  pl := dg_duel_me(p_tok);
  if dg_duels_off() then raise exception 'duels_off'; end if;
  select * into tgt from dg_players where id = p_to and claimed_by is not null;
  if tgt.id is null or tgt.id = pl.id then raise exception 'bad_player'; end if;
  if (select count(*) from dg_duel where from_player = pl.id and created_at > now() - interval '1 hour') >= 30 then raise exception 'slow_down'; end if;
  update dg_duel set status = 'cancelled' where from_player = pl.id and status = 'invite';
  insert into dg_duel(from_acct, from_player, to_player, game, lv, seed)
    values (pl.claimed_by, pl.id, tgt.id, p_game, greatest(0, least(3, coalesce(p_lv, 0))), floor(random() * 2000000000)::int)
    returning id into gid;
  return jsonb_build_object('id', gid);
end $$;

-- polled every few seconds: challenges waiting for me, my current duel, my recent results
create or replace function dz_duel_poll(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl dg_players;
begin
  pl := dg_duel_me(p_tok);
  perform dg_duel_sweep();
  return jsonb_build_object('off', dg_duels_off(),
    'inv', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'from', f.name, 'game', d.game, 'lv', d.lv, 'left_ms', greatest(0, 120000 - (extract(epoch from (now() - d.created_at)) * 1000)::int)) order by d.created_at desc)
       from dg_duel d join dg_players f on f.id = d.from_player where d.to_player = pl.id and d.status = 'invite'), '[]'::jsonb),
    'active', (select jsonb_build_object('id', d.id, 'status', d.status) from dg_duel d
       where (d.from_player = pl.id or d.to_player = pl.id) and (d.status = 'live' and not (case when d.from_player = pl.id then d.f_done else d.t_done end) or (d.status = 'invite' and d.from_player = pl.id))
       order by d.created_at desc limit 1),
    'recent', coalesce((select jsonb_agg(x order by x->>'at' desc) from (
       select jsonb_build_object('id', d.id, 'game', d.game, 'lv', d.lv, 'at', d.created_at,
         'opp', case when d.from_player = pl.id then t.name else f.name end, 'oppId', case when d.from_player = pl.id then d.to_player else d.from_player end,
         'mine', case when d.from_player = pl.id then d.f_score else d.t_score end,
         'theirs', case when d.from_player = pl.id then d.t_score else d.f_score end,
         'res', case when d.winner is null then 'tie' when d.winner = pl.id then 'win' else 'loss' end) x
       from dg_duel d join dg_players f on f.id = d.from_player join dg_players t on t.id = d.to_player
       where (d.from_player = pl.id or d.to_player = pl.id) and d.status = 'done' order by d.created_at desc limit 8) q), '[]'::jsonb),
    'record', (select jsonb_build_object('w', count(*) filter (where winner = pl.id), 'l', count(*) filter (where winner is not null and winner <> pl.id), 't', count(*) filter (where winner is null))
       from dg_duel where (from_player = pl.id or to_player = pl.id) and status = 'done'));
end $$;

create or replace function dz_duel_answer(p_tok text, p_id uuid, p_yes boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl dg_players; d dg_duel;
begin
  pl := dg_duel_me(p_tok);
  perform dg_duel_sweep();
  select * into d from dg_duel where id = p_id and to_player = pl.id for update;
  if d.id is null or d.status <> 'invite' then raise exception 'gone'; end if;
  if not p_yes then update dg_duel set status = 'declined' where id = d.id; return jsonb_build_object('ok', true); end if;
  if dg_duels_off() then raise exception 'duels_off'; end if;
  update dg_duel set status = 'live', to_acct = pl.claimed_by, start_at = now() + interval '4 seconds' where id = d.id;
  return jsonb_build_object('ok', true);
end $$;

-- each phone reports its progress about once a second and gets the other side back
create or replace function dz_duel_tick(p_tok text, p_id uuid, p_i int default null, p_n int default null, p_score int default null, p_done boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl dg_players; d dg_duel; mine boolean; on_name text;
begin
  pl := dg_duel_me(p_tok);
  select * into d from dg_duel where id = p_id and (from_player = pl.id or to_player = pl.id);
  if d.id is null then raise exception 'gone'; end if;
  mine := d.from_player = pl.id;
  if d.status = 'live' and p_i is not null and now() >= d.start_at then
    if mine and not d.f_done then
      update dg_duel set f_i = greatest(f_i, least(p_i, 500)), f_n = least(coalesce(p_n, f_n), 500), f_score = greatest(0, least(coalesce(p_score, f_score), 100000)),
        f_done = p_done, f_at = case when p_done then now() else null end where id = d.id;
    elsif not mine and not d.t_done then
      update dg_duel set t_i = greatest(t_i, least(p_i, 500)), t_n = least(coalesce(p_n, t_n), 500), t_score = greatest(0, least(coalesce(p_score, t_score), 100000)),
        t_done = p_done, t_at = case when p_done then now() else null end where id = d.id;
    end if;
    perform dg_duel_finish(d.id);
  end if;
  select * into d from dg_duel where id = p_id;
  select name into on_name from dg_players where id = case when mine then d.to_player else d.from_player end;
  return jsonb_build_object('id', d.id, 'game', d.game, 'lv', d.lv, 'seed', d.seed, 'status', d.status,
    'start_ms', case when d.start_at is null then null else (extract(epoch from (d.start_at - now())) * 1000)::int end,
    'left_ms', case when d.status = 'invite' then greatest(0, 120000 - (extract(epoch from (now() - d.created_at)) * 1000)::int) else null end,
    'me', jsonb_build_object('i', case when mine then d.f_i else d.t_i end, 'n', case when mine then d.f_n else d.t_n end, 'score', case when mine then d.f_score else d.t_score end, 'done', case when mine then d.f_done else d.t_done end),
    'them', jsonb_build_object('id', case when mine then d.to_player else d.from_player end, 'name', on_name, 'i', case when mine then d.t_i else d.f_i end, 'n', case when mine then d.t_n else d.f_n end, 'score', case when mine then d.t_score else d.f_score end, 'done', case when mine then d.t_done else d.f_done end),
    'res', case when d.status <> 'done' then null when d.winner is null then 'tie' when d.winner = pl.id then 'win' else 'loss' end);
end $$;

-- sender cancels an invite, or a player quits a live duel (counts as finished with the score so far)
create or replace function dz_duel_leave(p_tok text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl dg_players; d dg_duel;
begin
  pl := dg_duel_me(p_tok);
  select * into d from dg_duel where id = p_id and (from_player = pl.id or to_player = pl.id);
  if d.id is null then return jsonb_build_object('ok', true); end if;
  if d.status = 'invite' and d.from_player = pl.id then update dg_duel set status = 'cancelled' where id = d.id;
  elsif d.status = 'live' then
    if d.from_player = pl.id then update dg_duel set f_done = true, f_at = coalesce(f_at, now()) where id = d.id;
    else update dg_duel set t_done = true, t_at = coalesce(t_at, now()) where id = d.id; end if;
    perform dg_duel_finish(d.id);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- coach: recent duels across the team
create or replace function dz_duel_recent(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform dg_coach(p_tok);
  return coalesce((select jsonb_agg(x) from (
    select jsonb_build_object('a', f.name, 'b', t.name, 'game', d.game, 'lv', d.lv, 'as', d.f_score, 'bs', d.t_score, 'status', d.status,
      'w', case when d.winner = d.from_player then f.name when d.winner = d.to_player then t.name else null end, 'at', d.created_at) x
    from dg_duel d join dg_players f on f.id = d.from_player join dg_players t on t.id = d.to_player
    where d.status in ('live','done') order by d.created_at desc limit 30) q), '[]'::jsonb);
end $$;

revoke execute on function dg_duel_me(text), dg_duels_off(), dg_duel_sweep(), dg_duel_finish(uuid) from public, anon, authenticated;
grant execute on function dz_duel_team(text), dz_duel_invite(text,uuid,text,int), dz_duel_poll(text), dz_duel_answer(text,uuid,boolean),
  dz_duel_tick(text,uuid,int,int,int,boolean), dz_duel_leave(text,uuid), dz_duel_recent(text) to anon, authenticated;

notify pgrst, 'reload schema';
