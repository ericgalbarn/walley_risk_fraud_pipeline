WITH flagged_summary AS (
    SELECT 
        COUNT(*) AS total_flagged_anomalies,
        COUNT(*) FILTER (WHERE 'biometric_evasion_rule' = ANY(rule_flags)) AS biometric_evasion_count
    FROM transactions
    WHERE cardinality(rule_flags) > 0
)
SELECT 
    biometric_evasion_count AS actual_evasion_transactions,
    total_flagged_anomalies,
    ROUND(100.0 * biometric_evasion_count / NULLIF(total_flagged_anomalies, 0), 2) AS actual_percentage
FROM flagged_summary;