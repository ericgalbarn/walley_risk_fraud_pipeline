# 🔬 Technical Documentation: Walley Risk Platform

This document covers the full methodology, architecture, code-level decisions, data dictionary, and limitations behind the Walley Risk Platform. For a high-level overview, see the [README](../README.md).

---

## Table of Contents

1. [Pipeline Architecture](#pipeline-architecture)
2. [Data Dictionary](#data-dictionary)
3. [Methodology: Phase-by-Phase Deep Dive](#methodology-phase-by-phase-deep-dive)
4. [Pandas ETL Layer](#pandas-etl-layer)
5. [Data Quality Framework (DAMA)](#data-quality-framework-dama)
6. [Key Findings & Dashboard Layout](#key-findings--dashboard-layout)
7. [Recommendations](#recommendations)
8. [Execution Guide](#execution-guide)
9. [Limitations & Assumptions](#limitations--assumptions)
10. [Future Work](#future-work)

---



## Pipeline Architecture

The platform follows a 6-stage end-to-end pipeline:

```
┌─────────────────┐    ┌─────────────────────────┐    ┌─────────────────────────┐
│ 1. Data Gen     │───►│ 2. Schema Setup         │───►│ 3. Feature Store        │
│ (Python Script) │    │ (01_create_tables.sql)  │    │ (02_feature_eng.sql)    │
└─────────────────┘    └─────────────────────────┘    └─────────────────────────┘
                                                                   │
┌─────────────────┐    ┌─────────────────────────┐                │
│ 6. BI Dashboard │◄───│ 5. Data Mart / Views    │◄───────────────┘
│ (Single-Page)   │    │ (05_create_views.sql)   │
└─────────────────┘    └─────────────────────────┘
                                   ▲
                                   │
                       ┌─────────────────────────┐
                       │ 4. RegTech Rules Layer  │
                       │ (04_regtech_rules.sql)  │
                       └─────────────────────────┘
```

1. **Data Generation** — `generate_data.py` produces 18,164 synthetic transaction records with injected fraud scenarios and data quality issues.
2. **Schema Setup** — Relational schema with `users`, `beneficiaries`, `transactions`, `device_authentications`, enforced via primary/foreign keys and indexes.
3. **Feature Engineering** — SQL window functions and geolocation math compute risk-relevant features.
4. **Data Cleaning** — DAMA 6-dimension data quality framework applied.
5. **RegTech Rules Engine** — Four detection rules flag transactions against SBV compliance thresholds.
6. **Data Mart / BI Layer** — Read-only views expose flattened, BI-ready data to Power BI.

---



## Data Dictionary



### `users`


| Column                             | Type      | Description                                                              | Example             |
| ---------------------------------- | --------- | ------------------------------------------------------------------------ | ------------------- |
| `user_id`                          | INT (PK)  | Unique user identifier                                                   | `10234`             |
| `home_latitude` / `home_longitude` | FLOAT     | User's registered home coordinates, used for geolocation distance checks | `21.0278, 105.8342` |
| `account_created_at`               | TIMESTAMP | Account opening date                                                     | `2024-03-11`        |




### `beneficiaries`


| Column                  | Type      | Description                                          | Example      |
| ----------------------- | --------- | ---------------------------------------------------- | ------------ |
| `beneficiary_id`        | INT (PK)  | Unique beneficiary account identifier                | `55012`      |
| `beneficiary_bank_code` | TEXT      | NAPAS bank routing code                              | `VCB`        |
| `created_at`            | TIMESTAMP | Date beneficiary was first added to sender's account | `2026-06-28` |
| `is_beneficiary_new`    | BOOLEAN   | Flag: beneficiary added within last 30 days          | `TRUE`       |




### `transactions`


| Column                         | Type      | Description                                                      | Example                    |
| ------------------------------ | --------- | ---------------------------------------------------------------- | -------------------------- |
| `transaction_id`               | INT (PK)  | Unique transaction identifier                                    | `9004521`                  |
| `user_id`                      | INT (FK)  | Sender, references `users`                                       | `10234`                    |
| `beneficiary_id`               | INT (FK)  | Recipient, references `beneficiaries`                            | `55012`                    |
| `amount`                       | NUMERIC   | Transaction amount in VND                                        | `9450000`                  |
| `timestamp`                    | TIMESTAMP | Transaction execution time                                       | `2026-07-02 19:00:00`      |
| `ip_latitude` / `ip_longitude` | FLOAT     | Geolocation of transaction origin                                | `10.7626, 106.6602`        |
| `distance_from_home_km`        | FLOAT     | Computed Haversine distance between IP location and home address | `142.7`                    |
| `is_off_hours`                 | BOOLEAN   | Flag: transaction occurred 11 PM–5 AM                            | `TRUE`                     |
| `rule_flags`                   | TEXT[]    | Array of triggered RegTech rule names                            | `{biometric_evasion_rule}` |
| `is_flagged`                   | INT (0/1) | Binary flag: 1 if `cardinality(rule_flags) > 0`                  | `1`                        |


---



## Methodology: Phase-by-Phase Deep Dive



### Phase 1: Feature Store Engineering & Spatial-Temporal Analytics

**1. Geolocation Fraud via Haversine Distance**

**Business pain point:** Fraudsters often compromise a session and transact from a remote location while impersonating the legitimate home user.

**Technical decision:** Rather than relying on raw latitude/longitude, we computed the physical distance (km) between the transaction's IP-derived location and the user's registered home address, using the Haversine formula directly in SQL.

```sql
-- Calculating Geolocation Distance (Haversine Approximation)
UPDATE transactions t
SET distance_from_home_km = (
    6371 * acos(
        least(1.0, greatest(-1.0,
            cos(radians(u.home_latitude)) * cos(radians(t.ip_latitude)) *
            cos(radians(t.ip_longitude) - radians(u.home_longitude)) +
            sin(radians(u.home_latitude)) * sin(radians(t.ip_latitude))
        ))
    )
)
FROM users u
WHERE t.user_id = u.user_id;
```

**Why this approach:** `least(1.0, greatest(-1.0, ...))` guards against floating-point domain errors in PostgreSQL's `acos()` when coordinates are identical or sit at rounding boundaries — without this clamp, near-zero-distance transactions can throw a NaN/domain error and silently break the pipeline.

**Insight:** Transactions with `distance_from_home_km > 100km` showed a **100% overlap with the off-hours flag** (all 96 remote transactions occurring exclusively during off-hours), demonstrating a rigid spatial-temporal clustering that eliminates daytime noise and provides a high-precision indicator for unauthorized remote access patterns.

![Remote transactions during off hours output](../screenshots/06_verifying_remote_transactions_off_hours.png)

You can query this SQL line to check [Remote transactions during off hours query](../sql/08_verifying_remote_transaction_off_hours.sql)

---



### Phase 2: High-Velocity Attack Detection via Window Functions

**2. ATO Night-Burst Detection (Velocity Rule)**

**Business pain point:** Once an account is compromised, fraudsters typically attempt to move funds as fast as possible before the victim notices and locks the account.

**Technical decision:** A standard `GROUP BY user_id` collapses time continuity and can't measure burst density. Instead, we used a sliding window (`RANGE BETWEEN INTERVAL PRECEDING AND CURRENT ROW`) to compute rolling transaction density per user within true 5-minute clock windows.

```sql
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
    SELECT transaction_id FROM burst_transactions WHERE txn_count_5min > 3
);
```

**Why this approach:** `RANGE BETWEEN` measures true elapsed clock time, unlike `ROWS BETWEEN`, which counts a fixed number of preceding rows regardless of how much time actually separates them — the latter would misfire on users with naturally sparse or dense transaction histories.

**Insight:** Isolated 1,258 velocity-flagged transactions. 33.07% of these bursts occurred between 1:00–4:00 AM, consistent with attackers exploiting victims' sleeping hours before detection.

![Flagged velocity transaction verification output](../screenshots/04_verifying_velocity_triggered_off_hours.png)

You can query this SQL line to check [Flagged velocity transaction verification query](../sql/06_verifying_velocity_triggered_off_hours.sql)
---



### Phase 3: AML Mule Ring Detection

**3. Circular 17 Mule Account Identification**

**Business pain point:** Fraud rings direct multiple victims to funnel money into a single "mule account" for rapid consolidation and withdrawal. Circular 17/2024/TT-NHNN requires banks to detect and freeze these collection hubs.

**Technical decision:** A self-join graph CTE matches `beneficiary_id` across distinct sending `user_id`s within a rolling 1-hour window.

```sql
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
```

**Why this approach:** Requiring `COUNT(DISTINCT t2.user_id) >= 4` ensures only genuine fund-pooling hubs are flagged — a legitimate merchant receiving many payments from the *same* repeat customer would not trigger this rule, since `DISTINCT` collapses repeat senders.

**Insight:** Flagged 80 transactions across 8 distinct mule rings. All 8 mule beneficiary accounts were less than 15 days old, supporting the hypothesis that rings rely on newly opened, disposable accounts.

---

### Phase 4: Regulatory Evasion Detection (Decision 2345 Structuring)

**4. Biometric Threshold Evasion Pattern**

**Business pain point:** Decision 2345/QĐ-NHNN mandates facial biometric verification for transfers ≥10,000,000 VND. Fraudsters structure amounts just under this line to avoid triggering the check.

**Technical decision:** Combined numeric range filtering (9M–9.99M VND) with beneficiary metadata (newly added or created within 7 days).

```sql
UPDATE transactions t
SET rule_flags = array_append(rule_flags, 'biometric_evasion_rule')
FROM beneficiaries b
WHERE t.beneficiary_id = b.beneficiary_id
  AND t.amount BETWEEN 9000000 AND 9999999
  AND (
      COALESCE(t.is_beneficiary_new, TRUE) = TRUE
      OR b.created_at >= (t.timestamp - INTERVAL '7 days')
  );
```

**Why this approach:** `COALESCE(t.is_beneficiary_new, TRUE)` is a defensive-SQL choice — if the flag is NULL due to upstream ingestion lag, the rule defaults to a conservative "treat as new" stance rather than silently skipping a potentially risky transaction.

**Insight:** 1,422 transactions matched this pattern — ~71.0% of all flagged anomalies, making structuring just under the biometric threshold the single largest fraud vector in the dataset.

![Biometric evasion transaction verification output](../screenshots/05_verifying_biometric_evasion_transaction.png)

You can query this SQL line to check [Biometric evasion transaction verification query](../sql/07_verifying_biometric_evasion_transaction.sql)

### Phase 5: Semantic Data Mart Layer

**5. Unnesting Arrays for BI Efficiency**

**Technical decision:** PostgreSQL array columns (`TEXT[]`) efficiently store multiple triggered rules per transaction (e.g., `{velocity_rule, biometric_evasion_rule}`), but BI tools can't natively aggregate array elements. A dedicated view uses `unnest()` to flatten rule arrays into individual rows.

```sql
CREATE OR REPLACE VIEW vw_dashboard_rule_breakdown AS
SELECT
    t.transaction_id,
    t.timestamp,
    t.amount,
    unnest(t.rule_flags) AS rule_name,
    b.beneficiary_bank_code
FROM transactions t
LEFT JOIN beneficiaries b ON t.beneficiary_id = b.beneficiary_id
WHERE cardinality(t.rule_flags) > 0;
```

**Result:** Removes the need for custom DAX or SQL on the BI side — Power BI can drag-and-drop aggregate `rule_name` directly, cutting dashboard load and development time.

---



## Pandas ETL Layer

**File:** `python/pandas_etl_demo.ipynb`

The production cleaning and feature-engineering pipeline runs in PostgreSQL (Phases 1–5 above), chosen for performance and auditability at the dataset's full scale, and because the velocity and mule-network rules rely on window functions and self-joins that PostgreSQL executes far more efficiently than an equivalent row-by-row Pandas implementation would.

Alongside this, a standalone Jupyter notebook replicates the *core cleaning and feature-engineering logic* — not the full rule engine — using Python and Pandas. It exists to demonstrate the same transformation logic in a portable, dependency-light form usable without a live database connection: for ad-hoc analysis, local prototyping before promoting logic to SQL, or environments without direct PostgreSQL access.

The notebook is self-contained: it generates its own small synthetic sample (1,000 rows, same schema shape as the production dataset) with the same categories of data quality issues intentionally injected — negative amounts, malformed phone prefixes, nulls, duplicate rows, orphan records — so it can be cloned and run independently, without setting up PostgreSQL first.

### SQL → Pandas Equivalence

Each transformation in the notebook sits directly beneath a markdown cell showing its SQL counterpart from `03_data_cleaning.sql` and `02_feature_engineering.sql`:


| Step                             | SQL                                                                      | Pandas                                                      |
| -------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------- |
| Phone standardization            | `REGEXP_REPLACE(phone, '^(84                                             | 84)', '0')`                                                 |
| Negative amount correction       | `ABS(amount)`                                                            | `.abs()`                                                    |
| Null imputation                  | `COALESCE(is_beneficiary_new, TRUE)`                                     | `.fillna(True)`                                             |
| Deduplication                    | `ROW_NUMBER() OVER (PARTITION BY ...)`, keep `rn = 1`                    | `.drop_duplicates(subset=..., keep='first')`                |
| Referential integrity            | `NOT EXISTS` subquery against `beneficiaries`                            | `.dropna(subset=['beneficiary_id', 'user_id'])`             |
| Haversine distance               | `acos()`/`radians()` with `least(1.0, greatest(-1.0, ...))` domain guard | `np.arccos()`/`np.radians()` with `np.clip(..., -1.0, 1.0)` |
| Off-hours / weekend flags        | `EXTRACT(HOUR FROM timestamp)`, `EXTRACT(DOW FROM timestamp)`            | `.dt.hour`, `.dt.dayofweek`                                 |
| Rule flagging (single-rule demo) | `UPDATE ... WHERE amount BETWEEN 9000000 AND 9999999`                    | Boolean mask via `.between()`                               |


The `np.clip()` call is worth calling out specifically: it serves the exact same purpose as SQL's `least(1.0, greatest(-1.0, ...))` clamp in Phase 1 — both prevent a domain error in `acos()`/`arccos()` when floating-point rounding pushes an input marginally outside its valid [-1, 1] range. Encountering and solving the same numerical edge case in two different engines reinforced that this isn't a SQL-specific quirk, but a general floating-point boundary condition worth guarding against regardless of implementation.

### Why maintain both

- **SQL** is the system of record — full-scale, auditable, and handles the time-series/graph-style rules (velocity bursts, mule networks) that Pandas would need far more complex rolling/merge logic to replicate at similar performance.
- **Pandas** is the portable layer — no database setup required, faster to iterate on for prototyping new rule logic before committing it to SQL, and directly demonstrates Python/Pandas ETL proficiency as a standalone, runnable artifact.

Full notebook output (verified to run end-to-end without errors) is available at `python/pandas_etl_demo.ipynb`.

---



## Data Quality Framework (DAMA)

Applied the DAMA 6-dimension data quality standard in `03_data_cleaning.sql`:


| Dimension                 | Applied Technique                                                                             |
| ------------------------- | --------------------------------------------------------------------------------------------- |
| **Accuracy & Conformity** | String trimming, case normalization, phone number standardization (`+84`/`84` prefixes → `0`) |
| **Referential Integrity** | Purged orphan transactions with no valid `user_id` or `beneficiary_id`                        |
| **Validity**              | Corrected negative amounts/balances via `ABS()`; capped fraud scores to `[0.0, 1.0]`          |
| **Completeness**          | Imputed NULLs via `COALESCE()` with conservative defaults                                     |
| **Uniqueness**            | Removed network-retry duplicate transactions via `ROW_NUMBER() OVER (...)`                    |


**Verification output after cleaning:**

![Data cleaning verification output](../screenshots/02_cleaning_verification.png)

---



## Key Findings & Dashboard Layout

From **18,164** cleaned transactions, the RegTech layer flagged **~2,000 suspicious transactions** (**~11.0%** flag rate).


| Risk Rule                       | Triggered Count | Fraud Pattern & Business Context                                                                                |
| ------------------------------- | --------------- | --------------------------------------------------------------------------------------------------------------- |
| `biometric_evasion_rule`        | 1,804           | Transfers of 9M–9.99M VND to newly created beneficiaries, avoiding mandatory face-matching under Decision 2345. |
| `velocity_rule`                 | 1258            | Rapid 5-minute-window bursts, typical of stolen session tokens or ATO cash-out attempts.                        |
| `circular_17_mule_network_rule` | 80              | 8 distinct mule rings collecting funds from ≥4 victims within 1 hour.                                           |
| `biometric_structuring_rule`    | 56              | Cross-border FATF-flagged transactions layered with biometric evasion.                                          |


> **Reconciliation note:** Rule counts (1,804 + 1,258 + 80 + 56 = 3,198) exceed the total flagged transaction count (~2,000) because some transactions trigger more than one rule simultaneously. `is_flagged` counts unique transactions; the rule breakdown counts individual rule *triggers*.



### Dashboard Layout

Power BI Executive Cockpit — Fraud Detection Dashboard

---



## Recommendations



### 1. Step-Up Authentication for 9M–9.99M VND Range (Immediate)

**Finding:** 1,804 transactions bypassed biometric checks by staying just under the 10M VND threshold.  
**Action:** Require 2FA/OTP step-up verification for first-time transfers to newly added beneficiaries, regardless of amount — closing the structuring loophole rather than just the amount threshold.

### 2. Automated Account Freezing under Circular 17 (Operations)

**Finding:** 80 transactions tied to high-speed mule aggregation networks.  
**Action:** Configure core banking middleware to auto-place a 24-hour debit block on any beneficiary account triggering `circular_17_mule_network_rule`, with automatic routing to the AML/Compliance review queue.

### 3. Night-Time ATO Velocity Throttle (Product & Security)

**Finding:** Velocity bursts peaked significantly during 1–4 AM.
**Action:** Enforce a hard cap of 3 transfers per 5-minute window during off-hours; require biometric re-authentication for any device attempting to exceed it.

---



## Execution Guide

**Prerequisites:** PostgreSQL v13+, Python 3.8+, a DB client (DBeaver/pgAdmin/psql), a BI tool (Power BI/Tableau/Metabase).

### Step 1 — Clone & install

```bash
git clone https://github.com/your-username/walley-risk-platform.git
cd walley-risk-platform
pip install pandas psycopg2-binary faker
```



### Step 2 — Create the database

```sql
CREATE DATABASE walley_risk_db;
```



### Step 3 — Schema

```bash
psql -U postgres -d walley_risk_db -f sql/01_create_tables.sql
```

Sets up `users`, `beneficiaries`, `transactions`, `device_authentications` with keys and indexes.

### Step 4 — Generate synthetic data

```bash
python python/generate_data.py
```

Inserts 18,164 transactions with injected fraud vectors and intentional data quality issues.

### Step 5 — Feature engineering

```bash
psql -U postgres -d walley_risk_db -f sql/02_feature_engineering.sql
```

Computes `distance_from_home_km`, off-hours/weekend flags, balance ratios, window aggregates.

### Step 6 — Data cleaning

```bash
psql -U postgres -d walley_risk_db -f sql/03_data_cleaning.sql
```

Expected output:

![Data cleaning verification output](../screenshots/02_cleaning_verification.png)

### Step 7 — RegTech rules engine

```bash
psql -U postgres -d walley_risk_db -f sql/04_regtech_rules.sql
```

Expected output:

![RegTech rule trigger verification output](../screenshots/03_regtech_verification.png)

### Step 8 — Build data mart views

```bash
psql -U postgres -d walley_risk_db -f sql/05_create_views.sql
```

Creates `vw_dashboard_fraud_summary` and `vw_dashboard_rule_breakdown`.

### Step 9 — Connect BI tool

Connect Power BI (or Tableau/Metabase) to `localhost:5432/walley_risk_db`, import the two views, and build visuals per the dashboard layout above.

### Step 10 — (Optional) Run the Pandas ETL notebook

No database connection required — the notebook generates its own synthetic sample. Requires `pandas`, `numpy`, and Jupyter:

```bash
pip install -r requirements.txt
jupyter notebook python/pandas_etl_demo.ipynb
```

See [Pandas ETL Layer](#pandas-etl-layer) above for what this demonstrates and why it exists alongside the SQL pipeline.

---



## Limitations & Assumptions

This project is transparent about its scope and constraints:

- **Synthetic data:** All records are generated via Python/Faker to simulate realistic fraud patterns. No real user, transaction, or financial data is used at any stage.
- **Illustrative thresholds:** Rule thresholds (9M–9.99M VND structuring window, ≥4 distinct senders for mule detection, 5-minute/3-transaction velocity cap) are reasonable starting points based on the regulations they enforce, but would require calibration against real transaction volume distributions before production use — thresholds tuned on synthetic data will not necessarily hold on live traffic.
- **Static rules are inherently evadable.** Rules-based detection catches known patterns; once fraud rings learn the exact thresholds, they adapt around them. This is a known limitation of any purely rules-based system and is precisely the motivation for the ML roadmap below — not a gap unique to this implementation.
- **No live/streaming component.** This pipeline runs in scheduled batch mode via SQL scripts, not as a real-time transaction-blocking system. Findings support analyst review and downstream action; the platform itself does not freeze funds.
- **Scope is Data Analytics, not Machine Learning.** By design, this phase focuses on SQL-based feature engineering, rule logic, and BI reporting. ML scoring is explicitly out of scope for this version (see Future Work).

---



## Future Work

- **ML-based anomaly scoring** to supplement/replace static thresholds — e.g., isolation forests or gradient-boosted classifiers trained on engineered features (`distance_from_home_km`, velocity counts, account age) to catch patterns rules miss.
- **Graph-based network analysis** for mule ring detection beyond simple sender-count thresholds — community detection algorithms (e.g., Louvain) to surface indirect, multi-hop laundering networks.
- **Case management workflow** — analyst assignment, investigation notes, SAR (Suspicious Activity Report) filing status, and a feedback loop to track false-positive rates and retrain/re-tune rules over time.
- **Real-time streaming pipeline** (e.g., Kafka + streaming SQL) to move from scheduled batch scoring toward near-real-time transaction scoring.

