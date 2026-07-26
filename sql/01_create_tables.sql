-- =============================================
-- DATABASE: walley_risk_db
-- SCHEMA: public
-- DESCRIPTION: Production-Grade Table Schema for Walley Risk Engine
-- VERSION: 2.0 (Enterprise Standard)
-- =============================================

DROP TABLE IF EXISTS transactions CASCADE;
DROP TABLE IF EXISTS device_authentications CASCADE;
DROP TABLE IF EXISTS beneficiaries CASCADE;
DROP TABLE IF EXISTS users CASCADE;

-- 1. USERS TABLE
CREATE TABLE users (
    user_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE,
    phone VARCHAR(20) NOT NULL UNIQUE,
    wallet_balance DECIMAL(15,2) NOT NULL DEFAULT 0.00,
    home_city VARCHAR(50),
    home_country VARCHAR(50) DEFAULT 'Vietnam',
    home_latitude DECIMAL(10,6),
    home_longitude DECIMAL(10,6),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_login_timestamp TIMESTAMP,
    kyc_status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (kyc_status IN ('pending', 'verified', 'rejected', 'expired')),
    risk_tier VARCHAR(10) DEFAULT 'low' CHECK (risk_tier IN ('low', 'medium', 'high')),
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_phone ON users(phone);

-- 2. BENEFICIARIES TABLE (Bổ sung Chuyển tiền Liên ngân hàng NAPAS)
CREATE TABLE beneficiaries (
    beneficiary_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    beneficiary_name VARCHAR(100) NOT NULL,
    beneficiary_phone VARCHAR(20),
    beneficiary_bank_account VARCHAR(50) NOT NULL,
    beneficiary_bank_code VARCHAR(20) NOT NULL DEFAULT 'WALLEY_INTERNAL',
    beneficiary_country VARCHAR(50) NOT NULL DEFAULT 'Vietnam',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_verified BOOLEAN NOT NULL DEFAULT FALSE,
    is_mule_flagged BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_beneficiaries_bank_acc ON beneficiaries(beneficiary_bank_account, beneficiary_bank_code);

-- 3. DEVICE AUTHENTICATIONS TABLE (Chứa IP Geolocation thô)
CREATE TABLE device_authentications (
    auth_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(user_id),
    device_id VARCHAR(255) NOT NULL,
    login_timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ip_address VARCHAR(45),
    ip_geolocation_country VARCHAR(50),
    ip_geolocation_city VARCHAR(50),
    ip_latitude DECIMAL(10,6),
    ip_longitude DECIMAL(10,6),
    is_proxy_vpn BOOLEAN NOT NULL DEFAULT FALSE,
    is_emulator BOOLEAN NOT NULL DEFAULT FALSE,
    os_type VARCHAR(20),
    browser_fingerprint VARCHAR(255),
    session_duration_minutes INTEGER
);

CREATE INDEX idx_device_auth_user_time ON device_authentications(user_id, login_timestamp DESC);

-- 4. TRANSACTIONS TABLE (Raw Event Data + Operational Decision + Delayed Ground Truth)
CREATE TABLE transactions (
    transaction_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(user_id),
    beneficiary_id UUID NOT NULL REFERENCES beneficiaries(beneficiary_id),
    amount DECIMAL(15,2) NOT NULL,
    timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    channel VARCHAR(20) DEFAULT 'MOBILE_APP',
    merchant_country VARCHAR(50) DEFAULT 'Vietnam',
    
    -- Operational Risk Decision Fields (Real-time Engine Pipeline)
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    fraud_score DECIMAL(5,4),
    final_decision VARCHAR(20) NOT NULL DEFAULT 'pending',
    reviewed_by VARCHAR(50),
    reviewed_at TIMESTAMP,
    rule_flags TEXT[] NOT NULL DEFAULT '{}'::TEXT[], -- FIXED: Mặc định mảng rỗng để array_append không bị NULL
    
    -- Engineered Features (Tự động tính bằng SQL Feature Store, không random!)
    transaction_balance_ratio DECIMAL(5,4),
    is_beneficiary_new BOOLEAN,
    is_off_hours BOOLEAN,
    is_weekend BOOLEAN,
    distance_from_home_km DECIMAL(8,2),
    user_7day_transaction_count INTEGER,
    is_new_device BOOLEAN,
    beneficiary_account_age_days INTEGER,
    time_since_last_login_minutes INTEGER,
    is_high_risk_country BOOLEAN,
    
    -- Ground Truth Labeling (Delayed Feedback Loop - 30 days lag)
    is_ground_truth_fraud BOOLEAN NOT NULL DEFAULT FALSE,
    chargeback_reported_at TIMESTAMP
);

CREATE INDEX idx_transactions_user_time ON transactions(user_id, timestamp DESC);
CREATE INDEX idx_transactions_ben_time ON transactions(beneficiary_id, timestamp DESC);