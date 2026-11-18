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

## Cards and packs (v2)
New card design (rarity frame, parallel ribbon and serial stamp, on-card autographs, all six stats, explained back). Card guide in the Cards tab.
Seven packs, each with its own opening: Rookie Rush, All-Star Surge, Bullpen Heat, Grand Slam, World Series Vault, Hall of Fame Vault (tiger), Cosmic Moonshot. The top three give 3 cards.
Levels no longer stop at Hall of Famer: Legend, Icon, Immortal, then Immortal ★2, ★3... every 2,500 XP.

## Team Clubhouse
Run `supabase/dugout-clubhouse.sql` once in the Supabase SQL Editor (after `dugout-backend.sql` and `dugout-duel.sql`).
New Clubhouse tab holds the Arcade, Cards, Trades, Challenges and Leaderboards.
Trades: offer 1-3 of your cards for 0-3 of a teammate's. Cards move through the inbox when each player next syncs.
Challenges: play any game and send your score. Teammates get the same questions (shared seed). Winner +30 XP, tie +20, +10 for playing.
No daily limit on XP to spend.

## Search, XP and Home
🔎 in the top bar searches every page, game, drill, video, trivia/rule question, card and player.
Players see their XP in the top bar (tap for the XP page: level, how to earn, recent XP, all levels). Home starts with the XP card, then today's work.

## Gear and jerseys
Clubhouse → 🎽 Locker. 22 jersey designs (BigDawgz Classic, Old Gold Dawg Pound, Midnight Dawgz, New Hudson Nights, Walled Lake Waves, Cooperstown Classic, Tigerstripe, Galaxy, Lava Flow and more), each in Home, Away and Alternate = 66 jerseys, plus 31 bats, gloves, cleats, helmets and batting gloves.
Gear drops from every pack (better packs always), and the Locker Room Crate (900 XP) is 3 pieces of gear with a jersey for sure. Equipped gear adds up to +12 to the squad rating. The equipped jersey shows on My Card.
