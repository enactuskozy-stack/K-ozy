# K-ozy DB 스키마 (Supabase / Netlify DB)

`index.html` · `netlify/functions/*` · 실제 DB 를 하나씩 대조해서, **지금 화면에서는
입력받지만 DB 에는 남지 않는 값**과 **저장은 되지만 꺼내 쓸 수 없는 값**을 정리하고
그 자리를 채우는 스키마입니다.

---

## 1. 지금 상태 요약

현재 DB 에는 테이블이 **딱 3개**뿐이고, 전부 Netlify Function 이 실행 중에
`CREATE TABLE IF NOT EXISTS` 로 만든 것입니다.

| 테이블 | 만든 곳 | 구조 |
|---|---|---|
| `orders` | `netlify/functions/orders.mjs:55` | `id, order_no, status, rent_status, data(jsonb), created_at, updated_at` |
| `feedback` | `netlify/functions/feedback.mjs:66` | `id, type, data(jsonb), created_at` |
| `admin_store` | `netlify/functions/admin-store.mjs:32` | `key, data(jsonb), updated_at` |

즉 **주문과 피드백은 저장되고 있습니다**(전부 `data` jsonb 통째로). 문제는 그 다음입니다.

### 데이터별 대조표

| 화면 / 입력 | 지금 저장되는 곳 | 상태 | 이 스키마의 대응 |
|---|---|---|---|
| 렌탈 신청서 (`index.html:3684`) | `orders.data` | 🟡 저장됨 · 조회 불가 | `orders` 파생 컬럼 + 인덱스 |
| 이벤트 팝업 — 이불 / 유심 / 세면용품 (`index.html:8374`) | `orders.data` (`kind`) | 🟡 부스 접수(B)가 웹(W)으로 기록됨 | `kind` `channel` `sim_plan` `amn_qty` `evt_status` 컬럼 (+ 함수 1줄 수정 필요) |
| 만족도 리뷰 · 이슈 보고 (`index.html:4298`, `4516`) | `feedback.data` | 🟡 사진 base64 가 행 안에 통째로 | `feedback` 파생 컬럼 + `feedback_photos` |
| 고객 관리 (`kozyCustomers`) | `admin_store['customers']` 배열 blob | 🔴 통째 덮어쓰기 | `customers` 테이블 (자동 반영) |
| 학교 / 반납일 (`kozySchools`) | `admin_store['schools']` | 🔴 통째 덮어쓰기 | `schools` |
| 재고 (`kozyInventory`) | `admin_store['inventory']` | 🔴 통째 덮어쓰기 | `inventory_items` + `inventory_status_v` |
| 안내 메일 이력 (`kozyEmails`) | `admin_store['emails']` | 🔴 "내역 비우기" 누르면 영구 삭제 | `email_log` (append-only) + `status` |
| 이벤트 팝업 ON/OFF | `admin_store['flags']` | 🔴 **공개 화면이 읽지 못함** | `settings(is_public)` + `public_settings_v` |
| 주문번호 채번 (`rzNextOrderNo`) | `flags.kozy_seq_map` (브라우저가 계산) | 🔴 동시 접수 시 번호 중복 | `order_seq` + `kz_next_order_no()` |
| 결제 / 정산 (PayPal · 계좌이체 · 현장결제) | **없음** | 🔴 저장할 곳 자체가 없음 | `payments` + `orders_v.balance_krw` |
| 개인정보 · 약관 동의 (`kzEvt-agree1/2`) | **없음** | 🔴 체크만 확인하고 버림 | `orders.consent_privacy / consent_terms / consent_at` |

🔴 = 데이터가 사라지거나 애초에 저장되지 않음 · 🟡 = 저장은 되지만 쓸 수 없는 형태

### 특히 확인이 필요한 3가지

1. **이벤트 팝업이 절대 안 켜집니다.**
   `index.html:8245` 가 `GET /.netlify/functions/admin-store?public=1` 로 팝업 ON/OFF 를
   물어보는데, `admin-store.mjs` 의 GET 은 `?public=1` 을 모르고 무조건 관리자 세션을
   요구합니다(`admin-store.mjs:63`). 방문자에게는 401 이 떨어지고 팝업은 항상 꺼진 상태가 됩니다.
   지금은 QR 링크에 `?event=1` 을 붙였을 때만 열립니다.

