// netlify/shared/auth.mjs
// K-ozy 관리자 인증 공통 모듈 (서버 전용).
//
// 이 파일은 Netlify Function 이 아니라 함수들이 import 하는 라이브러리다.
// (functions 디렉터리 밖에 두어 엔드포인트로 배포되지 않는다.)
//
// 핵심 원칙
//  1) 인증은 전적으로 서버에서 판정한다. 브라우저가 보내온 값은 신뢰하지 않는다.
//  2) 환경변수가 하나도 설정돼 있지 않으면 "공개"가 아니라 "전면 차단"이다(fail closed).
//  3) 세션 토큰은 HMAC 서명 + 만료시각을 담고, HttpOnly 쿠키로만 오간다.
//     (JS 에서 읽을 수 없으므로 XSS 로 토큰을 직접 탈취할 수 없다.)
//  4) 비밀번호/키 비교는 timingSafeEqual 로 한다.
//
// 필요한 환경변수 (Netlify → Site settings → Environment variables)
//   KOZY_ADMIN_PASSWORD_HASH  관리자 비밀번호 해시. 권장 형식:
//                               scrypt$<saltHex>$<keyHex>   (scripts/hash-password.mjs 로 생성)
//                             sha256$<hex> / 64자리 hex 도 허용.
//   KOZY_ADMIN_PASSWORD       (대안) 평문 비밀번호. 해시를 못 쓸 때만.
//   KOZY_SESSION_SECRET       세션 서명키(임의의 긴 랜덤 문자열). 미설정 시 비밀번호
//                             재료에서 파생한다 → 비밀번호를 바꾸면 기존 세션이 무효화된다.
//   KOZY_ADMIN_KEY            (선택) 서버 간/스크립트용 API 키. x-kozy-key 헤더로 사용.
//   KOZY_SESSION_TTL_HOURS    (선택) 세션 유효시간(기본 8시간).

import { createHmac, createHash, timingSafeEqual, randomBytes, scryptSync } from 'node:crypto';

export const COOKIE_NAME = 'kozy_admin';

const RAW_KEY = (process.env.KOZY_ADMIN_KEY || '').trim();
const RAW_PW = (process.env.KOZY_ADMIN_PASSWORD || '').trim();
const RAW_PW_HASH = (process.env.KOZY_ADMIN_PASSWORD_HASH || '').trim();
const RAW_SECRET = (process.env.KOZY_SESSION_SECRET || '').trim();

const TTL_SECONDS = (() => {
  const h = Number(process.env.KOZY_SESSION_TTL_HOURS);
  const hours = Number.isFinite(h) && h > 0 ? Math.min(h, 24 * 30) : 8;
  return Math.round(hours * 3600);
})();

/* ────────────────── 설정 상태 ────────────────── */

export function hasPasswordLogin() {
  return !!(RAW_PW_HASH || RAW_PW);
}
export function hasApiKey() {
  return !!RAW_KEY;
}
/** 어떤 인증 수단이라도 설정돼 있는가. 하나도 없으면 모든 관리자 API 는 차단된다. */
export function isConfigured() {
  return hasPasswordLogin() || hasApiKey();
}
export function authState() {
  return { configured: isConfigured(), passwordLogin: hasPasswordLogin(), apiKey: hasApiKey() };
}
export function sessionTtlSeconds() {
  return TTL_SECONDS;
}

/* ────────────────── 유틸 ────────────────── */

function sha256Hex(s) {
  return createHash('sha256').update(String(s), 'utf8').digest('hex');
}

/** 길이가 달라도 정보를 흘리지 않는 상수시간 비교. */
function safeEqual(a, b) {
  const ha = createHash('sha256').update(String(a), 'utf8').digest();
  const hb = createHash('sha256').update(String(b), 'utf8').digest();
  return timingSafeEqual(ha, hb);
}

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function sessionSecret() {
  if (RAW_SECRET) return RAW_SECRET;
  if (!isConfigured()) return '';
  // 명시적 시크릿이 없으면 비밀번호/키 재료에서 결정적으로 파생한다.
  // → 비밀번호나 키를 교체하면 기존에 발급된 세션이 자동으로 무효화된다.
  return sha256Hex(`kozy-session-v1|${RAW_PW_HASH}|${RAW_PW}|${RAW_KEY}`);
}

