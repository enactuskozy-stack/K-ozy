-- ═══════════════════════════════════════════════════════════════════════════
--  K-ozy 데이터베이스 스키마 — 통합본 (전체 1개 파일)
--
--  Supabase → SQL Editor 에 이 파일 내용을 통째로 붙여넣고 한 번만 실행하세요.
--  나눠져 있던 5개 마이그레이션(0100~0500)을 순서대로 합친 것입니다.
--
--  ── 이 파일이 하는 일 ────────────────────────────────────────────────────
--   ① 주문·피드백·운영데이터 테이블을 정식 스키마로 고정하고, jsonb 안에 묻혀 있던
--      값을 조회 가능한 컬럼으로 끌어올린다 (자동 계산 컬럼이라 앱 수정 불필요)
--   ② 고객·학교·재고·메일이력·설정·주문번호·결제·첨부사진 테이블을 만든다
--   ③ admin_store 의 통짜 데이터를 위 테이블로 자동 반영하는 트리거 + 조회 뷰
--   ④ RLS(행 수준 보안) — anon 키로 고객 정보가 새지 않도록 전면 차단
--   ⑤ 이중 인코딩되어 저장된 jsonb 복구 (관리자 화면 리뷰 숨김 500 에러 해결)
--
--  ── 안전성 ──────────────────────────────────────────────────────────────
--   · 여러 번 실행해도 결과가 같습니다 (idempotent).
--   · 기존 orders / feedback / admin_store 데이터를 지우지 않습니다.
--     DROP 문은 전부 `drop trigger`·`drop policy` 이고, 바로 아래에서 다시 만듭니다.
--     DROP TABLE / DELETE / TRUNCATE 는 이 파일 어디에도 없습니다.
--   · 같은 이름의 테이블이 이미 있으면 모자란 컬럼만 채웁니다. 구조가 근본적으로
--     달라서 자동으로 못 고치는 경우에는 무엇을 어떻게 하면 되는지 알려주고 멈춥니다.
--   · 배포된 Netlify Function 코드를 고치지 않은 상태에서도 적용할 수 있습니다.
--
--  ── 실행 중 안내 ────────────────────────────────────────────────────────
--   · "Potential issues detected" 경고가 뜨면 [Run and enable RLS] 를 누르세요.
--   · 맨 마지막에 결과 요약 표가 나옵니다. 그걸로 정상 적용 여부를 확인하세요.
-- ═══════════════════════════════════════════════════════════════════════════




-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  [1/5]  20260806000100_kozy_core.sql
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- ═══════════════════════════════════════════════════════════════════════════
-- K-ozy 스키마 ① 코어 테이블 (orders / feedback / admin_store)
--
-- 이 파일은 "지금 배포되어 있는 Netlify Functions 가 런타임에 만드는 테이블"을
-- 정식 스키마로 고정하고, 브라우저가 이미 보내고 있지만 DB 에서는 jsonb 안에만
-- 묻혀 있던 값들을 조회 가능한 컬럼으로 끌어올린다.
--
-- ── 설계 원칙 ──────────────────────────────────────────────────────────────
--  1) 덧붙이기만 한다(additive). 기존 컬럼(id / order_no / status / rent_status /
--     data / created_at / updated_at, feedback.type, admin_store.key)은 그대로 두므로
--     지금 배포된 orders.mjs · feedback.mjs · admin-store.mjs 를 한 줄도 고치지 않아도
--     이 마이그레이션을 적용할 수 있다.
--  2) 새로 추가하는 컬럼은 전부 GENERATED ALWAYS AS ... STORED — 즉 data(jsonb)에서
--     자동으로 파생된다. 함수가 INSERT/UPDATE 할 때 이 컬럼들을 몰라도 값이 채워진다.
--     (application 이 값을 따로 써 넣을 필요가 없다 → 코드 변경 없이 즉시 유효)
--  3) 날짜·숫자 캐스팅은 실패해도 NULL 을 돌려주는 헬퍼로 감싼다. 고객이 보낸 문자열
--     하나가 잘못돼서 주문 저장 전체가 실패하는 일이 없어야 한다.
--
-- 적용: Supabase → SQL Editor 에 이 파일부터 번호 순서대로 붙여넣고 실행.
--       (모두 idempotent — 여러 번 실행해도 안전)
-- ═══════════════════════════════════════════════════════════════════════════

/* ────────────────── 0. 공통 헬퍼 ────────────────── */
-- 생성 컬럼(GENERATED)에 쓰려면 IMMUTABLE 이어야 한다.
-- 값이 깨져 있으면 예외를 던지지 않고 NULL 을 돌려준다.

create or replace function kz_date(t text) returns date
language plpgsql immutable as $$
begin
  if t is null then return null; end if;
  t := btrim(t);
  if t = '' then return null; end if;
  return substr(t, 1, 10)::date;   -- 'YYYY-MM-DD' 또는 ISO 문자열의 앞 10자
exception when others then
  return null;
end $$;
comment on function kz_date(text) is '문자열 → date. 파싱 실패 시 NULL (생성 컬럼용)';

create or replace function kz_ts(t text) returns timestamptz
language plpgsql immutable as $$
begin
  if t is null then return null; end if;
  t := btrim(t);
  if t = '' then return null; end if;
  return t::timestamptz;
exception when others then
  return null;
end $$;
comment on function kz_ts(text) is '문자열 → timestamptz. 파싱 실패 시 NULL (생성 컬럼용)';

create or replace function kz_num(t text) returns numeric
language plpgsql immutable as $$
begin
  if t is null then return null; end if;
  t := btrim(t);
  if t = '' then return null; end if;
  return t::numeric;
exception when others then
  return null;
end $$;
comment on function kz_num(text) is '문자열 → numeric. 파싱 실패 시 NULL (생성 컬럼용)';

create or replace function kz_int(t text) returns integer
language plpgsql immutable as $$
declare n numeric;
begin
  n := kz_num(t);
  if n is null then return null; end if;
  return round(n)::integer;
exception when others then
  return null;
end $$;
comment on function kz_int(text) is '문자열 → integer(반올림). 파싱 실패 시 NULL (생성 컬럼용)';

create or replace function kz_bool(t text) returns boolean
language plpgsql immutable as $$
begin
  if t is null then return null; end if;
  t := lower(btrim(t));
  if t in ('true','t','1','y','yes','on')  then return true;  end if;
  if t in ('false','f','0','n','no','off') then return false; end if;
  return null;
end $$;
comment on function kz_bool(text) is '문자열 → boolean. 판단 불가 시 NULL (생성 컬럼용)';

-- updated_at 자동 갱신
create or replace function kz_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;


/* ────────────────── 1. orders — 주문(이불·유심·세면용품) ──────────────────
   현재 저장 경로
     · 고객 신청(공개)        POST /orders  (단건)  → INSERT 전용
     · 관리자 일괄 동기화     POST /orders  (배열)  → id 기준 upsert
     · 이벤트 팝업(부스 접수) POST /orders  (단건)  → kind: bedding|sim|amenity
   data(jsonb) 가 원본이고, 아래 컬럼은 전부 거기서 파생된다.                       */

