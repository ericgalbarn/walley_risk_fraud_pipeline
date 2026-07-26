-- =============================================
-- DATA MART & BI VIEWS LAYER
-- Purpose: Serve Cleaned & Aggregated Data to BI Dashboards
-- File: 05_create_views.sql
-- VERSION: 3.0 (Production Standard)
-- =============================================

-- 1. VIEW TỔNG QUAN GIAO DỊCH VÀ CỜ RỦI RO (Dành cho KPI Cards, Filters, Overview)
CREATE OR REPLACE VIEW vw_dashboard_fraud_summary AS
SELECT 
    t.transaction_id,
    t.timestamp,
    t.user_id,
    t.amount,
    t.is_off_hours,
    t.is_weekend,
    t.distance_from_home_km,
    t.transaction_balance_ratio,
    t.beneficiary_account_age_days,
    t.rule_flags,
    -- Cờ nhị phân: 1 = Gian lận/Nghi vấn, 0 = An toàn (Tính Fraud Rate cực dễ)
    CASE WHEN cardinality(t.rule_flags) > 0 THEN 1 ELSE 0 END AS is_flagged,
    -- Đếm số lượng luật bị vi phạm trên cùng 1 giao dịch
    cardinality(t.rule_flags) AS triggered_rules_count,
    b.beneficiary_bank_code,
    b.beneficiary_country
FROM transactions t
LEFT JOIN beneficiaries b ON t.beneficiary_id = b.beneficiary_id;


-- 2. VIEW BUNG LUẬT RỦI RO (Dành riêng cho Biểu đồ Cột Top Triggered Rules)
CREATE OR REPLACE VIEW vw_dashboard_rule_breakdown AS
SELECT 
    t.transaction_id,
    t.timestamp,
    t.amount,
    unnest(t.rule_flags) AS rule_name, -- Bung mảng Array thành từng dòng để BI đếm Bar Chart
    b.beneficiary_bank_code
FROM transactions t
LEFT JOIN beneficiaries b ON t.beneficiary_id = b.beneficiary_id
WHERE cardinality(t.rule_flags) > 0;


-- =============================================
-- VERIFICATION QUERY
-- Kiểm tra View đã sẵn sàng phục vụ Dashboard chưa
-- =============================================

SELECT * FROM vw_dashboard_fraud_summary LIMIT 5;