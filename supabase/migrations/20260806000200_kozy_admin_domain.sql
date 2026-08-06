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
-- ═══════════════════════════════════════════════════════════════════════════

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
  fingerprint   text unique,                 -- 같은 메일이 두 번 들어오는 것 방지
  data          jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'email_log_status_chk') then
    alter table email_log add constraint email_log_status_chk
      check (status in ('queued','opened','sent','failed'));
  end if;
end $$;

comment on table  email_log        is '안내 메일 이력(append-only). 관리자 화면에서 목록을 비워도 여기 기록은 남는다.';
comment on column email_log.status is 'queued=대기열 등록, opened=Gmail 작성창 열림, sent=발송 확인, failed=실패';

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
  id           bigserial primary key,
  feedback_id  text not null references feedback(id) on delete cascade,
  idx          smallint not null,            -- 0,1,2 (건당 최대 3장)
  thumb_data_url text,                       -- 목록·카드용 썸네일
  full_data_url  text,                       -- 원본 (Storage 이관 시 NULL 로 비운다)
  storage_path text,                         -- 예: 'feedback/<id>/0.jpg'
  content_type text,
  bytes        integer,
  created_at   timestamptz not null default now(),
  unique (feedback_id, idx)
);

comment on table feedback_photos is
  '리뷰·이슈 첨부 사진. feedback.data->photos 를 kz_backfill_feedback_photos() 로 복사해 채운다.';

create index if not exists feedback_photos_fid_idx on feedback_photos (feedback_id);
