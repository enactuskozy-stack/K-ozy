// netlify/functions/feedback.mjs
// K-ozy 피드백(만족도/이슈) 저장소 — Netlify DB(Neon/Supabase).
//
//  GET    /.netlify/functions/feedback              → { satisfaction:[...], issue:[...] }  [관리자 전용]
//  GET    /.netlify/functions/feedback?photo=1&id=ID&i=N → { src } 첨부 사진 원본 1장
//  POST   /.netlify/functions/feedback              → 단건 생성 (고객, body 에 type 포함)   [공개]
//  DELETE /.netlify/functions/feedback?id=ID        → 1건 삭제                              [관리자 전용]
//
// 권한 판정은 전부 서버(netlify/shared/auth.mjs)에서 한다. orders.mjs 와 동일 정책.

import postgres from 'postgres';
import { isAdminRequest, isAdminMutation, rateLimit, clientIp, json, denied } from '../shared/auth.mjs';

// 연결 문자열은 환경변수로만 주입한다(코드에 박지 않음).
// Supabase 서버리스 권장: Transaction 풀러(포트 6543) + prepared statement 끄기.
const CONN = process.env.DATABASE_URL || '';
const sql = CONN
  ? postgres(CONN, { prepare: false, ssl: 'require', idle_timeout: 20, max: 1 })
  : null;

const TYPES = ['satisfaction', 'issue'];
// 사진 첨부를 허용하면서 본문 상한을 올렸다. 브라우저가 업로드 전에 리사이즈/압축하므로
// 정상 제출은 2MB 를 넘지 않는다(사진 3장 × 약 0.6MB + 썸네일).
const MAX_BODY_BYTES = 3_500_000;
const MAX_ITEM_BYTES = 3_000_000;
const MAX_FIELDS = 60;
const MAX_STRING = 2000;

/* ── 첨부 사진 ──
   photos: [{ t: 썸네일 data URL, f: 원본 data URL }] 형태로 jsonb 에 함께 저장한다.
   목록 API 는 썸네일만 내려주고, 원본은 ?photo=1 로 1장씩 받아간다(응답 크기 방어). */
const MAX_PHOTOS = 3;
const MAX_PHOTO_BYTES = 900_000;   // 원본 data URL 길이 상한
const MAX_THUMB_BYTES = 160_000;   // 썸네일 data URL 길이 상한
const DATA_URL_RE = /^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$/;

const asObj = (v) => (typeof v === 'string' ? JSON.parse(v) : v);

const isDataUrl = (s, max) => typeof s === 'string' && s.length > 0 && s.length <= max && DATA_URL_RE.test(s);

/** 클라이언트가 보낸 photos 를 검증한다. 형식이 어긋난 항목은 조용히 버린다. */
function sanitizePhotos(raw) {
  if (!Array.isArray(raw)) return [];
  const out = [];
  for (const p of raw) {
    if (out.length >= MAX_PHOTOS) break;
    const full = typeof p === 'string' ? p : (p && typeof p === 'object' ? p.f : '');
    if (!isDataUrl(full, MAX_PHOTO_BYTES)) continue;
    const thumb = p && typeof p === 'object' ? p.t : '';
    out.push({ t: isDataUrl(thumb, MAX_THUMB_BYTES) ? thumb : full, f: full });
  }
  return out;
}

/** 목록 응답용 — 썸네일만 남기고 원본은 뺀다. */
const photoThumbs = (d) =>
  (Array.isArray(d && d.photos) ? d.photos : [])
    .slice(0, MAX_PHOTOS)
    .map((p) => (typeof p === 'string' ? p : (p && p.t) || ''))
    .filter((s) => isDataUrl(s, MAX_PHOTO_BYTES));

let _ready;
function ensureTable() {
  if (!_ready) {
    _ready = sql`
      CREATE TABLE IF NOT EXISTS feedback (
        id         text PRIMARY KEY,
        type       text NOT NULL,
        data       jsonb NOT NULL,
        created_at timestamptz DEFAULT now()
      )`.catch((e) => {
      _ready = null;
      throw e;
    });
  }
  return _ready;
}

/**
 * 공개 리뷰에 표시할 이름 마스킹.
 *  '홍길동' → '홍*동',  '김하' → '김*',  'Sophia Miller' → 'Sophia M.',  'Sophia' → 'So****'
 */
