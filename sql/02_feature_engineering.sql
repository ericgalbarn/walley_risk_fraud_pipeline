-- =============================================
-- SQL FEATURE ENGINEERING ENGINE (SQL FEATURE STORE)
-- Standard: Enterprise Automated Feature Calculation
-- Calculation: Rolling Windows, Haversine Distances, Account Age
-- VERSION: 3.0 (Enterprise Standard)
-- =============================================

-- =============================================
-- 1. CALCULATE TRANSACTION BALANCE RATIO & TIME FLAGS
-- =============================================

-- Tính tỷ lệ giao dịch trên số dư ví (Transaction Balance Ratio)
UPDATE transactions t
SET transaction_balance_ratio = ROUND(LEAST(t.amount / NULLIF(u.wallet_balance, 0), 1.0), 4)
FROM users u
WHERE t.user_id = u.user_id;

-- Xác định giao dịch ngoài giờ hành chính (23h - 6h) và cuối tuần (T7, CN)
UPDATE transactions
SET is_off_hours = (EXTRACT(HOUR FROM timestamp) < 6 OR EXTRACT(HOUR FROM timestamp) >= 23),
    is_weekend = (EXTRACT(ISODOW FROM timestamp) IN (6, 7));


-- =============================================
-- 2. CALCULATE BENEFICIARY PROFILE FEATURES
-- =============================================

-- Tính tuổi tài khoản thụ hưởng (ngày) và cờ Beneficiary Mới (< 30 ngày)
UPDATE transactions t
SET beneficiary_account_age_days = GREATEST(EXTRACT(DAY FROM (t.timestamp - b.created_at))::INTEGER, 0),
    is_beneficiary_new = (t.timestamp - b.created_at < INTERVAL '30 days')
FROM beneficiaries b
WHERE t.beneficiary_id = b.beneficiary_id;

-- Gán cờ Quốc gia Rủi ro Cao theo danh sách FATF
UPDATE transactions t
SET is_high_risk_country = (b.beneficiary_country IN ('North Korea', 'Iran', 'Syria', 'Myanmar', 'Russia'))
FROM beneficiaries b
WHERE t.beneficiary_id = b.beneficiary_id;


-- =============================================
-- 3. ROLLING WINDOW CALCULATIONS (VELOCITY FEATURES)
-- =============================================

-- Tính tổng số lượng giao dịch của User trong 7 ngày gần nhất (Cửa sổ trượt 7 ngày)
WITH user_7d_counts AS (
    SELECT 
        transaction_id,
        COUNT(*) OVER (
            PARTITION BY user_id 
            ORDER BY timestamp 
            RANGE BETWEEN INTERVAL '7 DAYS' PRECEDING AND CURRENT ROW
        ) - 1 AS txn_count_7d
    FROM transactions
)
UPDATE transactions t
SET user_7day_transaction_count = c.txn_count_7d
FROM user_7d_counts c
WHERE t.transaction_id = c.transaction_id;


-- =============================================
-- 4. DEVICE AUTHENTICATION & HAVERSINE DISTANCE FEATURES
-- =============================================

-- Tính thời gian từ lần đăng nhập gần nhất, cờ Thiết bị Mới, và Khoảng cách Địa lý (Haversine Formula)
WITH last_logins AS (
    SELECT 
        t.transaction_id,
        da.device_id,
        da.login_timestamp,
        da.ip_latitude,
        da.ip_longitude,
        u.home_latitude,
        u.home_longitude,
        ROW_NUMBER() OVER (PARTITION BY t.transaction_id ORDER BY da.login_timestamp DESC) AS rn
    FROM transactions t
    JOIN device_authentications da ON t.user_id = da.user_id AND da.login_timestamp <= t.timestamp
    JOIN users u ON t.user_id = u.user_id
)
UPDATE transactions t
SET time_since_last_login_minutes = GREATEST(ROUND(EXTRACT(EPOCH FROM (t.timestamp - l.login_timestamp)) / 60)::INTEGER, 0),
    is_new_device = (l.device_id NOT LIKE 'device_legit%'),
    -- Công thức Haversine tính khoảng cách khoảng cách giữa Tọa độ IP Đăng nhập và Tọa độ Nhà riêng (Đơn vị: KM)
    distance_from_home_km = ROUND((
        6371 * acos(
            LEAST(1.0, GREATEST(-1.0,
                cos(radians(l.home_latitude)) * cos(radians(l.ip_latitude)) *
                cos(radians(l.ip_longitude) - radians(l.home_longitude)) +
                sin(radians(l.home_latitude)) * sin(radians(l.ip_latitude))
            ))
        )
    )::numeric, 2)
FROM last_logins l
WHERE t.transaction_id = l.transaction_id AND l.rn = 1;


-- =============================================
-- 5. DEFAULT FILLERS & EDGE CASE HANDLING
-- =============================================

-- Điền giá trị mặc định cho các giao dịch không tìm thấy lịch sử đăng nhập thiết bị
UPDATE transactions SET distance_from_home_km = 0.0 WHERE distance_from_home_km IS NULL;
UPDATE transactions SET time_since_last_login_minutes = 10 WHERE time_since_last_login_minutes IS NULL;
UPDATE transactions SET is_new_device = FALSE WHERE is_new_device IS NULL;


-- =============================================
-- VERIFICATION QUERY
-- Preview 5 bản ghi ngẫu nhiên sau khi biến đặc trưng được tính toán
-- =============================================

SELECT 
    transaction_id,
    amount,
    transaction_balance_ratio,
    is_beneficiary_new,
    is_off_hours,
    is_weekend,
    distance_from_home_km,
    user_7day_transaction_count,
    is_new_device,
    beneficiary_account_age_days,
    time_since_last_login_minutes,
    is_high_risk_country
FROM transactions
ORDER BY RANDOM()
LIMIT 5;