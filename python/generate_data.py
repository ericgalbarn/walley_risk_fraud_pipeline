# =============================================
# WALLEY RISK PLATFORM - RAW EVENT DATA GENERATOR (v3.1 - Fixed)
# Standard: Enterprise Pure Raw Event Generator
# Output: Direct PostgreSQL Ingestion + CSV Data Lake Archive
# Compliance: SBV Decision 2345/QD-NHNN & Circular 17/2024/TT-NHNN
# =============================================

import psycopg2
import numpy as np
import pandas as pd
from datetime import datetime, timedelta
import random
import uuid
import os

DB_CONFIG = {
    "host": "localhost",
    "port": 5432,
    "database": "walley_risk_db",
    "user": "postgres",
    "password": "minhduc2004"
}

OUTPUT_DIR = "data"

NUM_USERS = 1000
NUM_BENEFICIARIES = 600
NUM_TRANSACTIONS = 20000

VIETNAMESE_CITIES = [
    ("Ho Chi Minh City", 10.8231, 106.6297),
    ("Hanoi", 21.0285, 105.8542),
    ("Da Nang", 16.0544, 108.2022),
    ("Can Tho", 10.0452, 105.7469),
    ("Hai Phong", 20.8449, 106.6881)
]

NAPAS_BANKS = ["VCB", "TCB", "MBB", "ACB", "VPB", "BIDV", "CTG", "TPB"]
HIGH_RISK_COUNTRIES = ["North Korea", "Iran", "Syria", "Myanmar", "Russia"]

def random_date(start, end):
    delta = end - start
    int_delta = (delta.days * 24 * 60 * 60) + delta.seconds
    return start + timedelta(seconds=random.randrange(int_delta))

def generate_lognormal_amount():
    """Generates financial transaction amount using Log-Normal distribution + SBV 2345 Peaks."""
    rand = random.random()
    if rand < 0.75:
        # Giao dịch nhỏ hàng ngày (20k - 500k VND)
        amt = np.random.lognormal(mean=11.5, sigma=0.8)
    elif rand < 0.93:
        # Giao dịch trung bình (1M - 8M VND)
        amt = np.random.lognormal(mean=14.5, sigma=0.6)
    else:
        # Peak né sinh trắc học theo QĐ 2345 (9M - 9.99M VND)
        amt = random.uniform(9000000, 9999999)
    return round(float(amt), 2)

def generate_users():
    users = []
    now = datetime.now()
    for i in range(NUM_USERS):
        city, lat, lng = random.choice(VIETNAMESE_CITIES)
        created_at = random_date(now - timedelta(days=365), now)
        users.append({
            "user_id": str(uuid.uuid4()),
            "full_name": f"User_{i+1}",
            "email": f"user_{i+1}_{uuid.uuid4().hex[:4]}@gmail.com",
            "phone": f"09{random.randint(10000000, 99999999)}",
            "wallet_balance": round(float(np.random.lognormal(15.0, 1.0)), 2),
            "home_city": city,
            "home_country": "Vietnam",
            "home_latitude": lat + random.uniform(-0.05, 0.05),
            "home_longitude": lng + random.uniform(-0.05, 0.05),
            "created_at": created_at,
            "last_login_timestamp": created_at + timedelta(hours=2),
            "kyc_status": random.choices(["verified", "pending", "rejected"], weights=[0.85, 0.10, 0.05])[0],
            "risk_tier": random.choices(["low", "medium", "high"], weights=[0.80, 0.15, 0.05])[0],
            "is_active": True
        })
    return users

def generate_beneficiaries():
    beneficiaries = []
    now = datetime.now()
    for i in range(NUM_BENEFICIARIES):
        is_mule = i < 20 # 20 tài khoản rác gom tiền lừa đảo
        country = random.choice(HIGH_RISK_COUNTRIES) if (is_mule and random.random() < 0.3) else "Vietnam"
        beneficiaries.append({
            "beneficiary_id": str(uuid.uuid4()),
            "beneficiary_name": f"Beneficiary_{i+1}",
            "beneficiary_phone": f"03{random.randint(10000000, 99999999)}",
            "beneficiary_bank_account": str(random.randint(1000000000, 9999999999)),
            "beneficiary_bank_code": random.choice(NAPAS_BANKS) if country == "Vietnam" else "OFFSHORE_WIRE",
            "beneficiary_country": country,
            "created_at": random_date(now - timedelta(days=15), now) if is_mule else random_date(now - timedelta(days=200), now),
            "is_verified": not is_mule,
            "is_mule_flagged": is_mule
        })
    return beneficiaries

