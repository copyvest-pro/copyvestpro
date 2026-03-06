-- ═══════════════════════════════════════════════════════════════
-- CopyVestPro Full Migration
-- Run with: psql $DATABASE_URL -f migrate-full.sql
-- Safe to run multiple times (all idempotent)
-- ═══════════════════════════════════════════════════════════════

-- ── 1. DEPOSITS: add missing columns ────────────────────────────
ALTER TABLE deposits ADD COLUMN IF NOT EXISTS coin VARCHAR(30);
ALTER TABLE deposits ADD COLUMN IF NOT EXISTS screenshot_url TEXT;

-- Backfill coin from tx_reference where possible
UPDATE deposits
SET coin = split_part(tx_reference, '-', 1)
WHERE coin IS NULL AND tx_reference IS NOT NULL AND tx_reference <> '';

-- ── 2. USERS: add selected_trader_id ────────────────────────────
-- (column added after traders table is created below)

-- ── 3. BALANCE LEDGER ────────────────────────────────────────────
-- Source of truth for all user balances.
-- AvailableBalance = SUM(credit entries) - SUM(debit entries)
-- TotalProfit      = SUM(PROFIT_CREDIT + ADMIN_CREDIT + HOURLY_ACCRUAL)
CREATE TABLE IF NOT EXISTS balance_ledger (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  entry_type  VARCHAR(40) NOT NULL CHECK (entry_type IN (
    'DEPOSIT_CONFIRMED',   -- deposit approved by admin
    'PROFIT_CREDIT',       -- admin manual profit credit
    'ADMIN_CREDIT',        -- admin misc credit
    'HOURLY_ACCRUAL',      -- automated hourly ROI drip
    'WITHDRAWAL_DEBIT',    -- withdrawal request (reserved)
    'ADMIN_DEBIT',         -- admin manual debit
    'WITHDRAWAL_REFUND'    -- withdrawal rejected, refund
  )),
  amount      DECIMAL(18,6) NOT NULL CHECK (amount > 0),
  ref_id      UUID,           -- references deposit.id / withdrawal.id etc.
  note        TEXT,           -- human-readable description
  currency    VARCHAR(10) DEFAULT 'USD',
  created_by  UUID REFERENCES users(id),  -- admin user or NULL for system
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ledger_user       ON balance_ledger(user_id);
CREATE INDEX IF NOT EXISTS idx_ledger_type       ON balance_ledger(entry_type);
CREATE INDEX IF NOT EXISTS idx_ledger_created    ON balance_ledger(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ledger_ref        ON balance_ledger(ref_id) WHERE ref_id IS NOT NULL;

-- ── 4. TRADERS TABLE ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS traders (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name                VARCHAR(200) NOT NULL,
  handle              VARCHAR(100),        -- e.g. @username
  bio                 TEXT,
  photo_url           TEXT,
  category            VARCHAR(30) NOT NULL DEFAULT 'trader'
                        CHECK (category IN ('trader','academy','prop_firm')),
  markets             TEXT[],              -- e.g. {'Forex','Crypto','Stocks'}
  strategy_tags       TEXT[],              -- e.g. {'Scalping','Swing'}
  risk_level          VARCHAR(10) DEFAULT 'medium'
                        CHECK (risk_level IN ('low','medium','high')),
  roi_display         VARCHAR(50),         -- e.g. '+142%' — self-reported, not verified
  followers           VARCHAR(30),
  copiers             VARCHAR(30),
  accuracy            VARCHAR(20),
  youtube_url         TEXT,
  twitter_url         TEXT,
  website_url         TEXT,
  verification_status VARCHAR(30) DEFAULT 'unverified'
                        CHECK (verification_status IN (
                          'unverified','identity_verified','performance_verified')),
  is_active           BOOLEAN     DEFAULT TRUE,
  sort_order          INTEGER     DEFAULT 0,
  created_by          UUID REFERENCES users(id),
  created_at          TIMESTAMPTZ DEFAULT NOW(),
  updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_traders_active ON traders(is_active, sort_order);

-- ── 5. TRADER PROOFS ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS trader_proofs (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  trader_id     UUID        NOT NULL REFERENCES traders(id) ON DELETE CASCADE,
  proof_type    VARCHAR(50) NOT NULL CHECK (proof_type IN (
    'identity','track_record','broker_statement','audit','youtube_channel','other')),
  link          TEXT,
  file_ref      TEXT,
  date_verified DATE,
  admin_note    TEXT,
  verified_by   UUID REFERENCES users(id),
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_proofs_trader ON trader_proofs(trader_id);

-- ── 6. USERS: selected_trader_id ────────────────────────────────
ALTER TABLE users ADD COLUMN IF NOT EXISTS selected_trader_id UUID REFERENCES traders(id);

-- ── 7. SEED: TRADERS (unverified, as specified) ─────────────────
-- Safe insert — skip if already exists by name+category
-- ─── Seed traders with real channel photos ───────────────────────────────
-- photo_url = YouTube channel avatar URL (yt3.googleusercontent.com)
-- All entries are 'unverified' until admin adds proof
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN (VALUES
    ('The Trading Academy','@TheTradingAcademy',
     'Educational trading channel covering Forex, indices, and crypto. Live analysis, trade setups, and market commentary. Not financial advice.',
     'academy','https://yt3.googleusercontent.com/ytc/APkrFKZWeMCsx4Q9e_Pk9oZyGZmXF5kzOZnMXi4M8TyrNg=s176-c-k-c0x00ffffff-no-rj',
     ARRAY['Forex','Crypto','Indices'],ARRAY['Education','Live Analysis','Market Commentary'],
     'medium','https://www.youtube.com/@TheTradingAcademy',NULL,'unverified',10),

    ('KuntingSNR','@KuntingSNR',
     'Supply & demand / support & resistance trading education. Covers Forex pairs and Gold (XAU/USD). Educational content only.',
     'academy','https://yt3.googleusercontent.com/ytc/APkrFKa4xa-3HpC0KnQkYXZ1A4hNUWHGAYxsBqNXQXa-rA=s176-c-k-c0x00ffffff-no-rj',
     ARRAY['Forex','Gold','XAU/USD'],ARRAY['SNR','Supply & Demand','Price Action'],
     'medium','https://www.youtube.com/@KuntingSNR',NULL,'unverified',20),

    ('TargetHit','@TargetHit',
     'Forex trading signals and analysis channel. Regular trade setups and market analysis. Past performance does not guarantee future results.',
     'trader','https://yt3.googleusercontent.com/ytc/APkrFKYuFbZFZlKnx2b6q4C6Bn7AZyRXVPNbLmGBsE7f=s176-c-k-c0x00ffffff-no-rj',
     ARRAY['Forex','Indices'],ARRAY['Signals','Price Action','Swing Trading'],
     'high','https://www.youtube.com/@TargetHit',NULL,'unverified',30),

    ('Akademi Crypto','@AkademiCrypto',
     'Crypto trading education covering Bitcoin, Ethereum, altcoins and DeFi. Educational content only — not financial advice.',
     'academy','https://yt3.googleusercontent.com/ytc/APkrFKRqFgQFuWXoAqSCHrIDCYzQQQF4_bKkW3a-NJP9=s176-c-k-c0x00ffffff-no-rj',
     ARRAY['Crypto','Bitcoin','Ethereum','Altcoins'],ARRAY['Education','Crypto Analysis','DeFi'],
     'high','https://www.youtube.com/@AkademiCrypto',NULL,'unverified',40),

    ('Stockwise','@Stockwise',
     'Stock market education and analysis. Covers equities, ETFs, and market trends. Informational only — not financial advice.',
     'academy','https://yt3.googleusercontent.com/ytc/APkrFKZTpOdFKBSEFOBaBh9_k0ZXFqRqt8gB7s6zHpnJbA=s176-c-k-c0x00ffffff-no-rj',
     ARRAY['Stocks','ETFs','Indices'],ARRAY['Fundamental Analysis','Long-term','Education'],
     'low','https://www.youtube.com/@Stockwise',NULL,'unverified',50),

    ('Andre Rizky Investasi','@AndreRizkyInvestasi',
     'Forex and crypto investment educator from Indonesia. Covers technical and fundamental analysis, portfolio strategies, and risk management.',
     'trader','https://yt3.googleusercontent.com/ytc/APkrFKbCNNQ_0LxvFk5Y23Rp8OQr_c5j-W0Yq6-6a8Cag=s176-c-k-c0x00ffffff-no-rj',
     ARRAY['Forex','Crypto'],ARRAY['Technical Analysis','Fundamental Analysis','Risk Management'],
     'medium','https://www.youtube.com/@AndreRizkyInvestasi',NULL,'unverified',55),

    ('The Edge Funder','@TheEdgeFunder',
     'Proprietary trading firm offering funded accounts. Pass the evaluation to trade firm capital. Partner prop firm — not an individual trader listing.',
     'prop_firm','https://images.unsplash.com/photo-1560179707-f14e90ef3623?w=160&h=160&fit=crop&crop=faces&auto=format',
     ARRAY['Forex','Crypto','Indices','Commodities'],ARRAY['Funded Accounts','Prop Trading','Evaluation'],
     'medium',NULL,'https://www.theedgefunder.com','unverified',60)

  ) AS v(name,handle,bio,category,photo_url,markets,strategy_tags,risk_level,
         youtube_url,website_url,verification_status,sort_order)
  LOOP
    IF NOT EXISTS(SELECT 1 FROM traders WHERE LOWER(traders.name)=LOWER(r.name)) THEN
      INSERT INTO traders(name,handle,bio,category,photo_url,markets,strategy_tags,risk_level,
                          youtube_url,website_url,verification_status,sort_order,is_active)
      VALUES(r.name,r.handle,r.bio,r.category,r.photo_url,r.markets,r.strategy_tags,r.risk_level,
             r.youtube_url,r.website_url,r.verification_status,r.sort_order,TRUE);
    ELSE
      -- Update photo_url and bio if trader already exists but has no photo yet
      UPDATE traders
      SET photo_url = COALESCE(NULLIF(photo_url,''), r.photo_url),
          bio       = COALESCE(NULLIF(bio,''),       r.bio),
          updated_at= NOW()
      WHERE LOWER(name)=LOWER(r.name);
    END IF;
  END LOOP;
END $$;

-- ── 8. PLANS: seed if empty ──────────────────────────────────────
INSERT INTO plans (name, description, min_deposit, max_deposit, monthly_roi, lock_months, is_active)
SELECT * FROM (VALUES
  ('Starter',   'Entry-level plan. Variable monthly returns. Not guaranteed.',           100.00,    999.99, 5.00, 1, TRUE),
  ('Basic',     'Standard investment plan. Variable monthly returns. Not guaranteed.',   1000.00,  4999.99, 8.00, 3, TRUE),
  ('Growth',    'Mid-tier plan with 6-month lock. Variable returns. Not guaranteed.',    5000.00,  9999.99,12.00, 6, TRUE),
  ('Premium',   'High-tier plan. Variable monthly returns. Not guaranteed.',            10000.00, 49999.99,16.00,12, TRUE)
) AS v(name, description, min_deposit, max_deposit, monthly_roi, lock_months, is_active)
WHERE NOT EXISTS (SELECT 1 FROM plans LIMIT 1);

-- ── 9. INDEXES: performance ──────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_ledger_user_type ON balance_ledger(user_id, entry_type);

