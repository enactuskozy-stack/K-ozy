# K-ozy DB 스키마 (Supabase / Netlify DB)

`index.html` · `netlify/functions/*` · 실제 DB 를 하나씩 대조해서, **지금 화면에서는
입력받지만 DB 에는 남지 않는 값**과 **저장은 되지만 꺼내 쓸 수 없는 값**을 정리하고
그 자리를 채우는 스키마입니다. 함께 필요한 함수·프런트 수정도 반영되어 있습니다.

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

| 화면 / 입력 | 지금 저장되는 곳 | 상태 | 대응 |
|---|---|---|---|
| 렌탈 신청서 (`index.html:3684`) | `orders.data` | 🟡 저장됨 · 조회 불가 | `orders` 파생 컬럼 + 인덱스 |
| 이벤트 팝업 — 이불 / 유심 / 세면용품 (`index.html:8374`) | `orders.data` (`kind`) | 🔴 부스 접수(B)가 웹(W)으로 기록됨 | ✅ `orders.mjs` 수정 + `kind` `channel` `sim_plan` `amn_qty` `evt_status` 컬럼 |
| 만족도 리뷰 · 이슈 보고 (`index.html:4298`, `4516`) | `feedback.data` | 🟡 사진 base64 가 행 안에 통째로 | `feedback` 파생 컬럼 + `feedback_photos` |
| 리뷰 공개/숨김 버튼 | `feedback.data.hidden` | 🔴 **500 에러 — 동작 안 함** | ✅ jsonb 저장 방식 수정 + 복구 마이그레이션 |
| 고객 관리 (`kozyCustomers`) | `admin_store['customers']` 배열 blob | 🔴 통째 덮어쓰기 | `customers` 테이블 (자동 반영) |
| 학교 / 반납일 (`kozySchools`) | `admin_store['schools']` | 🔴 통째 덮어쓰기 | `schools` |
| 재고 (`kozyInventory`) | `admin_store['inventory']` | 🔴 통째 덮어쓰기 | `inventory_items` + `inventory_status_v` |
| 안내 메일 이력 (`kozyEmails`) | `admin_store['emails']` | 🔴 "내역 비우기" 누르면 영구 삭제 | `email_log` (append-only) + `status` |
| 이벤트 팝업 ON/OFF | `admin_store['flags']` | 🔴 **공개 화면이 읽지 못함(401)** | ✅ `admin-store.mjs?public=1` 추가 + `settings(is_public)` |
| 주문번호 채번 (`rzNextOrderNo`) | `flags.kozy_seq_map` (브라우저가 계산) | 🔴 동시 접수 시 번호 중복 | `order_seq` + `kz_next_order_no()` (이관은 미완 — 4장) |
| 결제 / 정산 (PayPal · 계좌이체 · 현장결제) | **없음** | 🔴 저장할 곳 자체가 없음 | `payments` + `orders_v.balance_krw` |
| 개인정보 · 약관 동의 (`kzEvt-agree1/2`) | **없음** | 🔴 체크만 확인하고 버림 | ✅ 프런트에서 전송 + `orders.consent_*` |

🔴 = 데이터가 사라지거나 애초에 저장되지 않음 · 🟡 = 저장은 되지만 쓸 수 없는 형태
· ✅ = 이 브랜치에서 코드까지 수정 완료

### 특히 확인이 필요한 4가지

**0. jsonb 가 객체가 아니라 "JSON 문자열"로 저장되고 있었습니다 (가장 심각)**

세 함수 모두 이렇게 저장하고 있었습니다.

```js
await sql`INSERT INTO orders (..., data) VALUES (..., ${JSON.stringify(o)}::jsonb)`
```

postgres.js 는 `::jsonb` 캐스트를 보고 파라미터 타입을 jsonb 로 잡은 뒤, **넘겨받은
문자열을 한 번 더 JSON 으로 감쌉니다.** 그래서 DB 에는 객체가 아니라 문자열 한 덩어리가
들어갑니다.

```
jsonb_typeof(data) = 'string'
data = "{\"id\":\"…\",\"name\":\"…\"}"      ← 객체가 아니라 문자열
```

앱은 읽을 때마다 `JSON.parse` 를 한 번 더 해서(각 함수의 `asObj`) 지금까지 눈에 띄지
않았지만, DB 입장에서는 안이 비어 있는 문자열이라 다음이 전부 동작하지 않습니다.

