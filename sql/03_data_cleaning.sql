-- =============================================
-- DATA CLEANING & QUALITY ENFORCEMENT PIPELINE
-- Standard: Enterprise Data Quality Framework (6-Column Standard)
-- DB: walley_risk_db
-- VERSION: 3.2 (Self-Healing Transaction Block)
-- =============================================

-- Khôi phục nếu có transaction cũ bị hủy trước đó
ROLLBACK; 

BEGIN; -- Bắt đầu Transaction Block mới an toàn

-- =============================================
-- STEP 1: ACCURACY & CONFORMITY (Chuẩn hóa Định dạng Chuỗi/PII)
-- =============================================

-- 1.1. Trim khoảng trắng thừa trong thông tin User & Beneficiary
UPDATE users
SET full_name = TRIM(full_name),
    email = LOWER(TRIM(email)),
    phone = TRIM(phone);

UPDATE beneficiaries
SET beneficiary_name = TRIM(beneficiary_name),
    beneficiary_bank_code = UPPER(TRIM(beneficiary_bank_code));

-- 1.2. Chuẩn hóa Số điện thoại về dạng đầu 0 chuẩn Việt Nam
UPDATE users
SET phone = CASE 
    WHEN phone LIKE '+84%' THEN '0' || SUBSTRING(phone FROM 4)
    WHEN phone LIKE '84%'  THEN '0' || SUBSTRING(phone FROM 3)
    ELSE phone
END
WHERE phone LIKE '+84%' OR phone LIKE '84%';

UPDATE beneficiaries
SET beneficiary_phone = CASE 
    WHEN beneficiary_phone LIKE '+84%' THEN '0' || SUBSTRING(beneficiary_phone FROM 4)
    WHEN beneficiary_phone LIKE '84%'  THEN '0' || SUBSTRING(beneficiary_phone FROM 3)
    ELSE beneficiary_phone
END
WHERE beneficiary_phone LIKE '+84%' OR beneficiary_phone LIKE '84%';


-- =============================================
-- STEP 2: REFERENTIAL INTEGRITY (Xử lý Khóa ngoại Mồ côi)
-- =============================================

DELETE FROM transactions
WHERE user_id NOT IN (SELECT user_id FROM users)
   OR beneficiary_id NOT IN (SELECT beneficiary_id FROM beneficiaries);


-- =============================================
-- STEP 3: VALIDITY (Sửa miền giá trị âm & Cực trị bất thường)
-- =============================================

UPDATE users 
SET wallet_balance = ABS(wallet_balance) 
WHERE wallet_balance < 0;

UPDATE transactions 
SET amount = ABS(amount),
    distance_from_home_km = ABS(distance_from_home_km),
    user_7day_transaction_count = ABS(user_7day_transaction_count),
    time_since_last_login_minutes = ABS(time_since_last_login_minutes),
    beneficiary_account_age_days = ABS(beneficiary_account_age_days)
WHERE amount < 0 
   OR distance_from_home_km < 0 
   OR user_7day_transaction_count < 0 
   OR time_since_last_login_minutes < 0
   OR beneficiary_account_age_days < 0;

UPDATE transactions
SET fraud_score = LEAST(1.0, GREATEST(0.0, fraud_score))
WHERE fraud_score IS NOT NULL AND (fraud_score < 0 OR fraud_score > 1);


-- =============================================
-- STEP 4: COMPLETENESS (Xử lý Dữ liệu NULL/Missing)
-- =============================================

UPDATE users
SET home_country = COALESCE(home_country, 'Vietnam'),
    kyc_status = COALESCE(kyc_status, 'pending')
WHERE home_country IS NULL OR kyc_status IS NULL;

UPDATE transactions
SET transaction_balance_ratio = COALESCE(transaction_balance_ratio, 0.0),
    distance_from_home_km = COALESCE(distance_from_home_km, 0.0),
    user_7day_transaction_count = COALESCE(user_7day_transaction_count, 0),
    is_beneficiary_new = COALESCE(is_beneficiary_new, FALSE),
    is_off_hours = COALESCE(is_off_hours, FALSE),
    is_weekend = COALESCE(is_weekend, FALSE),
    is_new_device = COALESCE(is_new_device, FALSE),
    is_high_risk_country = COALESCE(is_high_risk_country, FALSE)
WHERE transaction_balance_ratio IS NULL 
   OR distance_from_home_km IS NULL 
   OR user_7day_transaction_count IS NULL 
   OR is_beneficiary_new IS NULL 
   OR is_off_hours IS NULL 
   OR is_weekend IS NULL 
   OR is_new_device IS NULL 
   OR is_high_risk_country IS NULL;


-- =============================================
-- STEP 5: CONSISTENCY (Sửa mâu thuẫn Logic Chuỗi Thời gian)
-- =============================================

UPDATE transactions t
SET timestamp = u.created_at + INTERVAL '5 minutes'
FROM users u
WHERE t.user_id = u.user_id 
  AND t.timestamp < u.created_at;

UPDATE transactions
SET is_beneficiary_new = (beneficiary_account_age_days < 30);


-- =============================================
-- STEP 6: UNIQUENESS (Làm sạch Giao dịch Trùng lặp do Network Retry)
-- =============================================

WITH duplicate_txns AS (
    SELECT 
        transaction_id,
        ROW_NUMBER() OVER (
            PARTITION BY user_id, beneficiary_id, amount, timestamp 
            ORDER BY transaction_id
        ) as row_num
    FROM transactions
)
DELETE FROM transactions
WHERE transaction_id IN (
    SELECT transaction_id 
    FROM duplicate_txns 
    WHERE row_num > 1
);

COMMIT; -- Lưu thay đổi


-- =============================================
-- SUMMARY VERIFICATION REPORT
-- =============================================

SELECT 
    '=== DATA CLEANING REPORT ===' AS Report_Status,
    NOW() AS Executed_At,
    (SELECT COUNT(*) FROM transactions) AS Cleaned_Transactions,
    (SELECT COUNT(*) FROM transactions WHERE amount <= 0) AS Invalid_Amounts_Left,
    (SELECT COUNT(*) FROM transactions WHERE distance_from_home_km IS NULL) AS Null_Distances_Left,
    (SELECT COUNT(*) FROM transactions WHERE user_id NOT IN (SELECT user_id FROM users)) AS Orphan_Txns_Left;