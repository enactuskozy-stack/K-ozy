-- ═══════════════════════════════════════════════════════════════════════════
-- K-ozy 스키마 ④ RLS(행 수준 보안) · 권한
--
-- 지금 이 사이트는 Supabase 의 anon 키를 브라우저에서 쓰지 않는다. 모든 DB 접근은
-- Netlify Function 이 DATABASE_URL(서버 전용)로 직접 하고, 권한 판정은
-- netlify/shared/auth.mjs 가 한다. 그래도 RLS 를 켜 두는 이유:
--
--   · Supabase 프로젝트는 anon / service_role API 키가 항상 살아 있다. RLS 가 꺼진
--     테이블은 anon 키만 알아내면 PostgREST(https://<project>.supabase.co/rest/v1/…)
--     로 고객 이메일·여권번호·주소가 통째로 새어 나간다. 실수 하나가 곧 개인정보 유출이다.
--   · 나중에 브라우저에서 Supabase 클라이언트를 쓰게 되더라도 기본이 "차단"이어야 한다.
--
-- DATABASE_URL 로 붙는 postgres 역할은 BYPASSRLS 이므로 지금 동작에는 영향이 없다.
-- ═══════════════════════════════════════════════════════════════════════════

/* ────────────────── 1. 모든 테이블에 RLS 켜기 (정책 없음 = 전면 차단) ────────────────── */

alter table orders          enable row level security;
alter table feedback        enable row level security;
alter table feedback_photos enable row level security;
alter table admin_store     enable row level security;
alter table customers       enable row level security;
alter table schools         enable row level security;
alter table inventory_items enable row level security;
alter table email_log       enable row level security;
alter table settings        enable row level security;
alter table order_seq       enable row level security;
alter table payments        enable row level security;


/* ────────────────── 2. anon / authenticated 권한 회수 ──────────────────
   Supabase 는 public 스키마의 새 테이블·뷰에 anon, authenticated 권한을
   기본으로 부여한다. 여기서 전부 회수한 뒤 필요한 것만 다시 연다.        */

do $$
declare r record;
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    raise notice 'anon 역할이 없습니다(로컬 Postgres). 권한 회수를 건너뜁니다.';
    return;
  end if;

  for r in select tablename as rel from pg_tables where schemaname = 'public'
           union all
           select viewname  as rel from pg_views  where schemaname = 'public'
  loop
    execute format('revoke all on table public.%I from anon, authenticated', r.rel);
  end loop;

  for r in select sequencename as rel from pg_sequences where schemaname = 'public' loop
    execute format('revoke all on sequence public.%I from anon, authenticated', r.rel);
  end loop;
end $$;


/* ────────────────── 3. 공개로 열어 두는 것: 공개 설정 하나뿐 ──────────────────
   현장 이벤트 팝업 ON/OFF 는 비로그인 방문자도 읽어야 한다.
   (그 외 고객·주문·리뷰 원본은 절대 열지 않는다. 공개 리뷰는 이름을 마스킹하는
    Netlify Function 을 통해서만 나간다)                                     */

drop policy if exists settings_public_read on settings;
create policy settings_public_read on settings
  for select
  using (is_public);

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'grant usage on schema public to anon, authenticated';
    execute 'grant select on table public.settings to anon, authenticated';
    execute 'grant select on table public.public_settings_v to anon, authenticated';
  end if;
end $$;

comment on policy settings_public_read on settings is
  'is_public = true 인 설정만 비로그인 방문자에게 읽기 허용(이벤트 팝업 ON/OFF 등).';