- `data->>'kind'` 같은 SQL 조회, GIN 인덱스, **이 스키마의 파생 컬럼(전부 NULL 이 됩니다)**
- **관리자 화면의 리뷰 공개/숨김 버튼** — `jsonb_set` 이
  `ERROR: cannot set path in scalar` 로 실패해 500 을 반환합니다(로컬에서 재현 확인).

→ 함수 3개를 `sql.json()` 사용으로 고치고, 이미 저장된 행을 되돌리는 마이그레이션 ⑤ 를
추가했습니다. **⑤ 를 실행하기 전까지는 파생 컬럼이 비어 있는 게 정상입니다.**

**1. 이벤트 팝업이 절대 안 켜집니다** — `index.html:8245` 가
`GET /.netlify/functions/admin-store?public=1` 로 팝업 ON/OFF 를 물어보는데,
`admin-store.mjs` 의 GET 에는 그 분기가 없어 무조건 관리자 세션을 요구합니다.
방문자에게는 401 이 떨어지고 팝업은 늘 꺼진 상태가 됩니다(QR 에 `?event=1` 을 붙였을 때만 열림).

**2. 부스 접수가 웹 접수로 기록됩니다** — 팝업은 `channel:'B'` 를 보내지만
(`index.html:8410`), 서버가 공개 접수를 정규화하면서 `out.channel = 'W'` 로 덮어씁니다.
주문번호도 `W-…` 로 나갑니다.

**3. 관리자 운영 데이터는 "마지막에 저장한 사람이 이긴다" 구조입니다** — 고객 목록 전체가
한 행(`admin_store` key='customers')에 들어가므로, 두 사람이 각자 화면에서 수정하면
나중에 저장한 쪽이 상대의 변경을 통째로 지웁니다.

---

## 2. 적용 방법

### 순서

1. **함수 코드 배포**(이 브랜치의 `netlify/functions/*`) — 새 저장은 바르게 들어갑니다.
2. **마이그레이션 실행** — 기존에 잘못 저장된 행을 복구합니다.

순서가 바뀌어도 괜찮습니다. 마이그레이션 ⑤ 가 `BEFORE` 트리거를 함께 걸어서, 예전 코드가
아직 떠 있거나 나중에 롤백되더라도 DB 가 저장 형태를 스스로 교정합니다.

### Supabase 대시보드에서 (권장 · CLI 불필요)

`SQL Editor` → 아래 순서대로 파일 내용을 붙여넣고 실행:

```
supabase/migrations/20260806000100_kozy_core.sql           -- 코어 테이블 + 파생 컬럼
supabase/migrations/20260806000200_kozy_admin_domain.sql   -- 운영 도메인 테이블
supabase/migrations/20260806000300_kozy_sync_and_views.sql -- 동기화 트리거 · 발번 · 뷰
supabase/migrations/20260806000400_kozy_rls.sql            -- RLS · 권한
supabase/migrations/20260806000500_kozy_repair_json.sql    -- 이중 인코딩 복구 · 재발 방지
```

### Supabase CLI 를 쓴다면

```bash
supabase init            # supabase/config.toml 이 아직 없다면 (기존 migrations 폴더는 그대로 둡니다)
supabase link --project-ref <프로젝트 ref>
supabase db push
```

### 적용 직후 1회만 실행 (기존 데이터 이전)

```sql
select * from kz_repair_double_encoded_json();  -- ⑤가 이미 1회 실행하므로 보통은 불필요
select kz_backfill_admin_store();     -- admin_store blob → customers/schools/inventory/email_log/settings
select kz_sync_order_seq();           -- 이미 발급된 주문번호에 맞춰 카운터 정렬
select kz_backfill_feedback_photos(); -- feedback.data->photos → feedback_photos (원본은 그대로 둠)
```

### 같은 이름의 테이블이 이미 있다면

`create table if not exists` 는 테이블이 이미 있으면 **통째로 건너뜁니다.** 그래서 구조가 다른
`customers` 같은 테이블이 이미 있으면 그 다음 문장부터 이런 에러가 납니다.

```
ERROR: 42703: column "auto" of relation "customers" does not exist
```

②번 파일이 이 상황을 처리합니다.

- **모자란 컬럼만 채웁니다** — 기존 행과 데이터는 그대로 두고 `alter table ... add column
  if not exists` 로 없는 컬럼만 추가합니다.