create table if not exists orders (
  id          text primary key,
  order_no    text,
  status      text,
  rent_status text,
  data        jsonb not null,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- 주문 종류 — 화면에서 세 탭으로 갈라지는 기준. 값이 없으면 이불 렌탈.
alter table orders add column if not exists kind text
  generated always as (lower(coalesce(nullif(btrim(data->>'kind'), ''), 'bedding'))) stored;

-- 접수 채널: W(웹) / B(현장 부스).
-- ※ 지금은 공개 POST 가 서버에서 'W' 로 고정되어 부스 접수(B)가 웹으로 기록된다.
--    → netlify/functions/orders.mjs 의 sanitizePublicOrder 수정이 필요하다(README 참고).
alter table orders add column if not exists channel text
  generated always as (upper(nullif(btrim(data->>'channel'), ''))) stored;

-- 유입 경로 (예: 'event-popup')
alter table orders add column if not exists source text
  generated always as (nullif(btrim(data->>'source'), '')) stored;

alter table orders add column if not exists customer_name text
  generated always as (nullif(btrim(data->>'name'), '')) stored;

alter table orders add column if not exists customer_email text
  generated always as (lower(nullif(btrim(data->>'email'), ''))) stored;

alter table orders add column if not exists customer_phone text
  generated always as (nullif(btrim(data->>'phone'), '')) stored;

alter table orders add column if not exists nationality text
  generated always as (nullif(btrim(data->>'nationality'), '')) stored;

alter table orders add column if not exists instagram text
  generated always as (nullif(btrim(data->>'instagram'), '')) stored;

alter table orders add column if not exists school text
  generated always as (nullif(btrim(data->>'school'), '')) stored;

alter table orders add column if not exists package text
  generated always as (nullif(btrim(data->>'package'), '')) stored;

alter table orders add column if not exists duration text
  generated always as (nullif(btrim(data->>'duration'), '')) stored;

alter table orders add column if not exists extend_months integer
  generated always as (kz_int(data->>'extendMonths')) stored;

alter table orders add column if not exists start_date date
  generated always as (kz_date(data->>'startDate')) stored;

alter table orders add column if not exists end_date date
  generated always as (kz_date(data->>'endDate')) stored;

alter table orders add column if not exists submitted_at timestamptz
  generated always as (kz_ts(data->>'submittedAt')) stored;

alter table orders add column if not exists amount_krw numeric(12,2)
  generated always as (kz_num(data->>'amountKRW')) stored;

alter table orders add column if not exists rent_auto boolean
  generated always as (kz_bool(data->>'rentAuto')) stored;

alter table orders add column if not exists lang text
  generated always as (lower(nullif(btrim(data->>'lang'), ''))) stored;

-- 배송지 (이불 렌탈)
alter table orders add column if not exists postal_code text
  generated always as (nullif(btrim(data->>'postalCode'), '')) stored;

alter table orders add column if not exists address1 text
  generated always as (nullif(btrim(data->>'address1'), '')) stored;

alter table orders add column if not exists building text
  generated always as (nullif(btrim(data->>'building'), '')) stored;

-- 유심(kind='sim')
alter table orders add column if not exists sim_plan text
  generated always as (nullif(btrim(data->>'simPlan'), '')) stored;

alter table orders add column if not exists sim_price_krw numeric(12,2)
  generated always as (kz_num(data->>'simPrice')) stored;

-- 세면용품(kind='amenity')
alter table orders add column if not exists amn_qty integer
  generated always as (kz_int(data->>'amnQty')) stored;

-- 유심·세면용품 진행 상태 (new / paid / issued|handed / cancelled)
alter table orders add column if not exists evt_status text
  generated always as (lower(nullif(btrim(data->>'evtStatus'), ''))) stored;

-- 개인정보·약관 동의
alter table orders add column if not exists consent_privacy boolean
  generated always as (kz_bool(data->>'consentPrivacy')) stored;

alter table orders add column if not exists consent_terms boolean
  generated always as (kz_bool(data->>'consentTerms')) stored;

alter table orders add column if not exists consent_at timestamptz
  generated always as (kz_ts(data->>'consentAt')) stored;

-- 동의를 어떻게 받았는가.
--   checkbox = 현장 팝업의 필수 동의 체크박스 (consent_privacy/consent_terms 가 함께 찬다)
--   notice   = 웹 신청 폼의 개인정보 고지문 (명시적 동의가 아니므로 위 두 컬럼은 NULL)
alter table orders add column if not exists consent_method text
  generated always as (lower(nullif(btrim(data->>'consentMethod'), ''))) stored;

comment on table  orders             is 'K-ozy 주문. data(jsonb)가 원본이고 나머지 컬럼은 전부 거기서 파생(GENERATED)된다.';
comment on column orders.kind        is 'bedding | sim | amenity — 관리자 화면 탭 분류 기준';
comment on column orders.channel     is 'W = 웹 접수, B = 현장 부스 접수';
comment on column orders.consent_privacy is '개인정보 수집·이용 동의. 브라우저가 data.consentPrivacy 를 보내면 자동 기록된다.';

create index if not exists orders_kind_idx           on orders (kind);
create index if not exists orders_channel_idx        on orders (channel);
create index if not exists orders_email_idx          on orders (customer_email);
create index if not exists orders_school_idx         on orders (school);
create index if not exists orders_rent_status_idx    on orders (rent_status);
create index if not exists orders_status_idx         on orders (status);
create index if not exists orders_end_date_idx       on orders (end_date);
create index if not exists orders_created_at_idx     on orders (created_at);
create index if not exists orders_evt_status_idx     on orders (evt_status) where evt_status is not null;
create index if not exists orders_order_no_idx       on orders (order_no) where order_no is not null;
create index if not exists orders_data_gin           on orders using gin (data jsonb_path_ops);

-- 주문번호 중복 감시.
-- 지금은 브라우저가 주문번호를 매기므로(기기 두 대가 동시에 접수하면 같은 번호가 나온다)
-- UNIQUE 를 바로 걸면 적용이 실패할 수 있다. ③ 파일의 kz_next_order_no() 로 발번을
-- 옮긴 뒤, 아래 쿼리로 중복이 0건인지 확인하고 UNIQUE 로 승격할 것.
--   select order_no, count(*) from orders where coalesce(order_no,'') <> ''
--    group by 1 having count(*) > 1;
--   create unique index orders_order_no_uq on orders (order_no)
--    where coalesce(order_no,'') <> '';

drop trigger if exists orders_touch on orders;
create trigger orders_touch before update on orders
  for each row execute function kz_touch();


/* ────────────────── 2. feedback — 만족도 리뷰 / 이슈 보고 ────────────────── */

create table if not exists feedback (
  id         text primary key,
  type       text not null,
  data       jsonb not null,
  created_at timestamptz default now()
);

alter table feedback add column if not exists updated_at timestamptz default now();

alter table feedback add column if not exists customer_name text
  generated always as (nullif(btrim(data->>'name'), '')) stored;

alter table feedback add column if not exists customer_email text
  generated always as (lower(nullif(btrim(data->>'email'), ''))) stored;

-- 관리자가 숨긴 리뷰는 공개 목록에서 빠진다 (PUT /feedback 이 data.hidden 을 갱신)
alter table feedback add column if not exists hidden boolean
  generated always as (coalesce(kz_bool(data->>'hidden'), false)) stored;

alter table feedback add column if not exists star smallint
  generated always as (kz_int(data->>'starRating')::smallint) stored;

alter table feedback add column if not exists q1 smallint
  generated always as (kz_int(data->>'q1')::smallint) stored;
alter table feedback add column if not exists q2 smallint
  generated always as (kz_int(data->>'q2')::smallint) stored;
alter table feedback add column if not exists q3 smallint
  generated always as (kz_int(data->>'q3')::smallint) stored;
alter table feedback add column if not exists q4 smallint
  generated always as (kz_int(data->>'q4')::smallint) stored;

alter table feedback add column if not exists recommend text
  generated always as (nullif(btrim(data->>'recommend'), '')) stored;

alter table feedback add column if not exists user_type text
  generated always as (nullif(btrim(data->>'userType'), '')) stored;

alter table feedback add column if not exists lang text
  generated always as (lower(nullif(btrim(data->>'lang'), ''))) stored;

alter table feedback add column if not exists submitted_at timestamptz
  generated always as (kz_ts(data->>'submittedAt')) stored;

-- 이슈 보고 전용
alter table feedback add column if not exists severity text
  generated always as (lower(nullif(btrim(data->>'severity'), ''))) stored;

alter table feedback add column if not exists issue_types text
  generated always as (nullif(btrim(data->>'issueTypes'), '')) stored;

alter table feedback add column if not exists issue_date date
  generated always as (kz_date(data->>'issueDate')) stored;

alter table feedback add column if not exists resolved_at timestamptz
  generated always as (kz_ts(data->>'resolvedAt')) stored;

-- 첨부 사진 장수 (원본 base64 는 data.photos 안에 있다 — ② 파일 feedback_photos 참고)
alter table feedback add column if not exists photo_count smallint
  generated always as (
    (case when jsonb_typeof(data->'photos') = 'array'
          then jsonb_array_length(data->'photos') else 0 end)::smallint
  ) stored;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'feedback_type_chk') then
    alter table feedback add constraint feedback_type_chk
      check (type in ('satisfaction', 'issue'));
  end if;
end $$;

comment on table  feedback        is '고객 만족도 리뷰(satisfaction) / 이슈 보고(issue). data(jsonb)가 원본.';
comment on column feedback.hidden is '관리자가 숨김 처리한 리뷰. 공개 목록(?public=1)에서 제외된다.';

create index if not exists feedback_type_created_idx on feedback (type, created_at desc);
create index if not exists feedback_public_idx       on feedback (created_at desc)
  where type = 'satisfaction' and hidden = false;
create index if not exists feedback_email_idx        on feedback (customer_email);
create index if not exists feedback_star_idx         on feedback (star);
create index if not exists feedback_severity_idx     on feedback (severity) where type = 'issue';
create index if not exists feedback_data_gin         on feedback using gin (data jsonb_path_ops);

drop trigger if exists feedback_touch on feedback;
create trigger feedback_touch before update on feedback
  for each row execute function kz_touch();


