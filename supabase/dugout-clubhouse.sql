-- =====================================================================
-- BigDawgz Dugout: Team Clubhouse. Card trades and send-a-score challenges.
-- Run once in the Supabase SQL Editor (after dugout-backend.sql and
-- dugout-duel.sql). Safe to run more than once.
--
-- Trades: a player offers 1-3 of his cards for 0-3 of a teammate's cards.
-- When the teammate accepts, both players get an inbox note that moves the
-- cards on their next sync (same way homework reaches them).
-- Challenges: play a game, send your score. The teammate plays the exact
-- same questions (shared seed) and tries to beat it. Winner +30 XP,
-- tie +20 each, +10 for losing.
-- =====================================================================

create table if not exists dg_trades (
  id uuid primary key default gen_random_uuid(),
  from_player uuid not null references dg_players(id) on delete cascade,
  to_player uuid not null references dg_players(id) on delete cascade,
  give jsonb not null default '[]'::jsonb,
  want jsonb not null default '[]'::jsonb,
  status text not null default 'open' check (status in ('open','done','declined','cancelled')),
  note text not null default '',
  created_at timestamptz not null default now(),
  done_at timestamptz
);
create index if not exists dg_trades_to on dg_trades(to_player, status);
create index if not exists dg_trades_from on dg_trades(from_player, status);

create table if not exists dg_chal (
  id uuid primary key default gen_random_uuid(),
  from_player uuid not null references dg_players(id) on delete cascade,
  to_player uuid not null references dg_players(id) on delete cascade,
  game text not null check (game ~ '^[a-z]{2,12}$'),
  lv int not null default 0 check (lv between 0 and 3),
  seed bigint not null,
  f_score int not null default 0,
  t_score int,
  status text not null default 'open' check (status in ('open','done','declined')),
  created_at timestamptz not null default now(),
  done_at timestamptz
);
create index if not exists dg_chal_to on dg_chal(to_player, status);
create index if not exists dg_chal_from on dg_chal(from_player, status);

alter table dg_trades enable row level security;
alter table dg_chal enable row level security;
revoke all on dg_trades, dg_chal from anon, authenticated;

-- does this player's saved file hold every one of these cards (by u)?
create or replace function dg_owns(p_player uuid, p_cards jsonb) returns boolean
language sql security definer set search_path = public as $$
  select coalesce(bool_and(exists (
    select 1 from dg_players p, jsonb_array_elements(coalesce(p.doc->'cards','[]'::jsonb)) c
    where p.id = p_player and c->>'u' = x->>'u')), true)
  from jsonb_array_elements(p_cards) x;
$$;

-- everything the Clubhouse needs in one call
create or replace function dz_club(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; me uuid;
begin
  a := dg_me(p_tok);
  if a.status <> 'active' then raise exception 'signed_out'; end if;
  select id into me from dg_players where claimed_by = a.id;
  if a.role = 'player' and me is null then raise exception 'not_claimed'; end if;
  return jsonb_build_object(
    'me', me,
    'team', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'num', p.num, 'n', jsonb_array_length(coalesce(p.doc->'cards','[]'::jsonb))) order by p.name)
       from dg_players p where p.claimed_by is not null and not p.sample), '[]'::jsonb),
    'trades', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'from', t.from_player, 'to', t.to_player, 'fn', f.name, 'tn', o.name, 'give', t.give, 'want', t.want, 'status', t.status, 'note', t.note, 'at', t.created_at, 'done', t.done_at) order by t.created_at desc)
       from (select * from dg_trades t where (a.role = 'coach' or me in (t.from_player, t.to_player)) and (t.status = 'open' or t.created_at > now() - interval '14 days') order by t.created_at desc limit 60) t
       join dg_players f on f.id = t.from_player join dg_players o on o.id = t.to_player), '[]'::jsonb),
    'chals', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'from', c.from_player, 'to', c.to_player, 'fn', f.name, 'tn', o.name, 'game', c.game, 'lv', c.lv, 'seed', c.seed, 'fs', c.f_score, 'ts', c.t_score, 'status', c.status, 'at', c.created_at) order by c.created_at desc)
       from (select * from dg_chal c where (a.role = 'coach' or me in (c.from_player, c.to_player)) and (c.status = 'open' and c.created_at > now() - interval '7 days' or c.created_at > now() - interval '14 days') order by c.created_at desc limit 80) c
       join dg_players f on f.id = c.from_player join dg_players o on o.id = c.to_player), '[]'::jsonb));
end $$;

