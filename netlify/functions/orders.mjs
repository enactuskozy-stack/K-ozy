// netlify/functions/orders.mjs
// K-ozy 주문(rental) 저장소 — Netlify DB(Neon/Supabase)와 통신하는 서버 함수.
// DB 접속정보(DATABASE_URL)는 이 서버 런타임에만 존재하고 브라우저에 노출되지 않는다.
//
//  GET    /.netlify/functions/orders        → 전체 주문 배열              [관리자 전용]
//  POST   /.netlify/functions/orders        → 단건 생성(고객 신청, 공개) / 배열 일괄 upsert [관리자 전용]
//  DELETE /.netlify/functions/orders?id=ID  → 1건 삭제                    [관리자 전용]
//
// 권한 판정은 전부 서버(netlify/shared/auth.mjs)에서 한다.
//  - 관리자 세션 쿠키(HttpOnly) 또는 x-kozy-key(스크립트용)만 인정한다.
//  - 인증 환경변수가 하나도 없으면 관리자 API 는 전면 차단된다(fail closed).
//  - 공개 경로는 "신규 1건 생성"뿐이며, 기존 주문을 덮어쓰거나 관리자 필드를
//    조작할 수 없도록 서버에서 정규화한다.

import postgres from 'postgres';
import { isAdminRequest, isAdminMutation, rateLimit, clientIp, json, denied } from '../shared/auth.mjs';

// 연결 문자열은 환경변수로만 주입한다(코드에 박지 않음).
// Supabase 서버리스 권장: Transaction 풀러(포트 6543) + prepared statement 끄기.
const CONN = process.env.DATABASE_URL || '';
const sql = CONN
  ? postgres(CONN, { prepare: false, ssl: 'require', idle_timeout: 20, max: 1 })
  : null;

const MAX_BODY_BYTES = 1_000_000; // 1MB
const MAX_ORDER_BYTES = 20_000; // 단건 20KB
const MAX_BULK_ITEMS = 5000;
const MAX_FIELDS = 80;
const MAX_STRING = 2000;

// 고객(비인증)이 스스로 정할 수 없는 값 — 운영 상태·정산 관련 필드.
const ADMIN_ONLY_FIELDS = [
  'orderNo',
  'rentStatus',
  'rentAuto',
  'payments',
  'paid',
  'paidAt',
  'settled',
  'refund',
  'refundAt',
  'deposit',
  'memo',
  'adminMemo',
  'adminNote',
  'internalNote',
];

