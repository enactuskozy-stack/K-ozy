// netlify/functions/admin-store.mjs
// K-ozy 관리자 운영 데이터 저장소 (고객·학교·메일 대기열·재고·설정 플래그).
//
//  GET /.netlify/functions/admin-store          → { customers, schools, emails, inventory, flags }  [관리자 전용]
//  GET /.netlify/functions/admin-store?public=1 → { flags:{ ... } } 공개 설정만                      [공개]
//  PUT /.netlify/functions/admin-store          → { customers:[...], flags:{...} } 형태로 일부만 저장 [관리자 전용]
//
// ?public=1 을 뺀 나머지는 전부 관리자 전용이다. 브라우저 localStorage 대신 이 곳에 저장해
// 기기를 바꿔도 같은 데이터를 보고, 공용 PC 에 운영 데이터가 남지 않게 한다.

import postgres from 'postgres';
import { isAdminRequest, isAdminMutation, json, denied } from '../shared/auth.mjs';

const CONN = process.env.DATABASE_URL || '';
const sql = CONN
  ? postgres(CONN, { prepare: false, ssl: 'require', idle_timeout: 20, max: 1 })
  : null;

// 저장 가능한 키 화이트리스트 — 배열(컬렉션) / 객체(플래그)
const ARRAY_KEYS = ['customers', 'schools', 'emails', 'inventory'];
const OBJECT_KEYS = ['flags'];
const ALL_KEYS = ARRAY_KEYS.concat(OBJECT_KEYS);

const MAX_BODY_BYTES = 2_000_000; // 2MB
const MAX_ITEMS = 20_000;

// 로그인하지 않은 방문자에게도 내려주는 설정 키(화이트리스트).
// 여기 없는 플래그는 절대 공개되지 않는다.
// ※ supabase/migrations 의 kz_flag_is_public() 과 같은 목록을 유지할 것.
const PUBLIC_FLAG_KEYS = ['kozy_event_popup', 'kozy_fx'];

const asObj = (v) => (typeof v === 'string' ? JSON.parse(v) : v);

let _ready;
function ensureTable() {
  if (!_ready) {
    _ready = sql`
      CREATE TABLE IF NOT EXISTS admin_store (
        key        text PRIMARY KEY,
        data       jsonb NOT NULL,
        updated_at timestamptz DEFAULT now()
      )`.catch((e) => {
      _ready = null;
      throw e;
    });
  }
  return _ready;
}

function emptyStore() {
  const out = {};
  for (const k of ARRAY_KEYS) out[k] = [];
  for (const k of OBJECT_KEYS) out[k] = {};
  return out;
}

function validValue(key, v) {
  if (ARRAY_KEYS.includes(key)) return Array.isArray(v) && v.length <= MAX_ITEMS;
  if (OBJECT_KEYS.includes(key)) return !!v && typeof v === 'object' && !Array.isArray(v);
  return false;
}

export default async (req) => {
  try {
    if (!sql) return json(500, { error: 'DATABASE_URL not configured' });
    const method = req.method;

    if (method === 'GET') {
      // ── 공개 설정 (?public=1) ──
      // 현장 이벤트 팝업 ON/OFF 는 로그인하지 않은 방문자 화면이 읽어야 한다.
      // 화이트리스트에 있는 키만 담아 내보내므로 고객·주문 데이터는 노출되지 않는다.
      if (new URL(req.url).searchParams.get('public') === '1') {
        await ensureTable();
        const rows = await sql`SELECT data FROM admin_store WHERE key = 'flags' LIMIT 1`;
        const all = rows.length ? asObj(rows[0].data) : null;
        const flags = {};
        if (all && typeof all === 'object' && !Array.isArray(all)) {
          for (const k of PUBLIC_FLAG_KEYS) {
            if (all[k] !== undefined) flags[k] = all[k];
          }
        }
        return json(200, { flags });
      }

      if (!isAdminRequest(req)) return denied();
      await ensureTable();
      const rows = await sql`SELECT key, data FROM admin_store`;
      const out = emptyStore();
      for (const r of rows) {
        if (ALL_KEYS.includes(r.key)) out[r.key] = asObj(r.data);
      }
      return json(200, out);
    }

    if (method === 'PUT' || method === 'POST') {
      if (!isAdminMutation(req)) return denied();

      const text = await req.text();
      if (text.length > MAX_BODY_BYTES) return json(413, { error: 'payload too large' });
      let body;
      try {
        body = JSON.parse(text);
      } catch (e) {
        return json(400, { error: 'invalid json' });
      }
      if (!body || typeof body !== 'object' || Array.isArray(body)) {
        return json(400, { error: 'invalid body' });
      }

      await ensureTable();
      const saved = [];
      for (const key of Object.keys(body)) {
        if (!ALL_KEYS.includes(key)) continue; // 화이트리스트 외 키는 무시
        const value = body[key];
        if (!validValue(key, value)) return json(400, { error: 'invalid value for ' + key });
        // sql.json(값) 으로 넘겨야 jsonb 에 배열/객체가 들어간다.
        // `${JSON.stringify(v)}::jsonb` 는 문자열을 한 번 더 감싸 저장한다.
        await sql`
          INSERT INTO admin_store (key, data, updated_at)
          VALUES (${key}, ${sql.json(value)}, now())
          ON CONFLICT (key) DO UPDATE SET data = EXCLUDED.data, updated_at = now()`;
        saved.push(key);
      }
      if (!saved.length) return json(400, { error: 'no valid keys' });
      return json(200, { ok: true, saved });
    }

    return json(405, { error: 'method not allowed' });
  } catch (e) {
    return json(500, { error: String((e && e.message) || e) });
  }
};