-- a teammate's cards, to pick what you want in a trade
create or replace function dz_club_cards(p_tok text, p_player uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts;
begin
  a := dg_me(p_tok);
  if a.status <> 'active' then raise exception 'signed_out'; end if;
  return jsonb_build_object('cards', coalesce((select doc->'cards' from dg_players where id = p_player), '[]'::jsonb));
end $$;

create or replace function dz_trade_offer(p_tok text, p_to uuid, p_give jsonb, p_want jsonb, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl dg_players; tid uuid;
begin
  pl := dg_duel_me(p_tok);
  if p_to = pl.id or not exists (select 1 from dg_players where id = p_to and claimed_by is not null) then raise exception 'bad_player'; end if;
  if jsonb_typeof(p_give) <> 'array' or jsonb_typeof(p_want) <> 'array' then raise exception 'bad_trade'; end if;
  if jsonb_array_length(p_give) < 1 or jsonb_array_length(p_give) > 3 or jsonb_array_length(p_want) > 3 then raise exception 'bad_trade'; end if;
  if (select count(*) from dg_trades where from_player = pl.id and status = 'open') >= 5 then raise exception 'too_many_trades'; end if;
  if not dg_owns(pl.id, p_give) then raise exception 'not_yours'; end if;
  if not dg_owns(p_to, p_want) then raise exception 'not_theirs'; end if;
  insert into dg_trades(from_player, to_player, give, want, note) values (pl.id, p_to, p_give, p_want, left(coalesce(p_note, ''), 80)) returning id into tid;
  return jsonb_build_object('ok', true, 'id', tid);
end $$;

create or replace function dz_trade_act(p_tok text, p_id uuid, p_act text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl dg_players; t dg_trades; fname text; tname text; us text[];
begin
  pl := dg_duel_me(p_tok);
  select * into t from dg_trades where id = p_id for update;
  if t.id is null or t.status <> 'open' then raise exception 'gone'; end if;
  if p_act = 'cancel' then
    if t.from_player <> pl.id then raise exception 'bad_player'; end if;
    update dg_trades set status = 'cancelled', done_at = now() where id = t.id;
  elsif p_act = 'decline' then
    if t.to_player <> pl.id then raise exception 'bad_player'; end if;
    update dg_trades set status = 'declined', done_at = now() where id = t.id;
  elsif p_act = 'accept' then
    if t.to_player <> pl.id then raise exception 'bad_player'; end if;
    if not dg_owns(t.from_player, t.give) or not dg_owns(t.to_player, t.want) then
      update dg_trades set status = 'cancelled', done_at = now() where id = t.id;
      raise exception 'cards_moved';
    end if;
    select name into fname from dg_players where id = t.from_player;
    select name into tname from dg_players where id = t.to_player;
    insert into dg_inbox(aid, player_id, item) values
      ('trade-' || t.id || '-f', t.from_player, jsonb_build_object('kind', 'trade', 'out', t.give, 'in', t.want, 'with', tname, 'at', current_date)),
      ('trade-' || t.id || '-t', t.to_player, jsonb_build_object('kind', 'trade', 'out', t.want, 'in', t.give, 'with', fname, 'at', current_date))
      on conflict (aid) do nothing;
    update dg_trades set status = 'done', done_at = now() where id = t.id;
    -- any other open offer that uses one of these cards can't happen now
    select array_agg(x->>'u') into us from jsonb_array_elements(t.give || t.want) x;
    update dg_trades o set status = 'cancelled', done_at = now()
      where o.status = 'open' and o.id <> t.id
        and exists (select 1 from jsonb_array_elements(o.give || o.want) y where y->>'u' = any(us));
  else
    raise exception 'bad_trade';
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function dz_chal_send(p_tok text, p_to uuid[], p_game text, p_lv int, p_seed bigint, p_score int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl dg_players; u uuid; n int := 0;
begin
  pl := dg_duel_me(p_tok);
  if p_to is null or array_length(p_to, 1) is null or array_length(p_to, 1) > 12 then raise exception 'bad_player'; end if;
  if (select count(*) from dg_chal where from_player = pl.id and created_at > now() - interval '1 day') > 60 then raise exception 'slow_down'; end if;
  foreach u in array p_to loop
    if u <> pl.id and exists (select 1 from dg_players where id = u and claimed_by is not null) then
      insert into dg_chal(from_player, to_player, game, lv, seed, f_score) values (pl.id, u, p_game, greatest(0, least(3, p_lv)), p_seed, greatest(0, least(100000, p_score)));
      n := n + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'sent', n);
end $$;

create or replace function dz_chal_play(p_tok text, p_id uuid, p_score int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl dg_players; c dg_chal; fname text; tname text; res text; s int := greatest(0, least(100000, p_score));
begin
  pl := dg_duel_me(p_tok);
  select * into c from dg_chal where id = p_id for update;
  if c.id is null or c.to_player <> pl.id then raise exception 'gone'; end if;
  if c.status <> 'open' then raise exception 'gone'; end if;
  update dg_chal set t_score = s, status = 'done', done_at = now() where id = c.id;
  select name into fname from dg_players where id = c.from_player;
  select name into tname from dg_players where id = c.to_player;
  res := case when s > c.f_score then 'win' when s < c.f_score then 'loss' else 'tie' end;
  insert into dg_inbox(aid, player_id, item) values
    ('chal-' || c.id || '-t', c.to_player, jsonb_build_object('kind', 'coins', 'n', case res when 'win' then 30 when 'tie' then 20 else 10 end, 't', case res when 'win' then 'Beat ' || fname || '''s challenge' when 'tie' then 'Tied ' || fname || '''s challenge' else 'Played ' || fname || '''s challenge' end, 'at', current_date)),
    ('chal-' || c.id || '-f', c.from_player, jsonb_build_object('kind', 'coins', 'n', case res when 'loss' then 30 when 'tie' then 20 else 10 end, 't', case res when 'loss' then tname || ' couldn''t beat your challenge' when 'tie' then 'Tied with ' || tname else tname || ' beat your challenge' end, 'at', current_date))
    on conflict (aid) do nothing;
  return jsonb_build_object('ok', true, 'res', res, 'theirs', c.f_score);
end $$;

create or replace function dz_chal_decline(p_tok text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl dg_players;
begin
  pl := dg_duel_me(p_tok);
  update dg_chal set status = 'declined', done_at = now() where id = p_id and to_player = pl.id and status = 'open';
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function dg_owns(uuid, jsonb) from public, anon, authenticated;
grant execute on function dz_club(text), dz_club_cards(text, uuid), dz_trade_offer(text, uuid, jsonb, jsonb, text), dz_trade_act(text, uuid, text),
  dz_chal_send(text, uuid[], text, int, bigint, int), dz_chal_play(text, uuid, int), dz_chal_decline(text, uuid) to anon, authenticated;