/* ────────────────── 3. admin_store — 운영 데이터 원본(키-값 blob) ──────────────────
   customers / schools / emails / inventory / flags 를 통째로 한 행에 넣는다.
   ③ 파일의 팬아웃 트리거가 이 blob 을 정규화 테이블로 풀어 준다.                      */

create table if not exists admin_store (
  key        text primary key,
  data       jsonb not null,
  updated_at timestamptz default now()
);

comment on table admin_store is
  '관리자 운영 데이터 원본(배열/객체 통째 저장). 정규화된 사본은 customers/schools/inventory_items/email_log/settings 에 자동 반영된다.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  [2/5]  20260806000200_kozy_admin_domain.sql
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- ═══════════════════════════════════════════════════════════════════════════
-- K-ozy 스키마 ② 운영 도메인 테이블
--
-- 지금은 고객·학교·재고·메일 이력·설정 플래그가 admin_store 한 테이블에
-- "배열 통째로" 들어간다(key='customers' 한 행에 고객 전체). 그래서
--   · 두 관리자가 같은 시간에 저장하면 나중 저장이 앞의 변경을 통째로 덮어쓴다
--   · 고객 1명만 조회/수정하는 쿼리를 쓸 수 없고, 정렬·검색·집계도 못 한다
--   · 관리자가 "내역 비우기"를 누르면 메일 발송 이력이 영구히 사라진다
--   · 2MB 본문 제한에 걸리면 그 시점부터 저장 자체가 실패한다
-- 이 파일은 그 데이터가 들어갈 정식 테이블을 만든다.
-- (admin_store → 이 테이블들로의 자동 반영은 ③ 파일의 트리거가 담당한다)
--
-- ── 같은 이름의 테이블이 이미 있는 경우 ────────────────────────────────────
-- `create table if not exists` 는 테이블이 이미 있으면 **통째로 건너뛴다.**
-- 그래서 구조가 다른 테이블이 이미 있으면 그 다음 문장부터 컬럼이 없다고 실패한다.
--   예) ERROR: column "auto" of relation "customers" does not exist
-- 이를 막기 위해 각 테이블마다 `create table` 뒤에 컬럼별
-- `alter table ... add column if not exists` 를 붙였다. 새 DB 에서는 전부 no-op 이고,
-- 기존 테이블이 있으면 모자란 컬럼만 채워 넣는다.
-- 기본키 타입까지 다른 경우는 자동으로 고칠 수 없으므로 아래 0번에서 먼저 확인한다.
-- ═══════════════════════════════════════════════════════════════════════════


/* ────────────────── 0. 충돌 사전 점검 ──────────────────
   같은 이름의 테이블이 이미 있는데 기본키가 호환되지 않으면, 여기서 무슨 일이
   벌어지는지 알려주고 멈춘다(엉뚱한 테이블에 컬럼을 덧붙이지 않기 위해). */

do $$
declare
  r        record;
  actual   text;
  coldef   text;
  isident  text;
  hint     text;
begin
  hint := E'  K-ozy 가 쓰는 테이블이 아닐 가능성이 큽니다. 다음 중 하나를 하세요.\n'
          '   1) 안 쓰는 테이블이면  →  drop table public.%1$I cascade;  실행 후 이 파일을 다시 실행\n'
          '   2) 쓰는 테이블이면    →  alter table public.%1$I rename to %1$I_old;  로 비켜 둔 뒤 다시 실행\n'
          '  (기존 데이터는 이 마이그레이션이 건드리지 않습니다)';

  /* ── (1) 문자열 키를 쓰는 테이블 ── */
  for r in
    select * from (values
      ('customers',       'id',          'text'),
      ('schools',         'name',        'text'),
      ('inventory_items', 'id',          'text'),
      ('settings',        'key',         'text'),
      ('order_seq',       'key',         'text'),
      ('payments',        'order_no',    'text'),
      ('feedback_photos', 'feedback_id', 'text')
    ) as t(tbl, col, typ)
  loop
    -- 테이블이 없으면 아래에서 새로 만들면 되므로 통과
    if not exists (
      select 1 from information_schema.tables
       where table_schema = 'public' and table_name = r.tbl
    ) then
      continue;
    end if;

    select data_type into actual
      from information_schema.columns
     where table_schema = 'public' and table_name = r.tbl and column_name = r.col;

    if actual is null then
      raise exception E'이미 있는 "%" 테이블에 "%" 컬럼이 없습니다.\n%',
        r.tbl, r.col, format(hint, r.tbl);
    end if;

    if actual <> r.typ then
      raise exception E'이미 있는 "%" 테이블의 "%" 컬럼 타입이 %(기대값: %)입니다.\n%',
        r.tbl, r.col, actual, r.typ, format(hint, r.tbl);
    end if;
  end loop;

  /* ── (2) 자동 증가 id 를 쓰는 테이블 ──
     id 가 있어도 시퀀스(bigserial)나 identity 가 아니면 INSERT 때 id 가 NULL 이 되어
     "null value in column id violates not-null constraint" 로 실패한다. */
  for r in
    select * from (values ('email_log'), ('payments'), ('feedback_photos')) as t(tbl)
  loop
    if not exists (
      select 1 from information_schema.tables
       where table_schema = 'public' and table_name = r.tbl
    ) then
      continue;
    end if;

    select data_type, column_default, is_identity
      into actual, coldef, isident
      from information_schema.columns
     where table_schema = 'public' and table_name = r.tbl and column_name = 'id';

    if actual is null then
      raise exception E'이미 있는 "%" 테이블에 "id" 컬럼이 없습니다.\n%',
        r.tbl, format(hint, r.tbl);
    end if;

    if actual not in ('bigint', 'integer', 'smallint') then
      raise exception E'이미 있는 "%" 테이블의 "id" 컬럼 타입이 %(기대값: bigint 자동 증가)입니다.\n%',
        r.tbl, actual, format(hint, r.tbl);
    end if;

    if coldef is null and coalesce(isident, 'NO') <> 'YES' then
      raise exception
        E'이미 있는 "%" 테이블의 "id" 에 자동 증가(시퀀스)가 없습니다.\n'
        '  이대로 두면 이 테이블에 INSERT 할 때 id 가 비어서 실패합니다.\n%',
        r.tbl, format(hint, r.tbl);
    end if;
  end loop;
end $$;


/* ────────────────── 1. customers — 고객 ──────────────────
   렌탈 신청이 들어오면 이메일 기준으로 자동 등록되고(auto=true),
   관리자가 직접 추가할 수도 있다.                                        */

create table if not exists customers (
  id          text primary key,               -- 'C' + timestamp (브라우저 생성)
  name        text,
  gender      text,
  nationality text,
  school      text,
  email       text,
  insta       text,                           -- 인스타그램 아이디
  depart      text,                           -- 출국(퇴사) 예정
  auto        boolean not null default false, -- 렌탈 신청에서 자동 등록된 고객인가
  note        text,
  data        jsonb  not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz                     -- 관리자 삭제(주문 기록은 유지 → soft delete)
);

-- 이미 있던 테이블이면 모자란 컬럼만 채운다 (새 DB 에서는 전부 no-op)
alter table customers add column if not exists name        text;
alter table customers add column if not exists gender      text;
alter table customers add column if not exists nationality text;
alter table customers add column if not exists school      text;
alter table customers add column if not exists email       text;
alter table customers add column if not exists insta       text;
alter table customers add column if not exists depart      text;
alter table customers add column if not exists auto        boolean not null default false;
alter table customers add column if not exists note        text;
alter table customers add column if not exists data        jsonb not null default '{}'::jsonb;
alter table customers add column if not exists created_at  timestamptz not null default now();
alter table customers add column if not exists updated_at  timestamptz not null default now();
alter table customers add column if not exists deleted_at  timestamptz;

comment on table  customers            is '고객 마스터. 주문(orders)과는 이메일로 느슨하게 연결된다.';
comment on column customers.auto       is 'true = 렌탈 신청에서 자동 생성, false = 관리자가 직접 등록';
comment on column customers.deleted_at is '관리자 삭제 시각. 주문 이력 보존을 위해 행은 남긴다.';

create index if not exists customers_email_idx  on customers (lower(email));
create index if not exists customers_school_idx on customers (school) where deleted_at is null;
create index if not exists customers_live_idx   on customers (name)   where deleted_at is null;
-- 이메일은 앱에서 사실상 고유키로 쓰인다. 기존 데이터에 중복이 없는지 확인한 뒤 승격할 것.
--   select lower(email), count(*) from customers where deleted_at is null
--    and coalesce(email,'') <> '' group by 1 having count(*) > 1;
--   create unique index customers_email_uq on customers (lower(email))
--    where deleted_at is null and coalesce(email,'') <> '';