2. **부스 접수가 웹 접수로 기록됩니다.**
   팝업은 `channel:'B'` 를 보내지만(`index.html:8410`), 서버가 공개 접수를 정규화하면서
   `out.channel = 'W'` 로 덮어씁니다(`orders.mjs:104`). 주문번호도 `W-…` 로 나갑니다.

3. **관리자 운영 데이터는 "마지막에 저장한 사람이 이긴다"입니다.**
   고객 목록 전체가 한 행(`admin_store` key='customers')에 들어가므로, 두 사람이 각자
   화면에서 수정하면 나중에 저장한 쪽이 상대의 변경을 통째로 지웁니다.

---

## 2. 적용 방법

### Supabase 대시보드에서 (권장 · CLI 불필요)

`SQL Editor` → 아래 순서대로 파일 내용을 붙여넣고 실행:

```
supabase/migrations/20260806000100_kozy_core.sql          -- 코어 테이블 + 파생 컬럼
supabase/migrations/20260806000200_kozy_admin_domain.sql  -- 운영 도메인 테이블
supabase/migrations/20260806000300_kozy_sync_and_views.sql-- 동기화 트리거 · 발번 · 뷰
supabase/migrations/20260806000400_kozy_rls.sql           -- RLS · 권한
```

### Supabase CLI 를 쓴다면

```bash
supabase init            # supabase/config.toml 이 아직 없다면 (기존 migrations 폴더는 그대로 둡니다)
supabase link --project-ref <프로젝트 ref>
supabase db push
```

### 적용 직후 1회만 실행 (기존 데이터 이전)

```sql
select kz_backfill_admin_store();     -- admin_store blob → customers/schools/inventory/email_log/settings
select kz_sync_order_seq();           -- 이미 발급된 주문번호에 맞춰 카운터 정렬
select kz_backfill_feedback_photos(); -- feedback.data->photos → feedback_photos (원본은 그대로 둠)
```

### 안전성

- 모든 파일이 **idempotent** 합니다. 여러 번 실행해도 결과가 같습니다.
- 기존 컬럼을 바꾸거나 지우지 않습니다. **지금 배포된 함수 코드를 한 줄도 고치지 않은 상태에서**
  적용할 수 있고, 적용 후에도 그대로 동작합니다 (배포된 함수의 SQL 문을 그대로 실행해 확인함).
- 생성 컬럼(GENERATED) 추가는 테이블을 다시 쓰므로 짧은 잠금이 걸립니다. 데이터가 수백~수천 행
  수준이면 체감되지 않지만, 접수가 몰리는 시간대는 피하는 편이 좋습니다.

---

## 3. 파일별 내용

### ① `20260806000100_kozy_core.sql` — 코어

`orders` / `feedback` / `admin_store` 를 정식 스키마로 고정하고, `data` jsonb 안에 묻혀 있던
값을 **생성 컬럼(GENERATED ALWAYS AS … STORED)** 으로 끌어올립니다.

생성 컬럼이라 **애플리케이션이 아무것도 안 해도 자동으로 채워집니다.** 함수는 지금처럼
`data` 만 넣으면 되고, DB 가 거기서 `kind`, `customer_email`, `start_date`, `amount_krw`,
`star`, `hidden` … 을 뽑아내 인덱스를 태웁니다.

날짜·숫자 변환은 `kz_date()` `kz_num()` `kz_int()` `kz_bool()` 로 감쌌습니다. 고객이 보낸
`"birthday":"not-a-date"` 같은 값 하나 때문에 주문 저장 전체가 실패하지 않도록,
변환 실패는 예외가 아니라 `NULL` 입니다.

### ② `20260806000200_kozy_admin_domain.sql` — 운영 도메인

