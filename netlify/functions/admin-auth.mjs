// netlify/functions/admin-auth.mjs
// K-ozy 관리자 로그인/세션 엔드포인트.
//
//  POST   /.netlify/functions/admin-auth   { password }  → 검증 성공 시 HttpOnly 세션 쿠키 발급
//  GET    /.netlify/functions/admin-auth                 → { authenticated, configured, passwordLogin }
//  DELETE /.netlify/functions/admin-auth                 → 로그아웃(쿠키 삭제)
//
// 비밀번호는 서버 환경변수(KOZY_ADMIN_PASSWORD_HASH)에만 존재한다.
// 브라우저 코드에는 비밀번호도, 장기 API 키도 남지 않는다.

import {
  isAdminRequest,
  verifyPassword,
  issueSessionToken,
  sessionCookie,
  clearedCookie,
  sessionTtlSeconds,
  authState,
  hasPasswordLogin,
  isConfigured,
  originAllowed,
  rateLimit,
  resetRateLimit,
  clientIp,
  json,
} from '../shared/auth.mjs';

const LOGIN_LIMIT = 10; // 10회
const LOGIN_WINDOW_MS = 10 * 60 * 1000; // 10분

export default async (req) => {
  try {
    const method = req.method;

    if (method === 'GET') {
      const st = authState();
      return json(200, {
        authenticated: isAdminRequest(req),
        configured: st.configured,
        passwordLogin: st.passwordLogin,
      });
    }

    if (method === 'DELETE') {
      return json(200, { ok: true }, { 'set-cookie': clearedCookie(req) });
    }

    if (method === 'POST') {
      // CSRF: 다른 사이트에서 넘어온 로그인 요청은 받지 않는다.
      if (!originAllowed(req)) return json(403, { error: 'forbidden origin' });

      if (!isConfigured()) {
        return json(503, {
          error: 'admin auth not configured',
          hint: 'KOZY_ADMIN_PASSWORD_HASH (또는 KOZY_ADMIN_PASSWORD) 환경변수를 설정하세요.',
        });
      }
      if (!hasPasswordLogin()) {
        return json(503, { error: 'password login not enabled' });
      }

      const ip = clientIp(req);
      const rl = rateLimit(`login:${ip}`, LOGIN_LIMIT, LOGIN_WINDOW_MS);
      if (!rl.ok) {
        return json(
          429,
          { error: 'too many attempts', retryAfter: rl.retryAfter },
          { 'retry-after': String(rl.retryAfter) }
        );
      }

      let body = null;
      try {
        body = await req.json();
      } catch (e) {
        return json(400, { error: 'invalid body' });
      }
      const password = body && typeof body.password === 'string' ? body.password : '';

      if (!verifyPassword(password)) {
        // 남은 시도 횟수만 알려주고, 비밀번호에 대한 힌트는 주지 않는다.
        return json(401, { error: 'invalid password', attemptsLeft: rl.remaining });
      }

      resetRateLimit(`login:${ip}`);
      const token = issueSessionToken();
      if (!token) return json(500, { error: 'session secret unavailable' });

      return json(
        200,
        { ok: true, expiresIn: sessionTtlSeconds() },
        { 'set-cookie': sessionCookie(req, token) }
      );
    }

    return json(405, { error: 'method not allowed' });
  } catch (e) {
    return json(500, { error: String((e && e.message) || e) });
  }
};