drop trigger if exists customers_touch on customers;
create trigger customers_touch before update on customers
  for each row execute function kz_touch();


/* ────────────────── 2. schools — 학교 / 공통 반납일 ──────────────────
   학교를 고르면 우편번호·주소가 자동 입력되고, 학교별 고정 반납일이
   신청서의 반납예정일로 들어간다.                                        */

create table if not exists schools (
  name        text primary key,
  return_date date,                -- 학교 공통 반납일
  postal_code text,
  address1    text,
  active      boolean not null default true,
  data        jsonb  not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz
);

alter table schools add column if not exists return_date date;
alter table schools add column if not exists postal_code text;
alter table schools add column if not exists address1    text;
alter table schools add column if not exists active      boolean not null default true;
alter table schools add column if not exists data        jsonb not null default '{}'::jsonb;
alter table schools add column if not exists created_at  timestamptz not null default now();
alter table schools add column if not exists updated_at  timestamptz not null default now();
alter table schools add column if not exists deleted_at  timestamptz;

comment on table schools is '학교 디렉터리(주소·우편번호)와 학교별 공통 반납일.';

create index if not exists schools_live_idx on schools (name) where deleted_at is null;

drop trigger if exists schools_touch on schools;
create trigger schools_touch before update on schools
  for each row execute function kz_touch();


/* ────────────────── 3. inventory_items — 품목 단위 재고 ──────────────────
   솜이불/매트리스 시트/토퍼/베개솜/베개커버를 낱개로 관리하고,
   대여 중·예약 주문 수를 빼서 가용 수량을 계산한다(뷰는 ③ 파일).        */

