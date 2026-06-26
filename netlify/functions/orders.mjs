// netlify/functions/orders.mjs
// K-ozy 주문(rental) 저장소 — Netlify DB(Neon)와 통신하는 서버 함수.
// DB 접속정보(NETLIFY_DATABASE_URL)는 이 서버 런타임에만 존재하고 브라우저에 노출되지 않는다.
//
//  GET    /.netlify/functions/orders        → 전체 주문 배열 (관리자)
//  POST   /.netlify/functions/orders        → 단건 생성(고객) 또는 배열 일괄 upsert(관리자)
//  DELETE /.netlify/functions/orders?id=ID  → 1건 삭제 (관리자)
//
// 보안: 환경변수 KOZY_ADMIN_KEY 가 설정돼 있으면 GET/DELETE/일괄 upsert 는
//       헤더 x-kozy-key 가 일치할 때만 허용된다. (미설정 시 = 부트스트랩용 전체 공개)

import postgres from 'postgres';

// 연결 문자열은 환경변수로만 주입한다(코드에 박지 않음).
// Supabase 서버리스 권장: Transaction 풀러(포트 6543) + prepared statement 끄기.
const CONN = process.env.DATABASE_URL || '';
const sql = CONN
  ? postgres(CONN, { prepare: false, ssl: 'require', idle_timeout: 20, max: 1 })
  : null;
const ADMIN_KEY = process.env.KOZY_ADMIN_KEY || '';

function authed(req) {
  if (!ADMIN_KEY) return true; // 키 미설정 → 공개(초기 셋업용)
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
      CREATE TABLE IF NOT EXISTS orders (
        id          text PRIMARY KEY,
        order_no    text,
        status      text,
        rent_status text,
        data        jsonb NOT NULL,
        created_at  timestamptz DEFAULT now(),
        updated_at  timestamptz DEFAULT now()
      )`;
  }
  return _ready;
}

async function upsertOne(o) {
  const id = String(o && o.id != null ? o.id : '');
  if (!id || id === 'undefined' || id === 'null') return;
  const payload = JSON.stringify(o);
  await sql`
    INSERT INTO orders (id, order_no, status, rent_status, data, updated_at)
    VALUES (${id}, ${o.orderNo || null}, ${o.status || null}, ${o.rentStatus || null}, ${payload}::jsonb, now())
    ON CONFLICT (id) DO UPDATE SET
      order_no    = EXCLUDED.order_no,
      status      = EXCLUDED.status,
      rent_status = EXCLUDED.rent_status,
      data        = EXCLUDED.data,
      updated_at  = now()`;
}

export default async (req) => {
  try {
    if (!sql) return json(500, { error: 'DATABASE_URL not configured' });
    await ensureTable();
    const method = req.method;

    if (method === 'GET') {
      if (!authed(req)) return json(401, { error: 'unauthorized' });
      const rows = await sql`SELECT data FROM orders ORDER BY created_at ASC`;
      return json(200, rows.map((r) => asObj(r.data)));
    }

    if (method === 'POST') {
      const body = await req.json();
      const isBulk = Array.isArray(body);
      // 일괄 upsert(관리자 동기화)는 인증 필요. 단건 생성(고객 신청)은 공개.
      if (isBulk && !authed(req)) return json(401, { error: 'unauthorized' });
      const list = isBulk ? body : [body];
      for (const o of list) await upsertOne(o);
      return json(200, { ok: true, count: list.length });
    }

    if (method === 'DELETE') {
      if (!authed(req)) return json(401, { error: 'unauthorized' });
      const id = new URL(req.url).searchParams.get('id');
      if (!id) return json(400, { error: 'id required' });
      await sql`DELETE FROM orders WHERE id = ${String(id)}`;
      return json(200, { ok: true });
    }

    return json(405, { error: 'method not allowed' });
  } catch (e) {
    return json(500, { error: String((e && e.message) || e) });
  }
};
