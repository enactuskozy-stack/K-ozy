// netlify/functions/feedback.mjs
// K-ozy 피드백(만족도/이슈) 저장소 — Netlify DB(Neon).
//
//  GET    /.netlify/functions/feedback        → { satisfaction:[...], issue:[...] } (관리자)
//  POST   /.netlify/functions/feedback        → 단건 생성 (고객, body 에 type 포함)
//  DELETE /.netlify/functions/feedback?id=ID  → 1건 삭제 (관리자)

import postgres from 'postgres';

// 연결 문자열은 환경변수로만 주입한다(코드에 박지 않음).
// Supabase 서버리스 권장: Transaction 풀러(포트 6543) + prepared statement 끄기.
const CONN = process.env.DATABASE_URL || '';
const sql = CONN
  ? postgres(CONN, { prepare: false, ssl: 'require', idle_timeout: 20, max: 1 })
  : null;
const ADMIN_KEY = process.env.KOZY_ADMIN_KEY || '';

function authed(req) {
  if (!ADMIN_KEY) return true;
  return req.headers.get('x-kozy-key') === ADMIN_KEY;
}
function asObj(v) {
  return typeof v === 'string' ? JSON.parse(v) : v;
}
const json = (status, body) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });

let _ready;
function ensureTable() {
  if (!_ready) {
    _ready = sql`
      CREATE TABLE IF NOT EXISTS feedback (
        id         text PRIMARY KEY,
        type       text NOT NULL,
        data       jsonb NOT NULL,
        created_at timestamptz DEFAULT now()
      )`;
  }
  return _ready;
}

export default async (req) => {
  try {
    if (!sql) return json(500, { error: 'DATABASE_URL not configured' });
    await ensureTable();
    const method = req.method;

    if (method === 'GET') {
      if (!authed(req)) return json(401, { error: 'unauthorized' });
      const rows = await sql`SELECT type, data FROM feedback ORDER BY created_at ASC`;
      const out = { satisfaction: [], issue: [] };
      for (const r of rows) {
        const t = r.type || 'issue';
        if (!out[t]) out[t] = [];
        out[t].push(asObj(r.data));
      }
      return json(200, out);
    }

    if (method === 'POST') {
      const o = await req.json();
      const id = String(o && o.id != null ? o.id : '');
      const type = (o && o.type) || 'issue';
      if (!id || id === 'undefined' || id === 'null') return json(400, { error: 'id required' });
      const payload = JSON.stringify(o);
      await sql`
        INSERT INTO feedback (id, type, data)
        VALUES (${id}, ${type}, ${payload}::jsonb)
        ON CONFLICT (id) DO UPDATE SET type = EXCLUDED.type, data = EXCLUDED.data`;
      return json(200, { ok: true });
    }

    if (method === 'DELETE') {
      if (!authed(req)) return json(401, { error: 'unauthorized' });
      const id = new URL(req.url).searchParams.get('id');
      if (!id) return json(400, { error: 'id required' });
      await sql`DELETE FROM feedback WHERE id = ${String(id)}`;
      return json(200, { ok: true });
    }

    return json(405, { error: 'method not allowed' });
  } catch (e) {
    return json(500, { error: String((e && e.message) || e) });
  }
};
