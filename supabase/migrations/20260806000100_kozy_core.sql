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