`customers` · `schools` · `inventory_items` · `email_log` · `settings` · `order_seq` ·
`payments` · `feedback_photos`.

- 고객·학교·재고는 **soft delete**(`deleted_at`)입니다. 관리자가 목록에서 지워도 과거 주문과의
  연결이 끊기지 않습니다.
- `email_log` 는 append-only 이고 `status`(queued / opened / sent / failed)를 가집니다.
  지금 화면은 "Gmail 작성창을 열었다"와 "실제로 보냈다"를 구분하지 못합니다.
- `payments` 는 한 주문에 여러 건이 붙습니다(부분 입금·환불). `external_ref` 에 PayPal 거래
  ID 를 넣으면 중복 기록이 막힙니다(unique).

### ③ `20260806000300_kozy_sync_and_views.sql` — 동기화 · 발번 · 뷰

**핵심은 팬아웃 트리거입니다.** `admin_store` 에 blob 이 저장될 때마다 정규화 테이블로
자동 반영됩니다.

```
PUT /admin-store {customers:[...]}  →  admin_store(key='customers')  →  [트리거]  →  customers 테이블
```

덕분에 **브라우저와 함수를 고치지 않아도 지금부터 정규화된 데이터가 함께 쌓입니다.**
읽는 쪽을 옮기는 작업은 나중에 천천히 해도 됩니다. 반영에 실패해도 원본 저장은 성공하도록
트리거 안에서 예외를 잡아 경고만 남깁니다(운영 저장이 스키마 때문에 막히면 안 되므로).

| 이름 | 용도 |
|---|---|
| `kz_next_order_no('W', 날짜)` | 주문번호 원자적 발번 (`W-26FW-003`) |
| `kz_sync_order_seq()` | 기존 주문번호에 맞춰 카운터 정렬 |
| `kz_backfill_admin_store()` | 기존 blob 을 정규화 테이블로 이전 |
| `kz_backfill_feedback_photos()` | 사진 base64 를 `feedback_photos` 로 복사 |
| `orders_v` | 주문 + 입금·환불·잔액 |
| `bedding_orders_v` / `sim_orders_v` / `amenity_orders_v` | 종류별 |
| `inventory_status_v` | 품목별 보유·대여중·예약·가용 (구성 B 는 토퍼 미점유 규칙 반영) |
| `due_orders_v` | 반납 임박(2주 이내) |
| `feedback_summary_v` | 리뷰 집계 (`?summary=1` 응답과 동일한 값) |
| `public_reviews_v` | 이름 마스킹한 공개 리뷰 (`홍*동`, `Sophia M.`) |
| `public_settings_v` | 비로그인 방문자에게 열어 줄 설정만 |

### ④ `20260806000400_kozy_rls.sql` — RLS · 권한

모든 테이블에 RLS 를 켜고 `anon` / `authenticated` 권한을 회수합니다. 공개는
`settings` 중 `is_public = true` 인 행 하나뿐입니다.

이 사이트는 브라우저에서 Supabase 키를 쓰지 않으므로 당장 동작에는 영향이 없습니다.
그래도 켜 두는 이유는, Supabase 프로젝트에는 anon API 키가 항상 살아 있어서 **RLS 가 꺼진
테이블은 키만 알면 PostgREST 로 고객 이메일·여권번호·주소가 통째로 읽힌다**는 점 때문입니다.
`DATABASE_URL` 로 붙는 `postgres` 역할은 RLS 를 우회하므로 Netlify Function 은 그대로 동작합니다.

---

## 4. 스키마만으로는 안 되는 것 (코드 수정이 남은 항목)

스키마는 자리를 만들 뿐입니다. 아래는 **코드 한두 줄이 같이 바뀌어야** 값이 채워집니다.
우선순위 순입니다.

1. **이벤트 팝업 공개 플래그** — `netlify/functions/admin-store.mjs` GET 맨 앞에 `?public=1`
   분기를 추가하고 `select key, value from public_settings_v` 결과를 `{flags:{…}}` 형태로
   내려주면 됩니다. (관리자 인증 없이 응답해야 하며, 공개 키만 나가므로 안전합니다)
