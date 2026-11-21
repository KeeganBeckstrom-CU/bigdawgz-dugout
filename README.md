# Basepaths

The team app for youth baseball coaches, players and families. Run practice. Teach the game.
(Started as the BigDawgz 12U Dugout. BigDawgz is now the first team on Basepaths.)

## Many teams (run this first)
Run `supabase/basepaths-orgs.sql` once in the Supabase SQL Editor, after all the `dugout-*.sql` files. Safe to run again.
- Accounts work across every team. First screen: pick Coach, Parent or Player, then sign in or create an account.
- After signing in you land on **My teams**: current teams and past seasons, each labeled name · age · season.
- **Find your team**: search by name, age, season or town, then ask to join as a player, parent or coach. A coach on that team approves you (Coach's View shows who's waiting, and Masterfile has Approve / Deny).
- Can't find it? Players and parents are told to ask their head coach to create the team. Only coach accounts can create one, and the creator is the head coach.
- Inside a team everything works the way it always has. Tap the team logo in the top bar (or More → My teams) to switch teams.
- Your BigDawgz data becomes the first team, and the first approved coach account becomes the **Basepaths admin**.

## Kids' accounts and deleting accounts (run second)
Run `supabase/basepaths-kids.sql` after `basepaths-orgs.sql`.
- Player sign-up asks for a birth year. Under 13: "Ask a parent to set you up" (remembered on that device).
- Parents: My teams → **My players** → Add my player (name, username, password). That's the parent's OK. Kids sign in with the username.
- Parents can change a kid's password or delete the kid's account. Players who were already on a team show up for their linked parent as "Needs your OK."
- Anyone can delete their account: My teams → Delete my account (an only coach on a team with people must add another coach first).
- `privacy.html` and `terms.html` — fill in the support email before submitting to the App Store, and have a lawyer look them over.

## Team look (coaches)
More → Team look and info. Upload a team logo, a big logo, a banner photo and a background photo; type hex colors or pull them from the logo; set the team's Venmo for dues. Press **Update my team's look** and the app re-themes for everyone on that team. Everything outside a team stays Basepaths-branded.

## Basepaths admin (admins only)
My teams → Basepaths admin. Overview numbers, every team (open it as a coach, members, approve, change roles, edit, pause, delete) and every account (reset password, make admin, delete).
Make another account an admin: `update dg_users set is_admin = true where email = 'them@email.com';`


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

## Dugout Live v2: game settings, prize wheel, parents watching
Run `supabase/dugout-live2.sql` once in the Supabase SQL Editor (after `dugout-live.sql` and `basepaths-orgs.sql`). Safe to run again.
- Coach sets up each game: random or hand-picked questions, how many (3-30), which question types, seconds per question.
- Prizes: how many places win (0-5) and what each place gets: the prize wheel (1st only), any pack, or XP. Plus XP for everyone else who played.
- Prize wheel: the coach picks what's on the wheel. The server picks the result when the game ends and sends it right away; "Spin the wheel" plays the spin on every screen.
- Packs won show up as "Open your pack" on the player's Home and Cards tab.
- Parents can watch (coach can turn it off per game). Parents see "Dugout Live is on now" at the top of My Player.

## Videos from Coach on Home
Videos the coach adds to the Film Room now show on every player's Home ("Videos from Coach"), not only in the Clubhouse.

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
