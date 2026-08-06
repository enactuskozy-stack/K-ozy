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