create table if not exists inventory_items (
  id         text primary key,               -- 'INV-<ts>-<rand>'
  type       text not null,                  -- comforter | mattress_sheet | topper | pillow_inner | pillow_cover
  label      text,                           -- 재고 번호 스티커 (CB-001 …)
  grade      text not null default 'A',      -- A(상) / B(중) / C(하)
  note       text,
  created_on date,                           -- 등록일(관리자 화면 표시용)
  retired_at timestamptz,                    -- 폐기·교체 시각
  data       jsonb  not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

-- type 은 NOT NULL 이지만 기본값이 없다. 기존 테이블에 행이 있으면 NOT NULL 로 못 붙이므로
-- 여기서는 컬럼만 추가한다(새로 만들 때는 위 create 문이 NOT NULL 을 건다).
alter table inventory_items add column if not exists type       text;
alter table inventory_items add column if not exists label      text;
alter table inventory_items add column if not exists grade      text not null default 'A';
alter table inventory_items add column if not exists note       text;
alter table inventory_items add column if not exists created_on date;
alter table inventory_items add column if not exists retired_at timestamptz;
alter table inventory_items add column if not exists data       jsonb not null default '{}'::jsonb;
alter table inventory_items add column if not exists created_at timestamptz not null default now();
alter table inventory_items add column if not exists updated_at timestamptz not null default now();
alter table inventory_items add column if not exists deleted_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'inventory_items_type_chk') then
    alter table inventory_items add constraint inventory_items_type_chk
      check (type in ('comforter','mattress_sheet','topper','pillow_inner','pillow_cover'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'inventory_items_grade_chk') then
    alter table inventory_items add constraint inventory_items_grade_chk
      check (grade in ('A','B','C'));
  end if;
end $$;

comment on table  inventory_items       is '낱개 단위 재고. 풀세트(구성 A)는 5품목, 구성 B는 토퍼 제외 4품목.';
comment on column inventory_items.grade is 'A 상(새것 같음) / B 중(사용감) / C 하(교체 임박)';

create index if not exists inventory_type_idx  on inventory_items (type) where deleted_at is null;
create index if not exists inventory_grade_idx on inventory_items (type, grade) where deleted_at is null;
create unique index if not exists inventory_label_uq on inventory_items (label)
  where deleted_at is null and coalesce(label,'') <> '';

drop trigger if exists inventory_items_touch on inventory_items;
create trigger inventory_items_touch before update on inventory_items
  for each row execute function kz_touch();


/* ────────────────── 4. email_log — 안내 메일 발송 이력 ──────────────────
   예약완료 → 대여 시작 → 반납 예정 → 반납 완료 4단계 안내 메일.
   지금은 관리자 화면의 배열 하나라서 "내역 비우기"를 누르면 사라지고,
   실제로 보냈는지(Gmail 작성창을 열었을 뿐인지) 구분도 없다.
   이 테이블은 append-only 로 쌓고 상태를 따로 들고 간다.                */

create table if not exists email_log (
  id            bigserial primary key,
  sent_at       timestamptz,                 -- 대기열에 올라간 시각(한국시간 문자열을 변환)
  sent_at_text  text,                        -- 원본 문자열 'YYYY-MM-DD HH:MM'
  kind          text,                        -- reserved | renting | due | returned | (수동)
  to_email      text,
  customer_name text,
  order_no      text,
  subject       text,
  body          text,
  status        text not null default 'queued',  -- queued | opened | sent | failed
  error         text,
  fingerprint   text,                        -- 같은 메일이 두 번 들어오는 것 방지(아래 unique 인덱스)
  data          jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

alter table email_log add column if not exists sent_at       timestamptz;
alter table email_log add column if not exists sent_at_text  text;
alter table email_log add column if not exists kind          text;
alter table email_log add column if not exists to_email      text;
alter table email_log add column if not exists customer_name text;
alter table email_log add column if not exists order_no      text;
alter table email_log add column if not exists subject       text;
alter table email_log add column if not exists body          text;
alter table email_log add column if not exists status        text not null default 'queued';
alter table email_log add column if not exists error         text;
alter table email_log add column if not exists fingerprint   text;
alter table email_log add column if not exists data          jsonb not null default '{}'::jsonb;
alter table email_log add column if not exists created_at    timestamptz not null default now();

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'email_log_status_chk') then
    alter table email_log add constraint email_log_status_chk
      check (status in ('queued','opened','sent','failed'));
  end if;
end $$;

comment on table  email_log        is '안내 메일 이력(append-only). 관리자 화면에서 목록을 비워도 여기 기록은 남는다.';
comment on column email_log.status is 'queued=대기열 등록, opened=Gmail 작성창 열림, sent=발송 확인, failed=실패';

-- ③ 파일의 팬아웃이 `on conflict (fingerprint)` 를 쓰므로 반드시 있어야 한다
create unique index if not exists email_log_fingerprint_uq on email_log (fingerprint);
create index if not exists email_log_order_idx   on email_log (order_no);
create index if not exists email_log_kind_idx    on email_log (order_no, kind);
create index if not exists email_log_sent_at_idx on email_log (sent_at desc nulls last);
create index if not exists email_log_to_idx      on email_log (lower(to_email));


/* ────────────────── 5. settings — 사이트 설정 플래그 ──────────────────
   현장 이벤트 팝업 ON/OFF, 환율, 마이그레이션 플래그 등.
   is_public = true 인 항목만 비로그인 방문자에게 노출한다.               */

create table if not exists settings (
  key         text primary key,
  value       jsonb not null,
  is_public   boolean not null default false,
  description text,
  updated_at  timestamptz not null default now()
);

alter table settings add column if not exists value       jsonb;
alter table settings add column if not exists is_public   boolean not null default false;
alter table settings add column if not exists description text;
alter table settings add column if not exists updated_at  timestamptz not null default now();

comment on table  settings           is '사이트 설정. admin_store 의 flags 와 자동 동기화된다.';
comment on column settings.is_public is 'true 면 로그인하지 않은 방문자도 값을 읽을 수 있다(예: 이벤트 팝업 ON/OFF).';

insert into settings (key, value, is_public, description) values
  ('kozy_event_popup', 'false'::jsonb, true,  '현장 이벤트 팝업 노출 여부. 공개 화면이 읽어야 하므로 is_public.'),
  ('kozy_fx',          '1400'::jsonb,  true,  'USD → KRW 환산 환율'),
  ('kozy_seq_map',     '{}'::jsonb,    false, '(구) 브라우저 주문번호 카운터. kz_next_order_no() 로 이관 예정')
on conflict (key) do nothing;

drop trigger if exists settings_touch on settings;
create trigger settings_touch before update on settings
  for each row execute function kz_touch();


/* ────────────────── 6. order_seq — 주문번호 발번 ──────────────────
   주문번호 W-26FW-003 = 채널(W/B) - 연도+학기(SS/FW) - 접수순서.
   지금은 브라우저가 카운터를 들고 있어서 기기 두 대가 동시에 접수하면
   같은 번호가 나온다. 채번을 DB 로 옮겨 원자적으로 증가시킨다.
   (발번 함수 kz_next_order_no 는 ③ 파일)                                */

create table if not exists order_seq (
  key        text primary key,            -- 'W-26FW'
  n          integer not null default 0,
  updated_at timestamptz not null default now()
);

alter table order_seq add column if not exists n          integer not null default 0;
alter table order_seq add column if not exists updated_at timestamptz not null default now();

comment on table order_seq is '채널·학기별 주문번호 카운터. kz_next_order_no() 로만 증가시킨다.';


/* ────────────────── 7. payments — 결제 / 정산 ──────────────────
   지금은 주문 한 건의 총액(amountKRW)만 있고, 실제로 얼마가 언제 어떤 수단으로
   들어왔는지 기록할 곳이 없다. (orders.mjs 의 ADMIN_ONLY_FIELDS 에 payments·paid·
   settled·refund 가 이미 예약되어 있지만 저장 구조가 없었다)              */

create table if not exists payments (
  id           bigserial primary key,
  order_id     text references orders(id) on delete set null,
  order_no     text,                        -- 주문이 삭제돼도 회계 기록은 남는다
  method       text,                        -- paypal | bank | cash | card | other
  amount_krw   numeric(12,2) not null default 0,
  currency     text not null default 'KRW',
  status       text not null default 'pending', -- pending | paid | refunded | failed | cancelled
  paid_at      timestamptz,
  refunded_at  timestamptz,
  external_ref text,                        -- PayPal 거래 ID, 입금자명 등
  memo         text,
  data         jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

alter table payments add column if not exists order_id     text;
alter table payments add column if not exists order_no     text;
alter table payments add column if not exists method       text;
alter table payments add column if not exists amount_krw   numeric(12,2) not null default 0;
alter table payments add column if not exists currency     text not null default 'KRW';
alter table payments add column if not exists status       text not null default 'pending';
alter table payments add column if not exists paid_at      timestamptz;
alter table payments add column if not exists refunded_at  timestamptz;
alter table payments add column if not exists external_ref text;
alter table payments add column if not exists memo         text;
alter table payments add column if not exists data         jsonb not null default '{}'::jsonb;
alter table payments add column if not exists created_at   timestamptz not null default now();
alter table payments add column if not exists updated_at   timestamptz not null default now();

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'payments_status_chk') then
    alter table payments add constraint payments_status_chk
      check (status in ('pending','paid','refunded','failed','cancelled'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payments_method_chk') then
    alter table payments add constraint payments_method_chk
      check (method is null or method in ('paypal','bank','cash','card','other'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payments_order_id_fkey') then
    alter table payments add constraint payments_order_id_fkey
      foreign key (order_id) references orders(id) on delete set null;
  end if;
end $$;

comment on table payments is '주문별 입·출금 기록. 한 주문에 여러 건(부분 결제·환불)이 붙을 수 있다.';

create index if not exists payments_order_idx    on payments (order_id);
create index if not exists payments_order_no_idx on payments (order_no);
create index if not exists payments_status_idx   on payments (status);
create index if not exists payments_paid_at_idx  on payments (paid_at desc nulls last);
create unique index if not exists payments_external_ref_uq on payments (external_ref)
  where external_ref is not null;

drop trigger if exists payments_touch on payments;
create trigger payments_touch before update on payments
  for each row execute function kz_touch();


/* ────────────────── 8. feedback_photos — 리뷰/이슈 첨부 사진 ──────────────────
   지금은 base64 data URL 이 feedback.data 안에 그대로 들어간다(1건 최대 3MB).
   행이 비대해지고 관리자 목록 조회가 통째로 무거워지므로 사진만 분리한다.
   나중에 Supabase Storage 로 옮길 때는 storage_path 만 채우면 된다.       */

create table if not exists feedback_photos (
  id             bigserial primary key,
  feedback_id    text not null references feedback(id) on delete cascade,
  idx            smallint not null,          -- 0,1,2 (건당 최대 3장)
  thumb_data_url text,                       -- 목록·카드용 썸네일
  full_data_url  text,                       -- 원본 (Storage 이관 시 NULL 로 비운다)
  storage_path   text,                       -- 예: 'feedback/<id>/0.jpg'
  content_type   text,
  bytes          integer,
  created_at     timestamptz not null default now()
);

alter table feedback_photos add column if not exists feedback_id    text;
alter table feedback_photos add column if not exists idx            smallint;
alter table feedback_photos add column if not exists thumb_data_url text;
alter table feedback_photos add column if not exists full_data_url  text;
alter table feedback_photos add column if not exists storage_path   text;
alter table feedback_photos add column if not exists content_type   text;
alter table feedback_photos add column if not exists bytes          integer;
alter table feedback_photos add column if not exists created_at     timestamptz not null default now();

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'feedback_photos_feedback_id_fkey') then
    alter table feedback_photos add constraint feedback_photos_feedback_id_fkey
      foreign key (feedback_id) references feedback(id) on delete cascade;
  end if;
end $$;

comment on table feedback_photos is
  '리뷰·이슈 첨부 사진. feedback.data->photos 를 kz_backfill_feedback_photos() 로 복사해 채운다.';

-- ③ 파일의 백필이 `on conflict (feedback_id, idx)` 를 쓰므로 반드시 있어야 한다
create unique index if not exists feedback_photos_fid_idx_uq on feedback_photos (feedback_id, idx);
create index if not exists feedback_photos_fid_idx on feedback_photos (feedback_id);


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  [3/5]  20260806000300_kozy_sync_and_views.sql
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- ═══════════════════════════════════════════════════════════════════════════
-- K-ozy 스키마 ③ 동기화 · 발번 · 조회 뷰
--
--  (1) admin_store(blob) → customers / schools / inventory_items / email_log /
--      settings 자동 반영 트리거
--        → 브라우저와 Netlify Function 을 한 줄도 고치지 않아도, 지금 이 순간부터
--          운영 데이터가 정규화된 테이블에도 함께 쌓인다.
--  (2) 주문번호 원자적 발번 함수 (브라우저 카운터의 중복 번호 문제 해결)
--  (3) 관리자 화면이 JS 로 계산하던 것(재고 가용수량·리뷰 집계·미수금)을
--      그대로 옮긴 조회 뷰
-- ═══════════════════════════════════════════════════════════════════════════

/* ══════════ 0. 이 파일이 의존하는 유니크 인덱스 보장 ══════════
   아래 팬아웃·백필은 `on conflict (...)` 를 쓰는데, 대상 컬럼에 유니크 인덱스가 없으면
     ERROR: there is no unique or exclusion constraint matching the ON CONFLICT specification
   로 실패한다. ② 를 건너뛰었거나 예전 버전으로 실행했거나, 같은 이름의 테이블이 이미
   있어서 인덱스만 빠진 경우가 있으므로 여기서 직접 확인하고 없으면 만든다.            */

do $$
declare
  r    record;
  n    integer;
  idx  text;
begin
  for r in
    select * from (values
      ('email_log',       'email_log_fingerprint_uq',   'fingerprint'),
      ('feedback_photos', 'feedback_photos_fid_idx_uq', 'feedback_id, idx')
    ) as t(tbl, idxname, cols)
  loop
    if not exists (
      select 1 from information_schema.tables
       where table_schema = 'public' and table_name = r.tbl
    ) then
      raise exception E'"%" 테이블이 없습니다. ② (20260806000200_kozy_admin_domain.sql) 를 먼저 실행하세요.', r.tbl;
    end if;

    -- 이름과 무관하게, 이 테이블에 해당 컬럼 구성의 유니크 인덱스가 이미 있는지 본다
    select count(*) into n
      from pg_index i
     where i.indrelid = format('public.%I', r.tbl)::regclass
       and i.indisunique
       and pg_get_indexdef(i.indexrelid) like '%(' || r.cols || ')';

    if n > 0 then
      continue;
    end if;

    /* 인덱스 이름은 테이블이 아니라 스키마 전체에서 유일해야 한다.
       `alter table X rename to X_old` 는 인덱스 이름을 따라 바꾸지 않으므로,
       비켜 둔 옛 테이블이 원하는 이름을 계속 쥐고 있는 경우가 있다. 그 상태에서
       `create unique index if not exists <이름>` 을 쓰면 **이름만 보고 조용히 건너뛰어**
       인덱스가 없는 채로 남는다(그래서 나중에 ON CONFLICT 가 실패한다).
       → 이름이 이미 쓰이고 있으면 다른 이름으로 만든다. */
    idx := r.idxname;
    if exists (
      select 1 from pg_class
       where relname = idx and relnamespace = 'public'::regnamespace
    ) then
      idx := left(r.idxname, 50) || '_' || substr(md5(r.tbl || r.cols || clock_timestamp()::text), 1, 8);
    end if;

    execute format('create unique index %I on public.%I (%s)', idx, r.tbl, r.cols);
    raise notice '% 에 유니크 인덱스 %(%) 를 새로 만들었습니다.', r.tbl, idx, r.cols;
  end loop;
end $$;


/* ══════════ 1. admin_store → 정규화 테이블 팬아웃 ══════════ */

create or replace function kz_flag_is_public(p_key text) returns boolean
language sql immutable as $$
  -- 비로그인 방문자가 읽어도 되는 설정 키 화이트리스트
  select p_key in ('kozy_event_popup', 'kozy_fx')
$$;

create or replace function kz_apply_admin_store(p_key text, p_data jsonb)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_ids text[];
begin
  if p_data is null then
    return;
  end if;

  /* ── 고객 ── */
  if p_key = 'customers' and jsonb_typeof(p_data) = 'array' then
    select array_agg(distinct coalesce(nullif(el->>'id',''), 'C-' || md5(el::text)))
      into v_ids
      from jsonb_array_elements(p_data) el
     where jsonb_typeof(el) = 'object';

    insert into customers (id, name, gender, nationality, school, email, insta, depart, auto, data, updated_at)
    select distinct on (id)
           coalesce(nullif(el->>'id',''), 'C-' || md5(el::text)) as id,
           nullif(btrim(el->>'name'), ''),
           nullif(btrim(el->>'gender'), ''),
           nullif(btrim(el->>'nationality'), ''),
           nullif(btrim(el->>'school'), ''),
           nullif(btrim(el->>'email'), ''),
           nullif(btrim(el->>'insta'), ''),
           nullif(btrim(el->>'depart'), ''),
           coalesce(kz_bool(el->>'auto'), false),
           el,
           now()
      from jsonb_array_elements(p_data) el
     where jsonb_typeof(el) = 'object'
     order by id
    on conflict (id) do update set
      name        = excluded.name,
      gender      = excluded.gender,
      nationality = excluded.nationality,
      school      = excluded.school,
      email       = excluded.email,
      insta       = excluded.insta,
      depart      = excluded.depart,
      auto        = excluded.auto,
      data        = excluded.data,
      deleted_at  = null,          -- 목록에 다시 나타나면 되살린다
      updated_at  = now();

    -- 목록에서 사라진 고객은 지우지 않고 표시만 한다(주문 기록 보존)
    update customers c
       set deleted_at = now()
     where c.deleted_at is null
       and not (c.id = any (coalesce(v_ids, '{}'::text[])));

  /* ── 학교 ── */
  elsif p_key = 'schools' and jsonb_typeof(p_data) = 'array' then
    select array_agg(distinct btrim(el->>'name'))
      into v_ids
      from jsonb_array_elements(p_data) el
     where jsonb_typeof(el) = 'object' and coalesce(btrim(el->>'name'), '') <> '';

    insert into schools (name, return_date, postal_code, address1, data, updated_at)
    select distinct on (name)
           btrim(el->>'name') as name,
           kz_date(el->>'returnDate'),
           nullif(btrim(el->>'postalCode'), ''),
           nullif(btrim(el->>'address1'), ''),
           el,
           now()
      from jsonb_array_elements(p_data) el
     where jsonb_typeof(el) = 'object'
       and coalesce(btrim(el->>'name'), '') <> ''
     order by name
    on conflict (name) do update set
      return_date = excluded.return_date,
      postal_code = coalesce(excluded.postal_code, schools.postal_code),
      address1    = coalesce(excluded.address1,    schools.address1),
      data        = excluded.data,
      deleted_at  = null,
      updated_at  = now();

    update schools s
       set deleted_at = now()
     where s.deleted_at is null
       and not (s.name = any (coalesce(v_ids, '{}'::text[])));

  /* ── 재고 ── */
  elsif p_key = 'inventory' and jsonb_typeof(p_data) = 'array' then
    select array_agg(distinct coalesce(nullif(el->>'id',''), 'INV-' || md5(el::text)))
      into v_ids
      from jsonb_array_elements(p_data) el
     where jsonb_typeof(el) = 'object';

    insert into inventory_items (id, type, label, grade, note, created_on, data, updated_at)
    select distinct on (id)
           coalesce(nullif(el->>'id',''), 'INV-' || md5(el::text)) as id,
           coalesce(nullif(btrim(el->>'type'), ''), 'comforter'),
           nullif(btrim(el->>'label'), ''),
           case when upper(btrim(coalesce(el->>'grade', ''))) in ('A','B','C')
                then upper(btrim(el->>'grade')) else 'A' end,
           nullif(btrim(el->>'note'), ''),
           kz_date(el->>'createdAt'),
           el,
           now()
      from jsonb_array_elements(p_data) el
     where jsonb_typeof(el) = 'object'
       and coalesce(nullif(btrim(el->>'type'), ''), 'comforter')
           in ('comforter','mattress_sheet','topper','pillow_inner','pillow_cover')
     order by id
    on conflict (id) do update set
      type       = excluded.type,
      label      = excluded.label,
      grade      = excluded.grade,
      note       = excluded.note,
      created_on = coalesce(excluded.created_on, inventory_items.created_on),
      data       = excluded.data,
      deleted_at = null,
      updated_at = now();

    update inventory_items i
       set deleted_at = now()
     where i.deleted_at is null
       and not (i.id = any (coalesce(v_ids, '{}'::text[])));

  /* ── 메일 이력 (append-only — 관리자가 목록을 비워도 지우지 않는다) ── */
  elsif p_key = 'emails' and jsonb_typeof(p_data) = 'array' then
    insert into email_log (sent_at, sent_at_text, kind, to_email, customer_name, order_no, subject, body, fingerprint, data)
    select case when el->>'at' ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}'
                then (substr(el->>'at', 1, 16))::timestamp at time zone 'Asia/Seoul'
           end,
           nullif(btrim(el->>'at'), ''),
           nullif(btrim(el->>'type'), ''),
           nullif(btrim(el->>'to'), ''),
           nullif(btrim(el->>'cname'), ''),
           nullif(btrim(el->>'oid'), ''),
           nullif(el->>'subj', ''),
           nullif(el->>'body', ''),
           md5(concat_ws('|', el->>'at', el->>'type', el->>'to', el->>'oid', left(coalesce(el->>'subj',''), 120))),
           el
      from jsonb_array_elements(p_data) el
     where jsonb_typeof(el) = 'object'
    on conflict (fingerprint) do nothing;

  /* ── 설정 플래그 ── */
  elsif p_key = 'flags' and jsonb_typeof(p_data) = 'object' then
    insert into settings (key, value, is_public, updated_at)
    select f.key, f.value, kz_flag_is_public(f.key), now()
      from jsonb_each(p_data) as f(key, value)
    on conflict (key) do update set
      value      = excluded.value,
      updated_at = now();       -- is_public / description 은 관리자가 정한 값을 유지
  end if;
end $$;

comment on function kz_apply_admin_store(text, jsonb) is
  'admin_store 의 배열/객체 blob 을 정규화 테이블로 반영한다. 트리거와 백필이 함께 쓴다.';

create or replace function kz_admin_store_fanout() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  perform kz_apply_admin_store(new.key, new.data);
  return null;   -- AFTER 트리거
exception when others then
  -- 정규화 사본 반영에 실패해도 원본 저장(admin_store)은 성공시킨다.
  raise warning 'kz_admin_store_fanout(%) 실패: %', new.key, sqlerrm;
  return null;
end $$;

drop trigger if exists admin_store_fanout on admin_store;
create trigger admin_store_fanout after insert or update on admin_store
  for each row execute function kz_admin_store_fanout();

-- 이미 admin_store 에 쌓여 있는 데이터를 정규화 테이블로 한 번에 옮긴다.
create or replace function kz_backfill_admin_store() returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare r record; n integer := 0;
begin
  for r in select key, data from admin_store loop
    perform kz_apply_admin_store(r.key, r.data);
    n := n + 1;
  end loop;
  return n;
end $$;


/* ══════════ 2. 주문번호 발번 ══════════ */

-- 1~6월 → 봄학기(SS), 7~12월 → 가을학기(FW). 예: 26SS
create or replace function kz_semester_code(p_date date default null) returns text
language sql stable as $$
  select to_char(coalesce(p_date, current_date), 'YY')
      || case when extract(month from coalesce(p_date, current_date)) between 1 and 6
              then 'SS' else 'FW' end
$$;

-- 채널·학기별로 원자적으로 1 증가시킨 주문번호를 돌려준다. 예: W-26FW-003
create or replace function kz_next_order_no(p_channel text default 'W', p_base_date date default null)
returns text
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_ch  text := case when upper(coalesce(p_channel, 'W')) = 'B' then 'B' else 'W' end;
  v_key text := v_ch || '-' || kz_semester_code(p_base_date);
  v_n   integer;
begin
  insert into order_seq (key, n, updated_at) values (v_key, 1, now())
  on conflict (key) do update set n = order_seq.n + 1, updated_at = now()
  returning n into v_n;
  return v_key || '-' || lpad(v_n::text, 3, '0');
end $$;

comment on function kz_next_order_no(text, date) is
  '주문번호 발번(원자적). 브라우저 카운터(kozy_seq_map)를 대체한다.';

-- 이미 발급된 주문번호에 맞춰 카운터를 끌어올린다(전환 시 1회 실행).
create or replace function kz_sync_order_seq() returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare n integer;
begin
  insert into order_seq (key, n, updated_at)
  select split_part(order_no, '-', 1) || '-' || split_part(order_no, '-', 2),
         max((split_part(order_no, '-', 3))::integer),
         now()
    from orders
   where order_no ~ '^[WB]-[0-9]{2}(SS|FW)-[0-9]+$'
   group by 1
  on conflict (key) do update set
    n = greatest(order_seq.n, excluded.n), updated_at = now();
  get diagnostics n = row_count;
  return n;
end $$;


/* ══════════ 3. 첨부 사진 분리 백필 ══════════ */
-- feedback.data->photos 의 base64 를 feedback_photos 로 복사한다(원본은 그대로 둔다).
-- Storage 로 옮긴 뒤에는 full_data_url 을 비우고 storage_path 만 남기면 된다.
create or replace function kz_backfill_feedback_photos() returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare n integer;
begin
  insert into feedback_photos (feedback_id, idx, thumb_data_url, full_data_url, bytes)
  select f.id,
         (p.ord - 1)::smallint,
         case when jsonb_typeof(p.el) = 'object' then p.el->>'t' else p.el #>> '{}' end,
         case when jsonb_typeof(p.el) = 'object' then p.el->>'f' else p.el #>> '{}' end,
         length(coalesce(case when jsonb_typeof(p.el) = 'object' then p.el->>'f' else p.el #>> '{}' end, ''))
    from feedback f
    cross join lateral jsonb_array_elements(f.data->'photos') with ordinality as p(el, ord)
   where jsonb_typeof(f.data->'photos') = 'array'
  on conflict (feedback_id, idx) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;


/* ══════════ 4. 조회 뷰 ══════════ */

/* 주문 + 결제 합계 — 관리자 목록·정산에 바로 쓸 수 있는 형태 */
create or replace view orders_v as
select o.id,
       o.order_no,
       o.kind,
       o.channel,
       o.source,
       o.status,
       o.rent_status,
       o.rent_auto,
       o.customer_name,
       o.customer_email,
       o.customer_phone,
       o.nationality,
       o.instagram,
       o.school,
       o.package,
       o.duration,
       o.extend_months,
       o.start_date,
       o.end_date,
       o.postal_code,
       o.address1,
       o.building,
       o.sim_plan,
       o.sim_price_krw,
       o.amn_qty,
       o.evt_status,
       o.lang,
       o.consent_privacy,
       o.consent_terms,
       o.consent_method,
       coalesce(o.amount_krw, 0)                                        as amount_krw,
       coalesce(p.paid_krw, 0)                                          as paid_krw,
       coalesce(p.refunded_krw, 0)                                      as refunded_krw,
       coalesce(o.amount_krw, 0) - coalesce(p.paid_krw, 0)
                                 + coalesce(p.refunded_krw, 0)          as balance_krw,
       o.submitted_at,
       o.created_at,
       o.updated_at
  from orders o
  left join lateral (
    select sum(amount_krw) filter (where status = 'paid')     as paid_krw,
           sum(amount_krw) filter (where status = 'refunded') as refunded_krw
      from payments pay
     where pay.order_id = o.id
  ) p on true;

comment on view orders_v is '주문 + 결제 합계(입금·환불·잔액). 관리자 목록과 정산 화면용.';

create or replace view bedding_orders_v as select * from orders_v where kind = 'bedding';
create or replace view sim_orders_v     as select * from orders_v where kind = 'sim';
create or replace view amenity_orders_v as select * from orders_v where kind = 'amenity';

/* 재고 현황 — 관리자 화면의 invStats() 를 그대로 SQL 로 옮긴 것.
   대여 중·반납예정 = 물품이 나가 있음, 예약완료 = 물품을 잡아 둠.
   구성 B(토퍼 미포함)는 토퍼 재고를 점유하지 않는다. */
create or replace view inventory_status_v as
with types(type) as (
  values ('comforter'), ('mattress_sheet'), ('topper'), ('pillow_inner'), ('pillow_cover')
),
stock as (
  select type,
         count(*)                                as total,
         count(*) filter (where grade = 'A')     as grade_a,
         count(*) filter (where grade = 'B')     as grade_b,
         count(*) filter (where grade = 'C')     as grade_c
    from inventory_items
   where deleted_at is null and retired_at is null
   group by type
),
usage as (
  select t.type,
         count(*) filter (where o.rent_status in ('renting','due')) as rented,
         count(*) filter (where o.rent_status = 'reserved')         as reserved
    from orders o
    join types t
      on t.type <> 'topper' or coalesce(o.package, 'A') <> 'B'   -- 구성 B는 토퍼 제외
   where o.kind = 'bedding'
     and o.rent_status in ('renting','due','reserved')
   group by t.type
)
select t.type,
       coalesce(s.total, 0)                                                          as total,
       coalesce(u.rented, 0)                                                         as rented,
       coalesce(u.reserved, 0)                                                       as reserved,
       coalesce(s.total, 0) - coalesce(u.rented, 0) - coalesce(u.reserved, 0)        as available,
       coalesce(s.grade_a, 0) as grade_a,
       coalesce(s.grade_b, 0) as grade_b,
       coalesce(s.grade_c, 0) as grade_c
  from types t
  left join stock s on s.type = t.type
  left join usage u on u.type = t.type;

comment on view inventory_status_v is '품목별 보유·대여중·예약·가용 수량. 관리자 재고 화면의 집계와 같은 규칙.';

/* 반납 임박(2주 이내) — 알림 배지·리마인더 메일 대상 */
create or replace view due_orders_v as
select id, order_no, customer_name, customer_email, school, start_date, end_date, rent_status,
       (end_date - current_date) as days_left
  from orders
 where kind = 'bedding'
   and end_date is not null
   and rent_status in ('renting','due')
   and end_date >= current_date - 7
   and end_date <= current_date + 14
 order by end_date;

/* 리뷰 집계 — feedback.mjs 의 ?summary=1 응답과 같은 값 */
create or replace view feedback_summary_v as
select count(*)                                                   as count,
       round(avg(nullif(star, 0))::numeric, 2)                     as avg_star,
       round(avg(nullif(q1,   0))::numeric, 2)                     as q1,
       round(avg(nullif(q2,   0))::numeric, 2)                     as q2,
       round(avg(nullif(q3,   0))::numeric, 2)                     as q3,
       round(avg(nullif(q4,   0))::numeric, 2)                     as q4,
       count(*) filter (where star = 1)                            as star1,
       count(*) filter (where star = 2)                            as star2,
       count(*) filter (where star = 3)                            as star3,
       count(*) filter (where star = 4)                            as star4,
       count(*) filter (where star = 5)                            as star5
  from feedback
 where type = 'satisfaction' and hidden = false;

/* 공개 리뷰용 이름 마스킹 — feedback.mjs 의 maskName() 과 같은 규칙 */
create or replace function kz_mask_name(p_name text) returns text
language plpgsql immutable as $$
declare s text; parts text[]; n integer;
begin
  s := btrim(coalesce(p_name, ''));
  if s = '' then return '익명'; end if;
  parts := regexp_split_to_array(s, '\s+');
  if array_length(parts, 1) > 1 then
    return left(parts[1], 20) || ' ' || upper(left(parts[array_length(parts,1)], 1)) || '.';
  end if;
  n := length(s);
  if s ~ '^[가-힣]+$' then
    if n <= 2 then return left(s, 1) || '*'; end if;
    return left(s, 1) || repeat('*', n - 2) || right(s, 1);
  end if;
  if n <= 2 then return left(s, 1) || '*'; end if;
  return left(s, 2) || repeat('*', least(6, n - 2));
end $$;

/* 공개 리뷰 목록 — 개인정보(이메일 등)를 빼고 이름을 마스킹한 형태.
   실제 API 응답은 feedback.mjs 가 만들지만, 대시보드·검증용으로 같은 뷰를 둔다. */
create or replace view public_reviews_v as
select id,
       kz_mask_name(customer_name)                 as name,
       coalesce(star, 0)                           as star,
       left(coalesce(data->>'title', ''), 120)     as title,
       left(coalesce(data->>'body', data->>'positive', ''), 2000) as body,
       left(coalesce(data->>'improvement', ''), 2000)             as improvement,
       recommend,
       submitted_at,
       photo_count,
       created_at
  from feedback
 where type = 'satisfaction' and hidden = false
 order by created_at desc;

/* 비로그인 방문자에게 열어 줄 설정 (이벤트 팝업 ON/OFF 등) */
create or replace view public_settings_v
  with (security_invoker = true) as
select key, value from settings where is_public;

comment on view public_settings_v is
  '공개 설정만 노출. GET /.netlify/functions/admin-store?public=1 이 이 뷰를 읽으면 된다.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  [4/5]  20260806000400_kozy_rls.sql
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  [5/5]  20260806000500_kozy_repair_json.sql
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- ═══════════════════════════════════════════════════════════════════════════
-- K-ozy 스키마 ⑤ 이중 인코딩된 jsonb 복구 · 재발 방지
--
-- ── 무슨 일이 있었나 ──────────────────────────────────────────────────────
-- 함수들이 이렇게 저장하고 있었다.
--
--     await sql`INSERT INTO orders (..., data) VALUES (..., ${JSON.stringify(o)}::jsonb)`
--
-- postgres.js 는 `::jsonb` 캐스트를 보고 파라미터 타입을 jsonb 로 잡은 뒤, 넘겨받은
-- **문자열을 한 번 더 JSON 으로 감싼다.** 그래서 DB 에는 객체가 아니라 JSON 문자열이 들어갔다.
--
--     jsonb_typeof(data) = 'string'
--     data = "{\"id\":\"…\",\"name\":\"…\"}"     ← 객체가 아니라 문자열 한 덩어리
--
-- 앱은 읽을 때마다 JSON.parse 를 한 번 더 해서(각 함수의 asObj) 지금까지 눈에 띄지 않았지만,
-- DB 입장에서는 내용이 없는 문자열이라 이런 것들이 전부 동작하지 않았다.
--
--   · data->>'kind' 같은 조회 · GIN 인덱스 · ①번 파일의 파생 컬럼(전부 NULL 이 된다)
--   · 리뷰 숨김(PUT /feedback)의 jsonb_set → ERROR: cannot set path in scalar
--     → 관리자 화면의 리뷰 공개/숨김 버튼은 지금 500 을 받고 있다.
--
-- ── 이 파일이 하는 일 ──────────────────────────────────────────────────────
--  1) 이미 저장된 행을 객체로 되돌린다(내용은 그대로, 껍데기만 벗긴다).
--  2) BEFORE 트리거로 앞으로 들어오는 값도 자동 교정한다.
--     → 함수 코드가 배포되기 전이거나 예전 버전으로 롤백돼도 데이터는 바르게 들어간다.
--  3) data 를 다시 쓰면 ①번 파일의 파생 컬럼이 자동으로 다시 계산된다.
--
-- 함수 코드(netlify/functions/*.mjs)도 sql.json() 을 쓰도록 고쳐 두었다.
-- 이 마이그레이션은 그 배포 전후 아무 때나 실행해도 되고, 여러 번 실행해도 안전하다.
-- ═══════════════════════════════════════════════════════════════════════════

/* ────────────────── 1. 재발 방지 트리거 ────────────────── */

create or replace function kz_normalize_json() returns trigger
language plpgsql as $$
declare i integer := 0;
begin
  -- 이중(혹은 삼중) 인코딩을 벗긴다. 진짜 문자열이면 그대로 둔다.
  while jsonb_typeof(new.data) = 'string' and i < 3 loop
    begin
      new.data := (new.data #>> '{}')::jsonb;
    exception when others then
      exit;                 -- JSON 이 아닌 평범한 문자열 → 건드리지 않는다
    end;
    i := i + 1;
  end loop;
  return new;
end $$;

comment on function kz_normalize_json() is
  'jsonb 컬럼에 JSON 문자열이 들어오면 객체로 펴 준다. 애플리케이션 버전과 무관하게 저장 형태를 보장한다.';

drop trigger if exists orders_normalize_json on orders;
create trigger orders_normalize_json before insert or update of data on orders
  for each row execute function kz_normalize_json();

drop trigger if exists feedback_normalize_json on feedback;
create trigger feedback_normalize_json before insert or update of data on feedback
  for each row execute function kz_normalize_json();

drop trigger if exists admin_store_normalize_json on admin_store;
create trigger admin_store_normalize_json before insert or update of data on admin_store
  for each row execute function kz_normalize_json();


/* ────────────────── 2. 기존 행 복구 ────────────────── */

create or replace function kz_repair_double_encoded_json()
returns table (relation text, repaired integer)
language plpgsql
set search_path = public, pg_temp
as $$
declare n integer;
begin
  -- data 를 그대로 다시 쓰면 위 BEFORE 트리거가 껍데기를 벗기고,
  -- 그 결과로 파생 컬럼(kind / customer_email / star …)까지 한꺼번에 다시 계산된다.
  update orders set data = data where jsonb_typeof(data) = 'string';
  get diagnostics n = row_count;
  relation := 'orders'; repaired := n; return next;

  update feedback set data = data where jsonb_typeof(data) = 'string';
  get diagnostics n = row_count;
  relation := 'feedback'; repaired := n; return next;

  update admin_store set data = data where jsonb_typeof(data) = 'string';
  get diagnostics n = row_count;
  relation := 'admin_store'; repaired := n; return next;

  -- 리뷰 숨김 값이 문자열("true")로 들어간 행을 boolean 으로 맞춘다.
  update feedback
     set data = jsonb_set(data, '{hidden}', to_jsonb(coalesce(kz_bool(data->>'hidden'), false)), true)
   where jsonb_typeof(data) = 'object'
     and jsonb_typeof(data->'hidden') = 'string';
  get diagnostics n = row_count;
  relation := 'feedback.hidden'; repaired := n; return next;
end $$;

comment on function kz_repair_double_encoded_json() is
  '이중 인코딩된 jsonb 를 객체로 되돌린다. 여러 번 실행해도 안전하다(이미 객체인 행은 건너뛴다).';

-- 지금 바로 1회 실행
select * from kz_repair_double_encoded_json();

-- admin_store 를 다시 썼으니 정규화 테이블(③번 파일)로도 다시 흘려보낸다
select kz_backfill_admin_store();


/* ────────────────── 3. 확인 ──────────────────
   아래가 전부 0 이어야 정상이다.

     select count(*) from orders      where jsonb_typeof(data) <> 'object';
     select count(*) from feedback    where jsonb_typeof(data) <> 'object';
     select count(*) from admin_store where jsonb_typeof(data) not in ('object','array');

   복구가 끝나면 파생 컬럼에 값이 차 있는지도 같이 본다.

     select count(*) filter (where customer_email is not null) as 이메일있음,
            count(*)                                           as 전체
       from orders;                                                              */


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  [완료] 결과 요약
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  · "이중 인코딩 잔여" 두 줄이 0 이면 복구 완료입니다.
--  · "주문 - 이메일 추출됨" 이 "주문 - 전체" 와 비슷하면 파생 컬럼이 정상입니다.
--    (이메일 없이 접수된 건이 있으면 조금 적을 수 있습니다)

select 순서, 항목, 값 from (
  select 1 as 순서, '⚠ 이중 인코딩 잔여 - 주문'   as 항목, count(*)::text as 값 from orders   where jsonb_typeof(data) <> 'object'
  union all select 2, '⚠ 이중 인코딩 잔여 - 피드백', count(*)::text from feedback where jsonb_typeof(data) <> 'object'
  union all select 3, '주문 - 전체',                 count(*)::text from orders
  union all select 4, '주문 - 이메일 추출됨',        count(*)::text from orders where customer_email is not null
  union all select 5, '주문 - 부스 접수(B)',         count(*)::text from orders where channel = 'B'
  union all select 6, '피드백 - 전체',               count(*)::text from feedback
  union all select 7, '피드백 - 공개 리뷰',          count(*)::text from feedback where type = 'satisfaction' and hidden = false
  union all select 8, '고객',                        count(*)::text from customers       where deleted_at is null
  union all select 9, '학교',                        count(*)::text from schools          where deleted_at is null
  union all select 10, '재고 품목',                  count(*)::text from inventory_items  where deleted_at is null
  union all select 11, '메일 발송 이력',             count(*)::text from email_log
  union all select 12, '설정 플래그',                count(*)::text from settings
  union all select 13, '결제 기록',                  count(*)::text from payments
  union all select 14, '첨부 사진',                  count(*)::text from feedback_photos
) t order by 순서;
