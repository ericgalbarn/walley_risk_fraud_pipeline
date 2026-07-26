# 🛡️ Walley Risk End-to-end Rule-based RegTech & Fraud Detection Pipeline

An end-to-end Financial Risk & AML analytics pipeline built with **PostgreSQL, Python, and SQL**, visualized through an interactive **Power BI Executive Cockpit**. The platform ingests, cleans, engineers risk features, and scans synthetic transaction data against Vietnamese State Bank (SBV) compliance rules — **Decision 2345** (biometric verification thresholds) and **Circular 17/2024/TT-NHNN** (mule account monitoring) — to detect **Account Takeover (ATO)**, **Biometric Evasion**, and **Mule Account Networks**.

> 📌 **Note:** All transaction, user, and beneficiary data in this project is synthetically generated (via Python/Faker) to simulate realistic fraud patterns for portfolio and demonstration purposes. No real financial data is used.

---

## 📸 Dashboard Preview

![Power BI Executive Cockpit — Fraud Detection Dashboard](screenshots/01_dashboard_preview.png)

*4-zone executive cockpit: KPI summary, RegTech rule breakdown, temporal fraud trends, and incident drill-down table.*

🔗 **[Explore the Interactive Power BI Dashboard →](https://app.powerbi.com/groups/me/reports/4363c137-59b2-4ef5-9011-106b53b4bfa6/b668eb87d8dc89ab4cc1?experience=power-bi&bookmarkGuid=3d38567bb8557ac59445)**

---

## 🎯 Business Problem

With the rapid growth of digital banking and e-wallets in Vietnam, financial institutions face increasingly sophisticated, high-velocity fraud vectors. This platform was built to answer four core risk and compliance questions:

1. **Biometric Evasion** — How many transactions are structured between 9,000,000–9,999,999 VND to intentionally bypass mandatory biometric authentication (Decision 2345) on transfers to new or high-risk accounts?
2. **Account Takeover (ATO)** — How can we detect high-velocity transaction bursts (>3 transactions within a 5-minute window) indicating a compromised account?
3. **Mule Account Networks** — How do we identify accounts that rapidly aggregate funds from multiple victims (≥4 unique senders within 1 hour), as mandated under Circular 17?
4. **Data Quality** — How do we enforce data quality (DAMA standards) across messy transactional records before they feed Risk Dashboards?

---

## 🔑 Key Findings

From a cleaned dataset of **18,164 transactions**, the RegTech rules engine flagged **~2,100 suspicious transactions** (**~11.5%** flag rate).

| Risk Rule | Triggered Count | What It Means |
|---|---|---|
| `biometric_evasion_rule` | 1,422 | **Primary risk vector.** Transfers of 9M–9.99M VND to newly created beneficiaries, structured just under the 10M VND biometric verification threshold. |
| `velocity_rule` | 629 | Rapid-fire transactions (>3 within 5 minutes), consistent with automated cash-out following account compromise. Concentrated between 1–4 AM. |
| `circular_17_mule_network_rule` | 40 | Accounts receiving funds from ≥4 distinct senders within 1 hour — flagged 8 distinct organized mule rings, all with account age <15 days. |
| `biometric_structuring_rule` | 28 | Cross-border FATF-flagged transactions combined with biometric evasion, indicating layered laundering attempts. |

*Note: individual rule counts sum to more than total flagged transactions because some transactions trigger multiple rules concurrently.*

---

## 💡 Recommendations

| Priority | Finding | Recommended Action |
|---|---|---|
| Immediate | 1,422 transactions evaded biometric checks by staying under 10M VND | Require step-up 2FA/OTP verification for first-time transfers to new beneficiaries, regardless of amount |
| Operational | 40 transactions tied to 8 mule rings | Auto-trigger a 24-hour debit block on any account flagged by `circular_17_mule_network_rule`, routed to AML review |
| Product/Security | Velocity bursts peak 1–4 AM | Cap transfers at 3 per 5-minute window during off-hours; require re-authentication beyond that |

Full reasoning and supporting evidence for each recommendation: see [Technical Documentation](docs/TechnicalDocumentation.md#recommendations).

---

## 🧰 Tech Stack

`PostgreSQL` · `Python (Faker, pandas, psycopg2)` · `SQL Window Functions` · `Power BI` · `DAMA Data Quality Framework`

---

## 🚀 Quick Start

```
# 1. Clone and install dependencies
git clone https://github.com/your-username/walley-risk-platform.git
cd walley-risk-platform
pip install -r requirements.txt

# 2. Create the database
createdb walley_risk_db

# 3. Run the pipeline in order
psql -U postgres -d walley_risk_db -f sql/01_create_tables.sql
python python/generate_data.py
psql -U postgres -d walley_risk_db -f sql/02_feature_engineering.sql
psql -U postgres -d walley_risk_db -f sql/03_data_cleaning.sql
psql -U postgres -d walley_risk_db -f sql/04_regtech_rules.sql
psql -U postgres -d walley_risk_db -f sql/05_create_views.sql

# 4. Connect Power BI (or Tableau/Metabase) to localhost:5432/walley_risk_db
#    Import views: vw_dashboard_fraud_summary, vw_dashboard_rule_breakdown
```

📖 **Full step-by-step guide with expected outputs:** [docs/TechnicalDocumentation.md](docs/TechnicalDocumentation.md#execution-guide)

---

## 📁 Repository Structure

```
walley-risk-platform/
│
├── README.md                        # You are here
├── LICENSE                          # MIT License
├── requirements.txt                 # Python dependencies
│
├── docs/
│   └── TechnicalDocumentation.md    # Full methodology, code walkthroughs, data dictionary
│
├── screenshots/
│   ├── 01_dashboard_preview.png     # Power BI cockpit preview
│   ├── 02_cleaning_verification.png # Data cleaning verification output
│   └── 03_regtech_verification.png  # RegTech rule trigger verification output
│
├── python/
│   └── generate_data.py             # Synthetic data generator
│
└── sql/
    ├── 01_create_tables.sql         # Schema definition
    ├── 02_feature_engineering.sql   # Spatial/temporal/window feature engineering
    ├── 03_data_cleaning.sql         # DAMA data quality pipeline
    ├── 04_regtech_rules.sql         # SBV 2345 & Circular 17 rules engine
    └── 05_create_views.sql          # BI-ready data mart views
```

---

## 🔭 Scope & Roadmap

This project is intentionally scoped as a **rules-based Data Analytics pipeline** — it demonstrates SQL engineering, feature construction, data quality enforcement, and BI storytelling. It is **not** presented as a production fraud-prevention system.

Planned next phases:
- **ML-based anomaly scoring** to replace static thresholds, which are inherently evadable once known
- **Graph-based network analysis** for deeper mule-ring detection beyond simple sender-count thresholds
- **Case management workflow** for analyst triage and SAR filing

See [Limitations & Assumptions](docs/TechnicalDocumentation.md#limitations--assumptions) for full detail.