- **기본키 타입까지 다르면** (예: `customers.id` 가 uuid) 자동으로 고칠 수 없으므로, 파일 맨 앞의
  점검 블록이 **무엇을 어떻게 하면 되는지 한국어로 알려주고 멈춥니다.** 안 쓰는 테이블이면
  `drop table`, 쓰는 테이블이면 `rename to <이름>_old` 로 비켜 둔 뒤 다시 실행하면 됩니다.

⚠️ 기존 `customers` / `schools` / `inventory_items` 테이블에 **K-ozy 관리자 화면에는 없는 데이터**가
들어 있다면, ③번의 팬아웃이 그 행들을 `deleted_at` 으로 표시합니다(soft delete — 행과 값은
그대로 남습니다). 관리자 화면의 목록이 정본이기 때문입니다. 되살리려면
`update customers set deleted_at = null where id = '...';` 로 풀면 됩니다.

### 안전성

- 모든 파일이 **idempotent** 합니다. 여러 번 실행해도 결과가 같습니다.
- 기존 컬럼을 바꾸거나 지우지 않습니다. **예전 함수 코드가 그대로 떠 있어도** 적용할 수
  있습니다(배포된 함수의 SQL 문을 그대로 재생해 확인).
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

### ⑤ `20260806000500_kozy_repair_json.sql` — 이중 인코딩 복구

위 "0번" 문제를 고칩니다.

- `kz_normalize_json()` **BEFORE 트리거** — 들어오는 값이 JSON 문자열이면 객체로 펴 줍니다.
  애플리케이션 버전과 무관하게 저장 형태가 보장됩니다.
- `kz_repair_double_encoded_json()` — 이미 저장된 행을 되돌립니다. `data` 를 다시 쓰는
  것만으로 트리거가 껍데기를 벗기고, 그 결과 **파생 컬럼도 한꺼번에 다시 계산됩니다.**
- 리뷰 `hidden` 이 문자열 `"true"` 로 들어간 행도 boolean 으로 맞춥니다.

---

## 4. 이번에 함께 고친 코드

| 파일 | 내용 |
|---|---|
| `netlify/functions/orders.mjs` | `${JSON.stringify(o)}::jsonb` → `${sql.json(o)}` (2곳) · 부스 채널(`B`) 보존 |
| `netlify/functions/feedback.mjs` | 저장·`jsonb_set` 을 `sql.json()` 으로 (2곳) → 리뷰 숨김 기능 복구 |
| `netlify/functions/admin-store.mjs` | `?public=1` 공개 분기 추가(화이트리스트) · `sql.json()` |
| `index.html` | 팝업: 동의 체크 상태를 `consentPrivacy/consentTerms/consentMethod/consentAt` 로 전송 · 웹 폼: `consentMethod:'notice'` + `consentAt` |

`admin-store.mjs` 의 공개 분기는 화이트리스트(`PUBLIC_FLAG_KEYS`)에 있는 키만 내보냅니다.
**이 목록은 마이그레이션 ③ 의 `kz_flag_is_public()` 과 같은 값을 유지해야 합니다.**

### 동의 기록에 대해

- **현장 팝업**은 필수 동의 체크박스가 실제로 있으므로 체크 상태를 그대로 기록합니다
  → `consent_privacy = true`, `consent_method = 'checkbox'`.
- **웹 렌탈 신청서**는 개인정보 **고지문만 있고 동의 체크박스가 없습니다**(`index.html:1421`).
  받지 않은 동의를 `true` 로 남기면 기록이 사실과 달라지므로, 고지를 보고 제출했다는 사실만
  남깁니다 → `consent_method = 'notice'`, `consent_privacy` 는 **NULL**.

즉 현재 웹 접수분에는 명시적 동의 근거가 없습니다. 개인정보보호법상 수집·이용 동의는
명시적 동의를 받는 것이 안전하므로, **웹 신청서에도 필수 동의 체크박스를 추가할지 결정이
필요합니다.** 추가하면 프런트에서 `consentPrivacy/consentTerms` 를 함께 실어 보내는 것만으로
서버·DB 수정 없이 그대로 기록됩니다.

---

## 5. 아직 남은 것

