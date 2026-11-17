-- =====================================================================
-- BigDawgz Dugout: players can make their own profile
-- Run once in the Supabase SQL Editor (after dugout-backend.sql).
-- A signed-in player who isn't on the roster yet types their name,
-- number and position. That adds them to the roster, already matched
-- to their account. Coach can edit or remove them from the Roster.
-- =====================================================================

create or replace function dz_selfadd(p_tok text, p_name text, p_num text default '', p_pos text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts; cur uuid; nm text := left(trim(coalesce(p_name, '')), 40); n int;
begin
  a := dg_me(p_tok);
  if a.role <> 'player' or a.status <> 'active' then raise exception 'bad_role'; end if;
  select id into cur from dg_players where claimed_by = a.id;
  if cur is not null then raise exception 'already_claimed'; end if;
  if nm = '' then raise exception 'need_name'; end if;
  if trim(coalesce(p_num, '')) <> '' then
    if trim(p_num) !~ '^[0-9]{1,2}$' then raise exception 'bad_num'; end if;
    n := trim(p_num)::int;
  end if;
  -- their name is already on the roster and nobody has it: pick that one instead
  if exists (select 1 from dg_players where lower(name) = lower(nm) and claimed_by is null) then
    raise exception 'on_roster';
  end if;
  insert into dg_players(name, num, pos, claimed_by) values (nm, n, left(trim(coalesce(p_pos, '')), 20), a.id);
  return jsonb_build_object('ok', true);
end $$;

grant execute on function dz_selfadd(text,text,text,text) to anon, authenticated;