function maskName(raw) {
  const s = String(raw == null ? '' : raw).trim();
  if (!s) return '익명';
  const parts = s.split(/\s+/).filter(Boolean);
  if (parts.length > 1) {
    return parts[0].slice(0, 20) + ' ' + parts[parts.length - 1].charAt(0).toUpperCase() + '.';
  }
  if (/^[가-힣]+$/.test(s)) {
    if (s.length <= 2) return s.charAt(0) + '*';
    return s.charAt(0) + '*'.repeat(s.length - 2) + s.charAt(s.length - 1);
  }
  if (s.length <= 2) return s.charAt(0) + '*';
  return s.slice(0, 2) + '*'.repeat(Math.min(6, s.length - 2));
}

function sanitizeFeedback(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return { error: 'invalid body' };

  const type = TYPES.includes(input.type) ? input.type : 'issue';
  const out = {};
  let fields = 0;
  for (const [k, v] of Object.entries(input)) {
    if (k === 'photos') continue;   // 사진은 아래에서 따로 검증한다(문자열 절단 대상 아님)
    if (++fields > MAX_FIELDS) return { error: 'too many fields' };
    if (typeof v === 'string') out[k] = v.slice(0, MAX_STRING);
    else if (v === null || typeof v === 'number' || typeof v === 'boolean') out[k] = v;
    else out[k] = String(JSON.stringify(v) || '').slice(0, MAX_STRING);
  }

  const id = String(out.id != null ? out.id : '');
  if (!id || id === 'undefined' || id === 'null' || id.length > 64) return { error: 'id required' };
  out.id = id;
  out.type = type;
  out.serverReceivedAt = new Date().toISOString();

  const photos = sanitizePhotos(input.photos);
  if (photos.length) out.photos = photos;

  if (JSON.stringify(out).length > MAX_ITEM_BYTES) return { error: 'payload too large' };
  return { value: out, id, type };
}