1. **주문번호 발번 이관** — `index.html:6275 rzNextOrderNo` 가 아직 브라우저에서 번호를
   매깁니다. `kz_next_order_no()` 는 준비돼 있지만, 이 함수는 `rzEnsureOrders` 등 여러 곳에서
   **동기적으로** 호출되고 있어 서버 호출로 바꾸려면 호출부를 비동기로 바꾸는 작업이 따라옵니다.
   회귀 위험이 있어 이번에는 손대지 않았습니다. 이관 후 중복이 0건이면 `orders.order_no` 에
   UNIQUE 인덱스를 걸 수 있습니다(파일 ① 하단에 명령이 주석으로 있습니다).
2. **결제 기록** — PayPal 링크로 이동하면(`index.html:3708`) 그 뒤 결과를 알 수 없습니다.
   결제 완료 리다이렉트나 관리자 입력으로 `payments` 에 한 행을 남기면 `orders_v.balance_krw`
   로 미수금이 바로 보입니다.
3. **사진 분리** — `kz_backfill_feedback_photos()` 로 복사한 뒤, 읽는 쪽을 `feedback_photos`
   로 바꾸고 Supabase Storage 로 옮기면 `feedback` 행이 가벼워집니다.
4. **운영 데이터 읽기 이관** — `customers` / `schools` / `inventory_items` 를 직접 읽는
   API 로 바꾸기. 팬아웃 트리거가 계속 동기화하므로 급하지 않고, 옮긴 뒤에는 동시 편집
   덮어쓰기 문제가 사라집니다.
5. **관리자 일괄 저장의 통째 덮어쓰기** — `POST /orders` 배열은 `data` 를 통째로 교체합니다.
   브라우저 메모리에 없는 필드는 그 시점에 사라지므로, 서버에서만 채우는 값을 늘릴 계획이라면
   `data = orders.data || EXCLUDED.data` 같은 병합 방식으로 바꾸는 걸 권합니다.

---

## 6. 적용 후 확인 쿼리

```sql
-- 이중 인코딩이 남아 있는지 (셋 다 0 이어야 정상)
select count(*) from orders      where jsonb_typeof(data) <> 'object';
select count(*) from feedback    where jsonb_typeof(data) <> 'object';
select count(*) from admin_store where jsonb_typeof(data) not in ('object','array');

-- 파생 컬럼이 실제로 찼는지
select count(*) filter (where customer_email is not null) as 이메일있음, count(*) as 전체 from orders;

-- 주문이 컬럼으로 잘 풀렸는지
select id, order_no, kind, channel, school, start_date, end_date, amount_krw
  from orders order by created_at desc limit 20;

-- 종류별 접수 건수 (부스/웹이 갈라지는지)
select kind, channel, count(*) from orders group by 1,2 order by 1,2;

-- 동의 기록 현황
select consent_method, count(*), count(*) filter (where consent_privacy) as 명시동의
  from orders group by 1;

-- 재고 현황
select * from inventory_status_v order by type;

-- 미수금
select order_no, customer_name, amount_krw, paid_krw, balance_krw
  from orders_v where balance_krw > 0 order by end_date;

-- 리뷰 집계 (사이트 표시값과 같아야 함)
select * from feedback_summary_v;

-- 주문번호 중복 (0건이어야 UNIQUE 승격 가능)
select order_no, count(*) from orders
 where coalesce(order_no,'') <> '' group by 1 having count(*) > 1;
```

## 7. 되돌리기

새로 만든 것만 지웁니다. `orders` / `feedback` / `admin_store` 원본 데이터는 건드리지 않습니다.

```sql
drop trigger if exists admin_store_fanout on admin_store;
drop trigger if exists orders_normalize_json on orders;
drop trigger if exists feedback_normalize_json on feedback;
drop trigger if exists admin_store_normalize_json on admin_store;
drop view if exists orders_v, bedding_orders_v, sim_orders_v, amenity_orders_v,
                    inventory_status_v, due_orders_v, feedback_summary_v,
                    public_reviews_v, public_settings_v cascade;
drop table if exists payments, feedback_photos, email_log, inventory_items,
                     schools, customers, settings, order_seq cascade;
-- 생성 컬럼도 되돌리려면 (예시)
-- alter table orders drop column if exists kind, drop column if exists channel /* … */;
```

> ⚠️ 이중 인코딩 복구(⑤)는 되돌릴 이유가 없습니다. 되돌리면 리뷰 숨김 기능이 다시 깨집니다.
