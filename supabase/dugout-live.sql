-- =====================================================================
-- BigDawgz Dugout: "Dugout Live" team trivia (adds to dugout-backend.sql)
-- Coach hosts on one screen, players join on their own phones with a PIN.
-- Safe to run more than once.
-- =====================================================================

create table if not exists dg_live (
  id uuid primary key default gen_random_uuid(),
  pin text not null,
  host uuid not null references dg_accounts(id) on delete cascade,
  qs jsonb not null,
  secs int not null default 20 check (secs between 5 and 60),
  idx int not null default -1,
  phase text not null default 'lobby' check (phase in ('lobby','question','reveal','board','done')),
  q_at timestamptz,
  awarded boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists dg_live_p (
  live uuid not null references dg_live(id) on delete cascade,
  acct uuid not null references dg_accounts(id) on delete cascade,
  name text not null,
  player uuid,
  score int not null default 0,
  streak int not null default 0,
  prev_rank int,
  joined_at timestamptz not null default now(),
  primary key (live, acct)
);
create table if not exists dg_live_a (
  live uuid not null references dg_live(id) on delete cascade,
  acct uuid not null,
  qi int not null,
  choice int not null,
  ms int not null,
  correct boolean not null,
  pts int not null,
  primary key (live, acct, qi)
);
create index if not exists dg_live_pin on dg_live(pin);
alter table dg_live enable row level security;
alter table dg_live_p enable row level security;
alter table dg_live_a enable row level security;
revoke all on dg_live, dg_live_p, dg_live_a from anon, authenticated;

-- coach starts a game
create or replace function dz_live_host(p_tok text, p_qs jsonb, p_secs int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; pn text; gid uuid;
begin
  a := dg_coach(p_tok);
  if jsonb_typeof(p_qs) <> 'array' or jsonb_array_length(p_qs) < 1 or jsonb_array_length(p_qs) > 30 then raise exception 'bad_quiz'; end if;
  update dg_live set phase = 'done' where host = a.id and phase <> 'done';
  delete from dg_live where created_at < now() - interval '7 days';
  loop
    pn := lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');
    exit when not exists (select 1 from dg_live where pin = pn and phase <> 'done');
  end loop;
  insert into dg_live(pin, host, qs, secs) values (pn, a.id, p_qs, greatest(5, least(60, coalesce(p_secs, 20)))) returning id into gid;
  return jsonb_build_object('pin', pn);
end $$;

-- is coach live right now? (so players can tap Join without typing a PIN)
create or replace function dz_live_find(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g dg_live;
begin
  perform dg_me(p_tok);
  select * into g from dg_live where phase <> 'done' and created_at > now() - interval '3 hours' order by created_at desc limit 1;
  if g.id is null then return jsonb_build_object('pin', null); end if;
  return jsonb_build_object('pin', g.pin, 'phase', g.phase);
end $$;

create or replace function dz_live_join(p_tok text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; g dg_live; pl dg_players;
begin
  a := dg_me(p_tok);
  if a.status <> 'active' then raise exception 'not_active'; end if;
  select * into g from dg_live where pin = trim(p_pin) and phase <> 'done' order by created_at desc limit 1;
  if g.id is null then raise exception 'no_game'; end if;
  select * into pl from dg_players where claimed_by = a.id;
  insert into dg_live_p(live, acct, name, player) values (g.id, a.id, coalesce(pl.name, a.name), pl.id) on conflict (live, acct) do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- end of game: coins for everyone who played, more for the podium
create or replace function dg_live_award(p_live uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r record; n int; lbl text;
begin
  if (select awarded from dg_live where id = p_live) then return; end if;
  for r in select acct, player, score, rank() over (order by score desc) rk from dg_live_p where live = p_live loop
    if r.player is null then continue; end if;
    n := case when r.score > 0 and r.rk = 1 then 150 when r.score > 0 and r.rk = 2 then 100 when r.score > 0 and r.rk = 3 then 75 else 25 end;
    lbl := case when r.score > 0 and r.rk <= 3 then 'Dugout Live: ' || (array['1st','2nd','3rd'])[r.rk] || ' place!' else 'Dugout Live: thanks for playing' end;
    insert into dg_inbox(aid, player_id, item) values ('live-' || p_live || '-' || r.acct, r.player, jsonb_build_object('kind', 'coins', 'n', n, 't', lbl, 'at', current_date)) on conflict (aid) do nothing;
  end loop;
  update dg_live set awarded = true where id = p_live;
end $$;
revoke execute on function dg_live_award(uuid) from public, anon, authenticated;

-- coach moves the game along: start / reveal / board / next / end
create or replace function dz_live_ctl(p_tok text, p_pin text, p_action text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; g dg_live;
begin
  a := dg_coach(p_tok);
  select * into g from dg_live where pin = p_pin and host = a.id and phase <> 'done' order by created_at desc limit 1;
  if g.id is null then raise exception 'no_game'; end if;
  if p_action in ('start','next') then
    -- remember ranks before this question so the board can show who moved up
    update dg_live_p p set prev_rank = x.rk from (select acct, rank() over (order by score desc) rk from dg_live_p where live = g.id) x where p.live = g.id and p.acct = x.acct;
    if g.idx + 1 >= jsonb_array_length(g.qs) then
      update dg_live set phase = 'done' where id = g.id; perform dg_live_award(g.id);
    else
      update dg_live set idx = g.idx + 1, phase = 'question', q_at = now() where id = g.id;
    end if;
  elsif p_action = 'reveal' and g.phase = 'question' then
    update dg_live set phase = 'reveal' where id = g.id;
  elsif p_action = 'board' then
    update dg_live set phase = 'board' where id = g.id;
  elsif p_action = 'end' then
    update dg_live set phase = 'done' where id = g.id; perform dg_live_award(g.id);
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function dz_live_answer(p_tok text, p_pin text, p_qi int, p_choice int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; g dg_live; me dg_live_p; el int; ok boolean; pts int := 0; st int;
begin
  a := dg_me(p_tok);
  select * into g from dg_live where pin = p_pin and phase <> 'done' order by created_at desc limit 1;
  if g.id is null then raise exception 'no_game'; end if;
  if g.phase <> 'question' or g.idx <> p_qi then raise exception 'too_late'; end if;
  select * into me from dg_live_p where live = g.id and acct = a.id;
  if me.acct is null then raise exception 'not_joined'; end if;
  el := (extract(epoch from (now() - g.q_at)) * 1000)::int;
  if el > g.secs * 1000 + 1500 then raise exception 'too_late'; end if;
  el := least(el, g.secs * 1000);
  ok := p_choice = (g.qs -> g.idx ->> 'a')::int;
  st := case when ok then me.streak + 1 else 0 end;
  if ok then pts := round(1000 * (1 - (el::numeric / (g.secs * 1000)) / 2))::int + least(greatest(st - 1, 0), 5) * 100; end if;
  insert into dg_live_a(live, acct, qi, choice, ms, correct, pts) values (g.id, a.id, p_qi, p_choice, el, ok, pts);
  update dg_live_p set score = score + pts, streak = st where live = g.id and acct = a.id;
  return jsonb_build_object('ok', true);
exception when unique_violation then raise exception 'already_answered';
end $$;

-- what everyone's screen should show right now (polled about once a second)
create or replace function dz_live_state(p_tok text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; g dg_live; host boolean; q jsonb; me dg_live_p; my dg_live_a; left_ms int; out jsonb; showans boolean;
begin
  a := dg_me(p_tok);
  select * into g from dg_live where pin = p_pin order by created_at desc limit 1;
  if g.id is null then raise exception 'no_game'; end if;
  host := g.host = a.id;
  q := case when g.idx >= 0 then g.qs -> g.idx else null end;
  showans := g.phase in ('reveal','board','done');
  left_ms := case when g.phase = 'question' then greatest(0, g.secs * 1000 - (extract(epoch from (now() - g.q_at)) * 1000)::int) else 0 end;
  out := jsonb_build_object('pin', g.pin, 'phase', g.phase, 'idx', g.idx, 'total', jsonb_array_length(g.qs), 'secs', g.secs, 'left_ms', left_ms, 'host', host,
    'q', case when q is null then null else jsonb_build_object('q', q->>'q', 'o', q->'o', 'cat', q->>'cat') end,
    'a', case when showans and q is not null then (q->>'a')::int else null end,
    'why', case when showans and q is not null then q->>'why' else null end,
    'count', (select count(*) from dg_live_p where live = g.id),
    'answered', (select count(*) from dg_live_a where live = g.id and qi = g.idx),
    'players', case when g.phase = 'lobby' or host then coalesce((select jsonb_agg(name order by joined_at) from dg_live_p where live = g.id), '[]'::jsonb) else '[]'::jsonb end,
    'dist', case when showans then (select jsonb_build_array(count(*) filter (where choice = 0), count(*) filter (where choice = 1), count(*) filter (where choice = 2), count(*) filter (where choice = 3)) from dg_live_a where live = g.id and qi = g.idx) else null end,
    'board', case when g.phase in ('board','done','reveal') then coalesce((select jsonb_agg(jsonb_build_object('name', x.name, 'score', x.score, 'rank', x.rk, 'up', coalesce(x.prev_rank - x.rk, 0)) order by x.score desc) from (select name, score, prev_rank, rank() over (order by score desc) rk from dg_live_p where live = g.id order by score desc limit 5) x), '[]'::jsonb) else null end);
  select * into me from dg_live_p where live = g.id and acct = a.id;
  if me.acct is not null then
    select * into my from dg_live_a where live = g.id and acct = a.id and qi = g.idx;
    out := out || jsonb_build_object('me', jsonb_build_object('name', me.name, 'score', me.score, 'streak', me.streak,
      'rank', (select count(*) + 1 from dg_live_p where live = g.id and score > me.score),
      'answered', my.acct is not null, 'choice', my.choice,
      'correct', case when showans then my.correct else null end, 'pts', case when showans then my.pts else null end));
  end if;
  return out;
end $$;

grant execute on function dz_live_host(text,jsonb,int), dz_live_find(text), dz_live_join(text,text), dz_live_ctl(text,text,text),
  dz_live_answer(text,text,int,int), dz_live_state(text,text) to anon, authenticated;

notify pgrst, 'reload schema';