export default async (req) => {
  try {
    if (!sql) return json(500, { error: 'DATABASE_URL not configured' });
    const method = req.method;

    if (method === 'GET') {
      const params = new URL(req.url).searchParams;

      // 첨부 사진 원본 1장 (?photo=1&id=ID&i=N)
      //  - 공개로 열람 가능한 건 '숨김이 아닌 리뷰'의 사진뿐이다.
      //  - 이슈 보고 사진과 숨김 리뷰 사진은 관리자 세션에서만 내려간다.
      //  - 존재 여부를 흘리지 않도록 권한 없는 요청도 404 로 답한다.
      if (params.get('photo') === '1') {
        const id = String(params.get('id') || '');
        const i = Number(params.get('i'));
        if (!id || id.length > 64 || !Number.isInteger(i) || i < 0 || i >= MAX_PHOTOS) {
          return json(400, { error: 'bad request' });
        }
        await ensureTable();
        const rows = await sql`SELECT type, data FROM feedback WHERE id = ${id} LIMIT 1`;
        if (!rows.length) return json(404, { error: 'not found' });
        const d = asObj(rows[0].data) || {};
        if (!isAdminRequest(req) && (rows[0].type !== 'satisfaction' || d.hidden === true)) {
          return json(404, { error: 'not found' });
        }
        const p = Array.isArray(d.photos) ? d.photos[i] : null;
        const src = typeof p === 'string' ? p : (p && p.f) || '';
        if (!isDataUrl(src, MAX_PHOTO_BYTES)) return json(404, { error: 'not found' });
        return json(200, { src });
      }

      // 공개 리뷰(?public=1) / 공개 집계(?summary=1)
      //  - 이름은 마스킹하고 이메일 등 개인정보는 내보내지 않는다.
      //  - 관리자가 숨김(hidden) 처리한 리뷰는 제외한다.
      if (params.get('public') === '1' || params.get('summary') === '1') {
        await ensureTable();
        const rows = await sql`SELECT data FROM feedback WHERE type = 'satisfaction' ORDER BY created_at DESC`;
        const items = rows.map((r) => asObj(r.data) || {}).filter((d) => d.hidden !== true);

        const acc = { starRating: 0, q1: 0, q2: 0, q3: 0, q4: 0 };
        const n = { starRating: 0, q1: 0, q2: 0, q3: 0, q4: 0 };
        const dist = { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 };
        for (const d of items) {
          for (const k of Object.keys(acc)) {
            const v = Number(d[k]);
            if (Number.isFinite(v) && v > 0) { acc[k] += v; n[k] += 1; }
          }
          const s = Math.round(Number(d.starRating));
          if (s >= 1 && s <= 5) dist[s] += 1;
        }
        const avg = (k) => (n[k] ? Math.round((acc[k] / n[k]) * 100) / 100 : 0);
        const summary = {
          count: items.length,
          avgStar: avg('starRating'),
          q1: avg('q1'), q2: avg('q2'), q3: avg('q3'), q4: avg('q4'),
          dist,
        };

        if (params.get('summary') === '1') return json(200, summary);

        const limit = Math.min(Math.max(Number(params.get('limit')) || 200, 1), 500);
        const reviews = items.slice(0, limit).map((d) => ({
          id: d.id,
          name: maskName(d.name),
          star: Math.round(Number(d.starRating)) || 0,
          title: String(d.title || '').slice(0, 120),
          body: String(d.body || d.positive || '').slice(0, 2000),
          improvement: String(d.improvement || '').slice(0, 2000),
          recommend: d.recommend || '',
          submittedAt: d.submittedAt || '',
          photos: photoThumbs(d),   // 원본은 ?photo=1 로 따로 받아간다
        }));
        return json(200, { summary, reviews });
      }

      if (!isAdminRequest(req)) return denied();
      await ensureTable();
      const rows = await sql`SELECT type, data FROM feedback ORDER BY created_at ASC`;
      const out = { satisfaction: [], issue: [] };
      for (const r of rows) {
        const t = TYPES.includes(r.type) ? r.type : 'issue';
        const d = asObj(r.data) || {};
        // 관리자 목록도 썸네일만 내려준다(원본까지 실으면 응답이 수십 MB 가 된다).
        // 원본은 상세 화면에서 ?photo=1 로 1장씩 받아간다.
        out[t].push(
          Array.isArray(d.photos)
            ? { ...d, photos: photoThumbs(d).map((t2) => ({ t: t2 })) }
            : d
        );
      }
      return json(200, out);
    }

    if (method === 'POST') {
      const text = await req.text();
      if (text.length > MAX_BODY_BYTES) return json(413, { error: 'payload too large' });
      let parsed;
      try {
        parsed = JSON.parse(text);
      } catch (e) {
        return json(400, { error: 'invalid json' });
      }

      const rl = rateLimit(`feedback:${clientIp(req)}`, 30, 10 * 60 * 1000);
      if (!rl.ok) {
        return json(429, { error: 'too many requests', retryAfter: rl.retryAfter }, { 'retry-after': String(rl.retryAfter) });
      }

      const clean = sanitizeFeedback(parsed);
      if (clean.error) return json(400, { error: clean.error });

      await ensureTable();
      // 공개 경로이므로 INSERT 전용 — 기존 응답을 덮어쓸 수 없다.
      const rows = await sql`
        INSERT INTO feedback (id, type, data)
        VALUES (${clean.id}, ${clean.type}, ${JSON.stringify(clean.value)}::jsonb)
        ON CONFLICT (id) DO NOTHING
        RETURNING id`;
      if (!rows.length) return json(409, { error: 'duplicate id' });
      return json(200, { ok: true });
    }

    // 관리자: 리뷰 공개/숨김 전환 (공개 목록에서 제외하되 데이터는 보존)
    if (method === 'PUT') {
      if (!isAdminMutation(req)) return denied();
      const text = await req.text();
      if (text.length > 10_000) return json(413, { error: 'payload too large' });
      let body;
      try {
        body = JSON.parse(text);
      } catch (e) {
        return json(400, { error: 'invalid json' });
      }
      const id = String((body && body.id) != null ? body.id : '');
      if (!id || id.length > 64) return json(400, { error: 'id required' });
      const hidden = !!(body && body.hidden);
      await ensureTable();
      const rows = await sql`
        UPDATE feedback
           SET data = jsonb_set(data, '{hidden}', ${JSON.stringify(hidden)}::jsonb, true)
         WHERE id = ${id}
        RETURNING id`;
      if (!rows.length) return json(404, { error: 'not found' });
      return json(200, { ok: true, hidden });
    }

    if (method === 'DELETE') {
      if (!isAdminMutation(req)) return denied();
      const id = new URL(req.url).searchParams.get('id');
      if (!id || id.length > 64) return json(400, { error: 'id required' });
      await ensureTable();
      await sql`DELETE FROM feedback WHERE id = ${String(id)}`;
      return json(200, { ok: true });
    }

    return json(405, { error: 'method not allowed' });
  } catch (e) {
    return json(500, { error: String((e && e.message) || e) });
  }
};
