# BigDawgz 12U Dugout

Team app for BigDawgz 12U: drills, games and the at-home program.

## Head-to-Head (live duels)
Run `supabase/dugout-duel.sql` once in the Supabase SQL Editor (after `dugout-backend.sql` and `dugout-live.sql`).
Players challenge a teammate from Play > Head-to-Head. Coaches can turn it off for the team on the same screen.

## Players make their own profile
Run `supabase/dugout-selfadd.sql` once in the Supabase SQL Editor (after `dugout-backend.sql`).
A new player who isn't on the team list taps "Make my profile" and types their name, number and position. They're added to the roster already matched to their account. Coach can edit them in Roster.

## High scores and leaderboards
Run `supabase/dugout-boards.sql` once in the Supabase SQL Editor (after `dugout-backend.sql`).
Every game: score = what you got × level (Easy ×1, Medium ×2, Hard ×3, Expert ×4). Expert keeps going until the first miss.
Players see Leaderboards and their high scores from Play and My Card. Coaches get a sortable table of every player's high scores in Coach's View.
Dugout Live: the coach can pick the questions (or write their own) instead of using random ones.