def generate_events(users, beneficiaries):
    txns = []
    auths = []
    now = datetime.now()
    start_time = now - timedelta(days=30)

    mule_bens = [b for b in beneficiaries if b["is_mule_flagged"]]
    normal_bens = [b for b in beneficiaries if not b["is_mule_flagged"]]

    print("1/3 Generating Normal Organic Transaction Stream...")
    for _ in range(NUM_TRANSACTIONS - 2000):
        u = random.choice(users)
        b = random.choice(normal_bens)
        t_time = random_date(start_time, now)
        amt = generate_lognormal_amount() # FIXED: Đã sửa tên hàm thống nhất

        txns.append({
            "transaction_id": str(uuid.uuid4()),
            "user_id": u["user_id"],
            "beneficiary_id": b["beneficiary_id"],
            "amount": amt,
            "timestamp": t_time,
            "channel": "MOBILE_APP",
            "merchant_country": b["beneficiary_country"],
            "is_ground_truth_fraud": False,
            "chargeback_reported_at": None
        })

        # Device Authentication Event
        auths.append({
            "auth_id": str(uuid.uuid4()),
            "user_id": u["user_id"],
            "device_id": f"device_legit_{u['user_id'][:8]}",
            "login_timestamp": t_time - timedelta(minutes=random.randint(1, 45)),
            "ip_address": f"113.161.{random.randint(1,254)}.{random.randint(1,254)}",
            "ip_geolocation_country": "Vietnam",
            "ip_geolocation_city": u["home_city"],
            "ip_latitude": u["home_latitude"] + random.uniform(-0.01, 0.01),
            "ip_longitude": u["home_longitude"] + random.uniform(-0.01, 0.01),
            "is_proxy_vpn": False,
            "is_emulator": False,
            "os_type": "iOS",
            "browser_fingerprint": f"fp_{u['user_id'][:6]}",
            "session_duration_minutes": random.randint(3, 30)
        })

    print("2/3 Injecting Fraud Scenario A: ATO Night Burst Attacks...")
    for _ in range(25): # 25 đợt cướp tài khoản đêm
        victim = random.choice(users)
        mule = random.choice(mule_bens)
        attack_start = random_date(start_time, now).replace(hour=2, minute=random.randint(0, 30))
        attacker_device = f"dev_hacked_{uuid.uuid4().hex[:8]}"

        # ATO Impossible Travel Login
        auths.append({
            "auth_id": str(uuid.uuid4()),
            "user_id": victim["user_id"],
            "device_id": attacker_device,
            "login_timestamp": attack_start - timedelta(minutes=2),
            "ip_address": f"185.220.{random.randint(1,254)}.{random.randint(1,254)}",
            "ip_geolocation_country": "Russia",
            "ip_geolocation_city": "Moscow",
            "ip_latitude": 55.7558,
            "ip_longitude": 37.6173,
            "is_proxy_vpn": True,
            "is_emulator": True,
            "os_type": "Android",
            "browser_fingerprint": f"fp_emulator_{uuid.uuid4().hex[:6]}",
            "session_duration_minutes": 15
        })

        for step in range(4):
            txn_time = attack_start + timedelta(seconds=step * 40)
            txns.append({
                "transaction_id": str(uuid.uuid4()),
                "user_id": victim["user_id"],
                "beneficiary_id": mule["beneficiary_id"],
                "amount": round(random.uniform(9400000, 9980000), 2),
                "timestamp": txn_time,
                "channel": "MOBILE_APP",
                "merchant_country": "Vietnam",
                "is_ground_truth_fraud": True,
                "chargeback_reported_at": txn_time + timedelta(days=random.randint(3, 15))
            })

    print("3/3 Injecting Fraud Scenario B: NAPAS Interbank Mule Rapid Drain (Thông tư 17)...")
    for mule in mule_bens[:8]:
        mule_attack_time = random_date(start_time, now)
        for _ in range(8):
            vic = random.choice(users)
            t_time = mule_attack_time + timedelta(seconds=random.randint(10, 1200))
            txns.append({
                "transaction_id": str(uuid.uuid4()),
                "user_id": vic["user_id"],
                "beneficiary_id": mule["beneficiary_id"],
                "amount": round(random.uniform(5000000, 9900000), 2),
                "timestamp": t_time,
                "channel": "MOBILE_APP",
                "merchant_country": "Vietnam",
                "is_ground_truth_fraud": True,
                "chargeback_reported_at": t_time + timedelta(days=random.randint(1, 20))
            })

    return txns, auths