export function parseCookies(req) {
  const raw = req.headers.get('cookie') || '';
  const out = {};
  for (const part of raw.split(';')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    const k = part.slice(0, i).trim();
    if (!k) continue;
    out[k] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

/* ────────────────── 비밀번호 검증 ────────────────── */

/**
 * 지원 형식
 *   scrypt$<saltHex>$<keyHex>
 *   sha256$<hex>
 *   <64자리 hex>            (= sha256)
 *   (해시가 없으면 KOZY_ADMIN_PASSWORD 평문과 비교)
 */
export function verifyPassword(password) {
  const pw = typeof password === 'string' ? password : '';
  if (!pw || pw.length > 512) return false;

  if (RAW_PW_HASH) {
    try {
      if (RAW_PW_HASH.startsWith('scrypt$')) {
        const [, saltHex, keyHex] = RAW_PW_HASH.split('$');
        if (!saltHex || !keyHex) return false;
        const salt = Buffer.from(saltHex, 'hex');
        const expected = Buffer.from(keyHex, 'hex');
        if (!salt.length || !expected.length) return false;
        const actual = scryptSync(pw, salt, expected.length);
        return timingSafeEqual(actual, expected);
      }
      const hex = RAW_PW_HASH.startsWith('sha256$') ? RAW_PW_HASH.slice(7) : RAW_PW_HASH;
      if (!/^[0-9a-f]{64}$/i.test(hex)) return false;
      return safeEqual(sha256Hex(pw), hex.toLowerCase());
    } catch (e) {
      return false;
    }
  }

  if (RAW_PW) return safeEqual(pw, RAW_PW);
  return false;
}

/* ────────────────── 세션 토큰 ────────────────── */

function sign(payload) {
  return b64url(createHmac('sha256', sessionSecret()).update(payload, 'utf8').digest());
}

/** `v1.<만료 epoch(sec)>.<nonce>.<서명>` */
export function issueSessionToken() {
  const secret = sessionSecret();
  if (!secret) return '';
  const exp = Math.floor(Date.now() / 1000) + TTL_SECONDS;
  const nonce = b64url(randomBytes(12));
  const body = `v1.${exp}.${nonce}`;
  return `${body}.${sign(body)}`;
}

export function verifySessionToken(token) {
  const secret = sessionSecret();
  if (!secret || typeof token !== 'string' || token.length > 512) return false;
  const parts = token.split('.');
  if (parts.length !== 4 || parts[0] !== 'v1') return false;
  const [, expStr, nonce, sig] = parts;
  if (!/^\d{1,12}$/.test(expStr) || !nonce) return false;
  const body = `v1.${expStr}.${nonce}`;
  if (!safeEqual(sig, sign(body))) return false;
  return Number(expStr) > Math.floor(Date.now() / 1000);
}

function isSecureRequest(req) {
  try {
    const u = new URL(req.url);
    if (u.protocol === 'https:') return true;
    // netlify dev(로컬 http)만 예외. 그 외에는 프록시 헤더를 신뢰.
    if (u.hostname === 'localhost' || u.hostname === '127.0.0.1') return false;
  } catch (e) {}
  return (req.headers.get('x-forwarded-proto') || '').split(',')[0].trim() !== 'http';
}

export function sessionCookie(req, token) {
  const secure = isSecureRequest(req) ? '; Secure' : '';
  return `${COOKIE_NAME}=${token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${TTL_SECONDS}${secure}`;
}

export function clearedCookie(req) {
  const secure = isSecureRequest(req) ? '; Secure' : '';
  return `${COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0${secure}`;
}

/* ────────────────── 요청 인증 ────────────────── */

/** 이 요청이 관리자 권한을 갖는가. 설정이 없으면 무조건 false(fail closed). */
export function isAdminRequest(req) {
  if (!isConfigured()) return false;

  const token = parseCookies(req)[COOKIE_NAME];
  if (token && verifySessionToken(token)) return true;

  if (RAW_KEY) {
    const k = req.headers.get('x-kozy-key');
    if (k && safeEqual(k, RAW_KEY)) return true;
  }
  return false;
}

/**
 * CSRF 방어: 상태를 바꾸는 요청(POST/PUT/DELETE)의 Origin 이 요청 호스트와 같아야 한다.
 * SameSite=Strict 쿠키와 이중 방어. Origin 이 없는 요청(curl·스크립트)은 통과시키되,
 * 그런 요청은 쿠키가 아니라 x-kozy-key 로 인증되어야 한다.
 */
export function originAllowed(req) {
  const origin = req.headers.get('origin');
  if (!origin) return true;
  try {
    return new URL(origin).host === new URL(req.url).host;
  } catch (e) {
    return false;
  }
}

/** 쿠키 세션으로 들어온 상태 변경 요청은 Origin 검사를 강제한다. */
export function isAdminMutation(req) {
  if (!isAdminRequest(req)) return false;
  const usingCookie = !!parseCookies(req)[COOKIE_NAME];
  if (usingCookie && !originAllowed(req)) return false;
  return true;
}

/* ────────────────── 간이 레이트 리밋 ────────────────── */
// 서버리스 인스턴스 단위의 best-effort 방어. 인스턴스가 여러 개면 완벽하지 않지만
// 단순 자동화 대입 공격의 비용을 크게 올린다.

const _hits = new Map();

export function rateLimit(key, limit, windowMs) {
  const now = Date.now();
  const rec = _hits.get(key);
  if (!rec || now > rec.reset) {
    _hits.set(key, { count: 1, reset: now + windowMs });
    if (_hits.size > 5000) {
      for (const [k, v] of _hits) if (now > v.reset) _hits.delete(k);
    }
    return { ok: true, remaining: limit - 1, retryAfter: 0 };
  }
  rec.count += 1;
  if (rec.count > limit) {
    return { ok: false, remaining: 0, retryAfter: Math.max(1, Math.ceil((rec.reset - now) / 1000)) };
  }
  return { ok: true, remaining: limit - rec.count, retryAfter: 0 };
}

export function resetRateLimit(key) {
  _hits.delete(key);
}

export function clientIp(req) {
  const h = req.headers;
  return (
    (h.get('x-nf-client-connection-ip') || '').trim() ||
    (h.get('x-forwarded-for') || '').split(',')[0].trim() ||
    'unknown'
  );
}

/* ────────────────── 공통 응답 ────────────────── */

export const json = (status, body, headers) =>
  new Response(JSON.stringify(body), {
    status,
    headers: Object.assign(
      { 'content-type': 'application/json', 'cache-control': 'no-store' },
      headers || {}
    ),
  });

/** 관리자 인증 실패 응답. 설정 누락과 인증 실패를 구분해 운영자가 원인을 알 수 있게 한다. */
export function denied() {
  if (!isConfigured()) {
    return json(503, {
      error: 'admin auth not configured',
      hint: 'KOZY_ADMIN_PASSWORD_HASH (또는 KOZY_ADMIN_PASSWORD) 환경변수를 설정하세요.',
    });
  }
  return json(401, { error: 'unauthorized' });
}
