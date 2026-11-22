// Basepaths: drill videos. Players upload a clip, coaches watch it, then it's deleted.
// Deploy: Supabase > Edge Functions > Deploy a new function > name it "drill-videos" > paste this file.
// Then open the function's settings and turn OFF "Verify JWT" (the app signs in with its own tokens,
// and every action below checks that token in the database first).
// Needs supabase/basepaths-videos.sql to have been run.
import { createClient } from "npm:@supabase/supabase-js@2";

const BUCKET = "drill-videos";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "apikey, content-type, authorization, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const KNOWN = ["signed_out", "no_team", "not_on_team", "team_off", "not_coach", "players_only",
  "not_claimed", "too_big", "too_many", "storage_full", "not_found"];
const out = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const errOf = (e: unknown) => {
  const m = String((e as Error)?.message ?? e ?? "");
  return KNOWN.find((k) => m.includes(k)) ?? "video_failed";
};

async function rpc(fn: string, args: Record<string, unknown>) {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return out({ error: "bad_method" }, 405);
  try {
    const b = await req.json();
    const tok = String(b.tok ?? "");
    if (!tok) return out({ error: "signed_out" }, 401);
    switch (b.action) {
      case "upload": { // player: get a one-time upload link for a new clip
        const r = await rpc("dz_vid_begin", {
          p_tok: tok, p_drill: String(b.drill ?? ""), p_hw: String(b.hw ?? ""),
          p_type: String(b.type ?? ""), p_size: Number(b.size) || 0,
        });
        const { data, error } = await sb.storage.from(BUCKET).createSignedUploadUrl(r.path);
        if (error) throw error;
        return out({ id: r.id, url: data.signedUrl });
      }
      case "sent": { // player: upload finished
        await rpc("dz_vid_sent", { p_tok: tok, p_id: b.id });
        return out({ ok: true });
      }
      case "list": { // coach: clips waiting to be watched
        const r = await rpc("dz_vid_list", { p_tok: tok });
        if (r.stale?.length) await sb.storage.from(BUCKET).remove(r.stale);
        return out({ videos: r.videos ?? [] });
      }
      case "view": { // coach: a viewing link that expires in an hour
        const path = await rpc("dz_vid_get", { p_tok: tok, p_id: b.id });
        const { data, error } = await sb.storage.from(BUCKET).createSignedUrl(path, 3600);
        if (error) throw error;
        return out({ url: data.signedUrl });
      }
      case "reviewed": { // coach: watched it, delete the file
        const path = await rpc("dz_vid_seen", { p_tok: tok, p_id: b.id });
        if (path) await sb.storage.from(BUCKET).remove([path]);
        return out({ ok: true });
      }
      default:
        return out({ error: "bad_action" }, 400);
    }
  } catch (e) {
    const code = errOf(e);
    return out({ error: code }, code === "signed_out" ? 401 : 400);
  }
});
