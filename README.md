# BigDawgz 12U Dugout

Team app for BigDawgz 12U: drills, games and the at-home program.

## Head-to-Head (live duels)
Run `supabase/dugout-duel.sql` once in the Supabase SQL Editor (after `dugout-backend.sql` and `dugout-live.sql`).
Players challenge a teammate from Play > Head-to-Head. Coaches can turn it off for the team on the same screen.

## Players make their own profile
Run `supabase/dugout-selfadd.sql` once in the Supabase SQL Editor (after `dugout-backend.sql`).
A new player who isn't on the team list taps "Make my profile" and types their name, number and position. They're added to the roster already matched to their account. Coach can edit them in Roster.
