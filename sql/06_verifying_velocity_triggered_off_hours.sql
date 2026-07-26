SELECT 
    -- 1. Amount of times velocity_rule is activated
    COUNT(*) FILTER (WHERE rule_name = 'velocity_rule') AS total_velocity_triggered,
    
    -- 2. Amount of times velocity_rule happens during off-hours
    COUNT(*) FILTER (
        WHERE rule_name = 'velocity_rule' 
        AND is_off_hours = TRUE
    ) AS off_hours_velocity_triggered,
    
    -- 3. Percentage of velocity_rule during off-hours
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE rule_name = 'velocity_rule' 
            AND is_off_hours = TRUE
        ) / NULLIF(COUNT(*) FILTER (WHERE rule_name = 'velocity_rule'), 0), 
        2
    ) AS off_hours_velocity_percentage

FROM (
    SELECT 
        unnest(rule_flags) AS rule_name,
        is_off_hours
    FROM transactions
    WHERE cardinality(rule_flags) > 0
) subquery;