// 예전 버전이 jsonb 컬럼에 "JSON 문자열"을 넣어 둔 행이 남아 있을 수 있어 방어적으로 되돌린다.
// (신규 저장은 sql.json() 을 쓰므로 항상 객체다 — 아래 upsertAdmin/insertPublic 주석 참고)
const asObj = (v) => (typeof v === 'string' ? JSON.parse(v) : v);

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
      )`.catch((e) => {
      _ready = null; // 실패한 promise 를 영구 캐시하지 않는다
      throw e;
    });
  }
  return _ready;
}

async function readBody(req) {
  const text = await req.text();
  if (text.length > MAX_BODY_BYTES) return { error: 'payload too large' };
  try {
    return { value: JSON.parse(text) };
  } catch (e) {
    return { error: 'invalid json' };
  }
}

function isPlainObject(v) {
  return !!v && typeof v === 'object' && !Array.isArray(v);
}

/** 공개(비인증) 생성 요청 정규화: 관리자 필드 제거 + 크기 제한 + 상태 고정. */
function sanitizePublicOrder(input) {
  if (!isPlainObject(input)) return { error: 'invalid order' };

  const out = {};
  let fields = 0;
  for (const [k, v] of Object.entries(input)) {
    if (ADMIN_ONLY_FIELDS.includes(k)) continue;
    if (++fields > MAX_FIELDS) return { error: 'too many fields' };
    if (typeof v === 'string') out[k] = v.slice(0, MAX_STRING);
    else if (v === null || typeof v === 'number' || typeof v === 'boolean') out[k] = v;
    else out[k] = String(JSON.stringify(v) || '').slice(0, MAX_STRING); // 중첩 구조는 문자열로 평탄화
  }

  const id = String(out.id != null ? out.id : '');
  if (!id || id === 'undefined' || id === 'null' || id.length > 64) return { error: 'invalid id' };

  out.id = id;
  out.status = 'new'; // 접수 상태는 서버가 고정
  // 접수 채널: B = 현장 부스(이벤트 팝업), W = 웹. 그 외 값은 W 로 정규화한다.
  // 채널은 집계·주문번호 접두사에만 쓰이고 권한이나 금액에는 관여하지 않으므로
  // 고객이 보낸 값을 인정한다. (예전에는 무조건 'W' 로 덮어써서 부스 접수가
  //  전부 웹 접수로 집계되고 주문번호도 W- 로 나갔다)
  out.channel = String(out.channel || '').trim().toUpperCase() === 'B' ? 'B' : 'W';
  out.serverReceivedAt = new Date().toISOString();

  if (JSON.stringify(out).length > MAX_ORDER_BYTES) return { error: 'order too large' };
  return { value: out };
}

/** 관리자 일괄 upsert 용 최소 검증. */
function normalizeAdminOrder(o) {
  if (!isPlainObject(o)) return null;
  const id = String(o.id != null ? o.id : '');
  if (!id || id === 'undefined' || id === 'null' || id.length > 64) return null;
  const payload = JSON.stringify(o);
  if (payload.length > MAX_ORDER_BYTES) return null;
  return { id, o };
}

// ⚠ 반드시 sql.json(객체) 로 넘긴다.
// `${JSON.stringify(o)}::jsonb` 로 쓰면 postgres.js 가 그 문자열을 한 번 더 JSON 으로
// 감싸서, DB 에는 객체가 아니라 "JSON 문자열"이 저장된다(jsonb_typeof = 'string').
// 그러면 data->>'kind' 같은 조회도, jsonb_set 도, GIN 인덱스도 전부 무용지물이 된다.
async function upsertAdmin(item) {
  const { id, o } = item;
  await sql`
    INSERT INTO orders (id, order_no, status, rent_status, data, updated_at)
    VALUES (${id}, ${o.orderNo || null}, ${o.status || null}, ${o.rentStatus || null}, ${sql.json(o)}, now())
    ON CONFLICT (id) DO UPDATE SET
      order_no    = EXCLUDED.order_no,
      status      = EXCLUDED.status,
      rent_status = EXCLUDED.rent_status,
      data        = EXCLUDED.data,
      updated_at  = now()`;
}

/** 공개 생성은 INSERT 전용 — 기존 주문을 덮어쓸 수 없다. */
async function insertPublic(o) {
  const rows = await sql`
    INSERT INTO orders (id, order_no, status, rent_status, data)
    VALUES (${o.id}, ${null}, ${'new'}, ${null}, ${sql.json(o)})
    ON CONFLICT (id) DO NOTHING
    RETURNING id`;
  return rows.length > 0;
}

export default async (req) => {
  try {
    if (!sql) return json(500, { error: 'DATABASE_URL not configured' });
    const method = req.method;

    if (method === 'GET') {
      if (!isAdminRequest(req)) return denied();
      await ensureTable();
      const rows = await sql`SELECT data FROM orders ORDER BY created_at ASC`;
      return json(200, rows.map((r) => asObj(r.data)));
    }

    if (method === 'POST') {
      const body = await readBody(req);
      if (body.error) return json(body.error === 'payload too large' ? 413 : 400, { error: body.error });

      // 배열 = 관리자 동기화(일괄 upsert)
      if (Array.isArray(body.value)) {
        if (!isAdminMutation(req)) return denied();
        if (body.value.length > MAX_BULK_ITEMS) return json(413, { error: 'too many items' });
        await ensureTable();
        let count = 0;
        for (const raw of body.value) {
          const item = normalizeAdminOrder(raw);
          if (!item) continue;
          await upsertAdmin(item);
          count++;
        }
        return json(200, { ok: true, count });
      }

      // 단건 = 고객 신청(공개). 남용 방지를 위한 간이 제한.
      const rl = rateLimit(`order:${clientIp(req)}`, 20, 10 * 60 * 1000);
      if (!rl.ok) {
        return json(429, { error: 'too many requests', retryAfter: rl.retryAfter }, { 'retry-after': String(rl.retryAfter) });
      }
      const clean = sanitizePublicOrder(body.value);
      if (clean.error) return json(400, { error: clean.error });

      await ensureTable();
      const created = await insertPublic(clean.value);
      if (!created) return json(409, { error: 'duplicate id' });
      return json(200, { ok: true, count: 1 });
    }

    if (method === 'DELETE') {
      if (!isAdminMutation(req)) return denied();
      const id = new URL(req.url).searchParams.get('id');
      if (!id || id.length > 64) return json(400, { error: 'id required' });
      await ensureTable();
      await sql`DELETE FROM orders WHERE id = ${String(id)}`;
      return json(200, { ok: true });
    }

    return json(405, { error: 'method not allowed' });
  } catch (e) {
    return json(500, { error: String((e && e.message) || e) });
  }
};
