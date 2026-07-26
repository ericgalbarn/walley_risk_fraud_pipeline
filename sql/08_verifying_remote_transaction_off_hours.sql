SELECT 
    COUNT(*) AS total_transactions,
    COUNT(*) FILTER (WHERE distance_from_home_km > 100) AS remote_transactions_gt_100km,
    COUNT(*) FILTER (WHERE distance_from_home_km > 100 AND is_off_hours = TRUE) AS remote_and_offhours,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE distance_from_home_km > 100 AND is_off_hours = TRUE) 
        / NULLIF(COUNT(*) FILTER (WHERE distance_from_home_km > 100), 0),
        2
    ) AS overlap_percentage
FROM transactions;