2. **부스 접수 채널** — `netlify/functions/orders.mjs:104` 의 `out.channel = 'W'` 를
   `out.channel = (input.channel === 'B') ? 'B' : 'W'` 로. 지금은 부스 주문이 전부 웹으로 집계됩니다.
3. **주문번호 발번 이관** — `index.html:6275 rzNextOrderNo` 대신 서버에서
   `select kz_next_order_no($1, $2)` 를 호출. 이관 후 중복이 0건이면
   `orders.order_no` 에 UNIQUE 인덱스를 걸 수 있습니다(파일 ① 하단에 명령 주석으로 있음).
4. **동의 기록** — 신청 폼(`submitForm`)과 팝업(`kzEvtSubmit`)이 보내는 객체에
   `consentPrivacy: true, consentTerms: true, consentAt: new Date().toISOString()` 만 추가하면
   `orders.consent_*` 컬럼이 자동으로 채워집니다. 서버 수정은 필요 없습니다.
5. **결제 기록** — PayPal 링크로 이동하면(`index.html:3708`) 그 뒤 결과를 알 수 없습니다.
   결제 완료 리다이렉트나 관리자 입력으로 `payments` 에 한 행을 남기면 `orders_v.balance_krw`
   로 미수금이 바로 보입니다.
6. **사진 분리** — `kz_backfill_feedback_photos()` 로 복사한 뒤, 읽는 쪽을 `feedback_photos`
   로 바꾸고 Supabase Storage 로 옮기면 `feedback` 행이 가벼워집니다.
7. **운영 데이터 읽기 이관** — `customers` / `schools` / `inventory_items` 를 직접 읽는
   API 로 바꾸기. 팬아웃 트리거가 계속 동기화하므로 급하지 않고, 옮긴 뒤에는 동시 편집
   덮어쓰기 문제가 사라집니다.

### 함께 알아 둘 것

관리자 일괄 저장(`POST /orders` 배열)은 `data` 를 **통째로 교체**합니다. 브라우저 메모리에
없는 필드는 그 시점에 사라지므로, 서버에서만 채우는 값을 앞으로 늘릴 계획이라면
`data = orders.data || EXCLUDED.data` 같은 병합 방식으로 바꾸는 걸 권합니다.

---

## 5. 적용 후 확인 쿼리

```sql
-- 테이블·뷰가 다 생겼는지
select table_name, table_type from information_schema.tables
 where table_schema = 'public' order by 1;

-- 주문이 컬럼으로 잘 풀렸는지
select id, order_no, kind, channel, school, start_date, end_date, amount_krw
  from orders order by created_at desc limit 20;

-- 종류별 접수 건수
select kind, channel, count(*) from orders group by 1,2 order by 1,2;

-- 재고 현황
select * from inventory_status_v order by type;

-- 미수금 (입금이 주문 금액에 못 미치는 건)
select order_no, customer_name, amount_krw, paid_krw, balance_krw
  from orders_v where balance_krw > 0 order by end_date;

-- 반납 임박
select * from due_orders_v;

-- 리뷰 집계 (사이트 표시값과 같아야 함)
select * from feedback_summary_v;

-- 주문번호 중복 (0건이어야 UNIQUE 승격 가능)
select order_no, count(*) from orders
 where coalesce(order_no,'') <> '' group by 1 having count(*) > 1;
```

## 6. 되돌리기

새로 만든 것만 지웁니다. `orders` / `feedback` / `admin_store` 원본 데이터는 건드리지 않습니다.

```sql
drop trigger if exists admin_store_fanout on admin_store;
drop view if exists orders_v, bedding_orders_v, sim_orders_v, amenity_orders_v,
                    inventory_status_v, due_orders_v, feedback_summary_v,
                    public_reviews_v, public_settings_v cascade;
drop table if exists payments, feedback_photos, email_log, inventory_items,
                     schools, customers, settings, order_seq cascade;
-- 생성 컬럼도 되돌리려면 (예시)
-- alter table orders drop column if exists kind, drop column if exists channel /* … */;
```