def insert_to_db(conn, users, beneficiaries, txns, auths):
    cur = conn.cursor()
    print("Writing Users to Database...")
    for u in users:
        cur.execute("""
            INSERT INTO users (user_id, full_name, email, phone, wallet_balance, home_city, home_country, home_latitude, home_longitude, created_at, last_login_timestamp, kyc_status, risk_tier, is_active)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, (u["user_id"], u["full_name"], u["email"], u["phone"], u["wallet_balance"], u["home_city"], u["home_country"], u["home_latitude"], u["home_longitude"], u["created_at"], u["last_login_timestamp"], u["kyc_status"], u["risk_tier"], u["is_active"]))

    print("Writing Beneficiaries to Database...")
    for b in beneficiaries:
        cur.execute("""
            INSERT INTO beneficiaries (beneficiary_id, beneficiary_name, beneficiary_phone, beneficiary_bank_account, beneficiary_bank_code, beneficiary_country, created_at, is_verified, is_mule_flagged)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, (b["beneficiary_id"], b["beneficiary_name"], b["beneficiary_phone"], b["beneficiary_bank_account"], b["beneficiary_bank_code"], b["beneficiary_country"], b["created_at"], b["is_verified"], b["is_mule_flagged"]))

    print("Writing Device Authentications to Database...")
    for a in auths:
        cur.execute("""
            INSERT INTO device_authentications (auth_id, user_id, device_id, login_timestamp, ip_address, ip_geolocation_country, ip_geolocation_city, ip_latitude, ip_longitude, is_proxy_vpn, is_emulator, os_type, browser_fingerprint, session_duration_minutes)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, (a["auth_id"], a["user_id"], a["device_id"], a["login_timestamp"], a["ip_address"], a["ip_geolocation_country"], a["ip_geolocation_city"], a["ip_latitude"], a["ip_longitude"], a["is_proxy_vpn"], a["is_emulator"], a["os_type"], a["browser_fingerprint"], a["session_duration_minutes"]))

    print("Writing Raw Transactions to Database...")
    for t in txns:
        cur.execute("""
            INSERT INTO transactions (transaction_id, user_id, beneficiary_id, amount, timestamp, channel, merchant_country, is_ground_truth_fraud, chargeback_reported_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, (t["transaction_id"], t["user_id"], t["beneficiary_id"], t["amount"], t["timestamp"], t["channel"], t["merchant_country"], t["is_ground_truth_fraud"], t["chargeback_reported_at"]))

    conn.commit()
    cur.close()
    print("✅ DATABASE INGESTION COMPLETE!")

def export_to_csv(users, beneficiaries, txns, auths):
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    print("\nExporting Raw Data to CSV files...")
    
    pd.DataFrame(users).to_csv(os.path.join(OUTPUT_DIR, "raw_users.csv"), index=False)
    pd.DataFrame(beneficiaries).to_csv(os.path.join(OUTPUT_DIR, "raw_beneficiaries.csv"), index=False)
    pd.DataFrame(auths).to_csv(os.path.join(OUTPUT_DIR, "raw_device_authentications.csv"), index=False)
    pd.DataFrame(txns).to_csv(os.path.join(OUTPUT_DIR, "raw_transactions.csv"), index=False)
    
    print("✅ CSV EXPORT COMPLETE!")

def main():
    print("==================================================")
    print("Starting Enterprise Raw Data Generator Pipeline...")
    print("==================================================")
    
    users = generate_users()
    beneficiaries = generate_beneficiaries()
    txns, auths = generate_events(users, beneficiaries)

    try:
        conn = psycopg2.connect(**DB_CONFIG)
        insert_to_db(conn, users, beneficiaries, txns, auths)
        conn.close()
    except Exception as e:
        print(f"❌ DB Error: {e}")

    export_to_csv(users, beneficiaries, txns, auths)

if __name__ == "__main__":
    main()