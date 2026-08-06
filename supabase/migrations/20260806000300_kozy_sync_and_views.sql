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
