-- =============================================
-- REGTECH LAYER: COMPLETE RULE SET (v3.0 Perfected)
-- Purpose: Implement AML & Fraud Detection Rules
-- Compliance: SBV Decision 2345, FATF Guidelines, Circular 17/2024
-- =============================================

-- =============================================
-- VIEW SETUP: USER LOGIN HISTORY
-- =============================================

CREATE OR REPLACE VIEW user_login_history AS
SELECT 
    user_id,
    login_timestamp,
    ip_latitude,
    ip_longitude,
    LAG(login_timestamp) OVER (PARTITION BY user_id ORDER BY login_timestamp) AS prev_login_timestamp,
    LAG(ip_latitude) OVER (PARTITION BY user_id ORDER BY login_timestamp) AS prev_ip_latitude,
    LAG(ip_longitude) OVER (PARTITION BY user_id ORDER BY login_timestamp) AS prev_ip_longitude
FROM device_authentications;

-- =============================================
-- RULE 1: BIOMETRIC STRUCTURING (QĐ 2345 / FATF)
-- Risk Intent: Giao dịch từ 9M-9.99M đến tài khoản mới/rác thuộc quốc gia rủi ro cao
-- =============================================

UPDATE transactions t
SET rule_flags = array_append(rule_flags, 'biometric_structuring_rule')
FROM beneficiaries b
WHERE t.beneficiary_id = b.beneficiary_id
  AND t.amount BETWEEN 9000000 AND 9999999
  AND b.beneficiary_country IN ('North Korea', 'Iran', 'Syria', 'Myanmar', 'Russia')
  AND (
      COALESCE(t.is_beneficiary_new, TRUE) = TRUE 
      OR b.created_at >= (t.timestamp - INTERVAL '30 days')
  );

-- =============================================
-- RULE 2: CASH-OUT VELOCITY (ATO BURST DETECTION)
-- Risk Intent: >3 giao dịch trong cửa sổ trượt 5 phút của cùng 1 User
-- =============================================

WITH burst_transactions AS (
    SELECT 
        transaction_id,
        COUNT(*) OVER (
            PARTITION BY user_id 
            ORDER BY timestamp 
            RANGE BETWEEN INTERVAL '5 MINUTES' PRECEDING AND CURRENT ROW
        ) AS txn_count_5min
    FROM transactions
)
UPDATE transactions
SET rule_flags = array_append(rule_flags, 'velocity_rule')
WHERE transaction_id IN (
    SELECT transaction_id 
    FROM burst_transactions 
    WHERE txn_count_5min > 3
);

-- =============================================
-- RULE 3: CROSS-BORDER CARD FRAUD
-- Risk Intent: Giao dịch qua Merchant thuộc quốc gia cấm vận FATF + Số tiền > 1M VND
-- =============================================

UPDATE transactions
SET rule_flags = array_append(rule_flags, 'cross_border_fraud_rule')
WHERE merchant_country IN ('North Korea', 'Iran', 'Syria', 'Myanmar', 'Russia')
  AND amount > 1000000;

-- =============================================
-- RULE 4: BIOMETRIC EVASION (QĐ 2345)
-- Risk Intent: Chuyển tiền lần đầu sát trần 10 triệu (9M - 9.99M VND) né sinh trắc học
-- =============================================

UPDATE transactions t
SET rule_flags = array_append(rule_flags, 'biometric_evasion_rule')
FROM beneficiaries b
WHERE t.beneficiary_id = b.beneficiary_id
  AND t.amount BETWEEN 9000000 AND 9999999
  AND (
      COALESCE(t.is_beneficiary_new, TRUE) = TRUE 
      OR b.created_at >= (t.timestamp - INTERVAL '7 days')
  );

-- =============================================
-- RULE 5: IMPOSSIBLE TRAVEL (ATO BEHAVIORAL FLAG)
-- Risk Intent: Đăng nhập từ vị trí cách xa > 100km trong < 2 giờ trước khi giao dịch >= 10M
-- =============================================

UPDATE transactions t
SET rule_flags = array_append(rule_flags, 'impossible_travel_rule')
WHERE t.amount >= 10000000
  AND EXISTS (
      SELECT 1 
      FROM user_login_history l
      WHERE l.user_id = t.user_id
        AND l.login_timestamp <= t.timestamp
        AND l.prev_login_timestamp IS NOT NULL
        AND ( 
            ((l.ip_latitude - l.prev_ip_latitude) ^ 2 + (l.ip_longitude - l.prev_ip_longitude) ^ 2) > 1.0
            AND EXTRACT(EPOCH FROM (l.login_timestamp - l.prev_login_timestamp)) / 3600 < 2
        )
  );

-- =============================================
-- RULE 6: CIRCULAR 17 MULE ACCOUNT NETWORK RULE (Tối ưu Hiệu năng)
-- Risk Intent: Bắt tài khoản rác (Mule) gom tiền từ >= 4 người khác nhau trong 1h qua NAPAS
-- =============================================

WITH mule_velocity AS (
    SELECT 
        t1.transaction_id
    FROM transactions t1
    JOIN transactions t2 ON t1.beneficiary_id = t2.beneficiary_id 
                         AND t2.timestamp BETWEEN t1.timestamp - INTERVAL '1 HOUR' AND t1.timestamp
    GROUP BY t1.transaction_id
    HAVING COUNT(DISTINCT t2.user_id) >= 4
)
UPDATE transactions
SET rule_flags = array_append(rule_flags, 'circular_17_mule_network_rule')
WHERE transaction_id IN (SELECT transaction_id FROM mule_velocity);

-- =============================================
-- VERIFICATION QUERY: KIỂM TRA KẾT QUẢ KÍCH HOẠT RULE
-- =============================================

SELECT 
    unnest(rule_flags) AS rule_name,
    COUNT(*) AS triggered_count
FROM transactions
WHERE cardinality(rule_flags) > 0
GROUP BY rule_name
ORDER BY triggered_count DESC;