-- =====================================================================
-- BigDawgz Dugout: leaderboards
-- Run once in the Supabase SQL Editor (after dugout-backend.sql).
-- Everyone signed in can see each player's game high scores and how many
-- games they've played. Nothing else from a player's file is shared.
-- =====================================================================

create or replace function dz_boards(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a dg_accounts;
begin
  a := dg_me(p_tok);
  if a.status <> 'active' then raise exception 'signed_out'; end if;
  return jsonb_build_object('players', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.name, 'num', p.num,
      'hs', coalesce(p.doc->'hs', '{}'::jsonb),
      'gp', coalesce(p.doc->'gp', '{}'::jsonb),
      'best', coalesce(p.doc->'best', '{}'::jsonb)) order by p.name)
    from dg_players p where not p.sample), '[]'::jsonb));
end $$;

grant execute on function dz_boards(text) to anon, authenticated;
