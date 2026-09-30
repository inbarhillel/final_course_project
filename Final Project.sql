USE FinalProject;
GO

/* ==============================================================================
   PHASE 1: LOAD STAGING TABLES FROM MIRROR
   ============================================================================== */

DROP TABLE IF EXISTS MRR.stg_historical_transactions;
DROP TABLE IF EXISTS MRR.stg_new_merchant_transactions;
DROP TABLE IF EXISTS MRR.stg_merchants;
DROP TABLE IF EXISTS MRR.stg_train;
DROP TABLE IF EXISTS MRR.stg_test;
DROP TABLE IF EXISTS MRR.stg_sample_submission;
GO

SELECT * INTO MRR.stg_historical_transactions     FROM MRR.historical_transactions_mirror;
SELECT * INTO MRR.stg_new_merchant_transactions   FROM MRR.new_merchant_transactions_mirror;
SELECT * INTO MRR.stg_merchants                   FROM MRR.merchants_mirror;
SELECT * INTO MRR.stg_train                       FROM MRR.train_mirror;
SELECT * INTO MRR.stg_test                        FROM MRR.test_mirror;
SELECT * INTO MRR.stg_sample_submission           FROM MRR.sample_submission_mirror;
GO

/* ==============================================================================
   VALIDATION 1: COMPLETE ROW COUNT AUDIT (MIRROR vs. STAGING)
   Ensures 100% data ingestion with zero loss across all staging tables (Delta = 0)
   ============================================================================== */
SELECT 'historical_transactions' AS TableName, 
       (SELECT COUNT(*) FROM MRR.historical_transactions_mirror) AS MirrorCount,
       (SELECT COUNT(*) FROM MRR.stg_historical_transactions) AS StagingCount,
       (SELECT COUNT(*) FROM MRR.historical_transactions_mirror) - (SELECT COUNT(*) FROM MRR.stg_historical_transactions) AS Delta
UNION ALL
SELECT 'new_merchant_transactions', 
       (SELECT COUNT(*) FROM MRR.new_merchant_transactions_mirror),
       (SELECT COUNT(*) FROM MRR.stg_new_merchant_transactions),
       (SELECT COUNT(*) FROM MRR.new_merchant_transactions_mirror) - (SELECT COUNT(*) FROM MRR.stg_new_merchant_transactions)
UNION ALL
SELECT 'merchants', 
       (SELECT COUNT(*) FROM MRR.merchants_mirror),
       (SELECT COUNT(*) FROM MRR.stg_merchants),
       (SELECT COUNT(*) FROM MRR.merchants_mirror) - (SELECT COUNT(*) FROM MRR.stg_merchants)
UNION ALL
SELECT 'train', 
       (SELECT COUNT(*) FROM MRR.train_mirror),
       (SELECT COUNT(*) FROM MRR.stg_train),
       (SELECT COUNT(*) FROM MRR.train_mirror) - (SELECT COUNT(*) FROM MRR.stg_train)
UNION ALL
SELECT 'test', 
       (SELECT COUNT(*) FROM MRR.test_mirror),
       (SELECT COUNT(*) FROM MRR.stg_test),
       (SELECT COUNT(*) FROM MRR.test_mirror) - (SELECT COUNT(*) FROM MRR.stg_test)
UNION ALL
SELECT 'sample_submission', 
       (SELECT COUNT(*) FROM MRR.sample_submission_mirror),
       (SELECT COUNT(*) FROM MRR.stg_sample_submission),
       (SELECT COUNT(*) FROM MRR.sample_submission_mirror) - (SELECT COUNT(*) FROM MRR.stg_sample_submission);
GO

/* ==============================================================================
   PHASE 2: DATA CLEANING, IMPUTATION & TYPE CASTING (STAGING)
   ============================================================================== */

-- 2.1 Clean stg_historical_transactions
UPDATE MRR.stg_historical_transactions
SET category_3 = 'Undefined'
WHERE category_3 IS NULL;

ALTER TABLE MRR.stg_historical_transactions
ALTER COLUMN month_lag INT;
GO

-- 2.2 Clean stg_new_merchant_transactions
UPDATE MRR.stg_new_merchant_transactions
SET merchant_id = 'Undefined'
WHERE merchant_id IS NULL;

ALTER TABLE MRR.stg_new_merchant_transactions
ALTER COLUMN installments INT;
GO

-- 2.3 Clean stg_merchants
ALTER TABLE MRR.stg_merchants
ALTER COLUMN active_months_lag3 INT;

-- Impute NULL avg_sales_lag12 with average
UPDATE MRR.stg_merchants
SET avg_sales_lag12 = (SELECT AVG(avg_sales_lag12) FROM MRR.stg_merchants)
WHERE avg_sales_lag12 IS NULL;
GO

-- 2.4 Clean stg_train
ALTER TABLE MRR.stg_train ALTER COLUMN feature_1 INT;
ALTER TABLE MRR.stg_train ALTER COLUMN feature_2 INT;
ALTER TABLE MRR.stg_train ALTER COLUMN feature_3 INT;
GO

-- 2.5 Clean stg_test & stg_sample_submission
ALTER TABLE MRR.stg_test ALTER COLUMN feature_1 INT;
ALTER TABLE MRR.stg_test ALTER COLUMN feature_2 INT;
ALTER TABLE MRR.stg_test ALTER COLUMN feature_3 INT;

ALTER TABLE MRR.stg_sample_submission ALTER COLUMN target INT;
GO

/* ==============================================================================
   VALIDATION 2: DUPLICATE & CANDIDATE KEY CHECKS
   Audits key constraints across dimensional candidate sources and staging sets
   ============================================================================== */

-- 2.1 Duplicate check on Merchants (demonstrates necessity for ROW_NUMBER deduplication in Phase 3)
SELECT 
    'Duplicate Merchants in Staging' AS AuditCheck,
    merchant_id, 
    COUNT(*) AS DuplicateOccurrences
FROM MRR.stg_merchants
GROUP BY merchant_id
HAVING COUNT(*) > 1;

-- 2.2 Duplicate check on Train Cards (ensures card_id can serve as clean PK for DimCard)
SELECT 
    'Duplicate Cards in Train' AS AuditCheck,
    card_id, 
    COUNT(*) AS DuplicateOccurrences
FROM MRR.stg_train
GROUP BY card_id
HAVING COUNT(*) > 1;

-- 2.3 Check for NULL natural keys across staging transaction logs
SELECT 
    'Null Natural Keys in Transactions' AS AuditCheck,
    SUM(CASE WHEN card_id IS NULL THEN 1 ELSE 0 END)              AS Null_Cards,
    SUM(CASE WHEN merchant_id IS NULL THEN 1 ELSE 0 END)          AS Null_Merchants,
    SUM(CASE WHEN merchant_category_id IS NULL THEN 1 ELSE 0 END) AS Null_Categories,
    SUM(CASE WHEN city_id IS NULL THEN 1 ELSE 0 END)              AS Null_Cities,
    SUM(CASE WHEN subsector_id IS NULL THEN 1 ELSE 0 END)         AS Null_Subsectors,
    SUM(CASE WHEN purchase_date IS NULL THEN 1 ELSE 0 END)        AS Null_Dates
FROM (
    SELECT card_id, merchant_id, merchant_category_id, city_id, subsector_id, purchase_date 
    FROM MRR.stg_historical_transactions
    UNION ALL
    SELECT card_id, merchant_id, merchant_category_id, city_id, subsector_id, purchase_date 
    FROM MRR.stg_new_merchant_transactions
) CombinedStaging;
GO


/* ==============================================================================
   PHASE 3: BUILD DATA WAREHOUSE DIMENSION TABLES
   ============================================================================== */

-- Drop existing tables to ensure clean recreation
DROP VIEW IF EXISTS MRR.vw_GeographicSpending;
DROP TABLE IF EXISTS MRR.FactTransactions;
DROP TABLE IF EXISTS MRR.DimMerchantCategories;
DROP TABLE IF EXISTS MRR.DimLocation;
DROP TABLE IF EXISTS MRR.DimMerchant;
DROP TABLE IF EXISTS MRR.DimDate;
DROP TABLE IF EXISTS MRR.DimSubsector;
DROP TABLE IF EXISTS MRR.DimCard;
GO

-- 3.1 DimDate
CREATE TABLE MRR.DimDate (
    FullDate    DATE PRIMARY KEY,
    [Year]      INT,
    [Quarter]   INT,
    [Month]     INT,
    [Day]       INT,
    DayOfWeek   INT
);

DECLARE @MinDate DATE;
DECLARE @MaxDate DATE;

SELECT
    @MinDate = MIN(CAST(purchase_date AS DATE)),
    @MaxDate = MAX(CAST(purchase_date AS DATE))
FROM (
    SELECT purchase_date FROM MRR.stg_historical_transactions
    UNION ALL
    SELECT purchase_date FROM MRR.stg_new_merchant_transactions
) T
WHERE purchase_date IS NOT NULL;

DECLARE @CurrentDate DATE = @MinDate;

WHILE @CurrentDate <= @MaxDate
BEGIN
    INSERT INTO MRR.DimDate (FullDate, [Year], [Quarter], [Month], [Day], DayOfWeek)
    VALUES (
        @CurrentDate,
        YEAR(@CurrentDate),
        DATEPART(QUARTER, @CurrentDate),
        MONTH(@CurrentDate),
        DAY(@CurrentDate),
        DATEPART(WEEKDAY, @CurrentDate)
    );

    SET @CurrentDate = DATEADD(DAY, 1, @CurrentDate);
END;
GO

-- 3.2 DimLocation
DROP TABLE IF EXISTS MRR.DimLocation;
GO

CREATE TABLE MRR.DimLocation (
    city_id     INT PRIMARY KEY,
    state_id    INT
);
GO

-- Populate with unique city_id
INSERT INTO MRR.DimLocation (city_id, state_id)
SELECT 
    city_id,
    MAX(state_id) AS state_id
FROM (
    SELECT city_id, state_id FROM MRR.stg_historical_transactions WHERE city_id IS NOT NULL
    UNION ALL
    SELECT city_id, state_id FROM MRR.stg_new_merchant_transactions WHERE city_id IS NOT NULL
    UNION ALL
    SELECT city_id, state_id FROM MRR.stg_merchants WHERE city_id IS NOT NULL
) L
GROUP BY city_id;
GO

-- Ensure fallback city_id = -1 exists
IF NOT EXISTS (SELECT 1 FROM MRR.DimLocation WHERE city_id = -1)
BEGIN
    INSERT INTO MRR.DimLocation (city_id, state_id)
    VALUES (-1, -1);
END;
GO
-- Check for duplicates
SELECT 
    city_id,
    state_id,
    COUNT(*) AS duplicate_count
FROM MRR.DimLocation
GROUP BY city_id, state_id
HAVING COUNT(*) > 1;
GO

-- 3.3 DimSubsector
CREATE TABLE MRR.DimSubsector (
    subsector_id INT PRIMARY KEY
);

INSERT INTO MRR.DimSubsector (subsector_id)
SELECT DISTINCT subsector_id
FROM (
    SELECT subsector_id FROM MRR.stg_historical_transactions
    UNION ALL
    SELECT subsector_id FROM MRR.stg_new_merchant_transactions
    UNION ALL
    SELECT subsector_id FROM MRR.stg_merchants
) S
WHERE subsector_id IS NOT NULL;

-- Fallback for Unknown Subsector (-1)
IF NOT EXISTS (SELECT 1 FROM MRR.DimSubsector WHERE subsector_id = -1)
BEGIN
    INSERT INTO MRR.DimSubsector (subsector_id)
    VALUES (-1);
END;
GO

-- 3.4 DimMerchantCategories
-- 1. Drop existing table
DROP TABLE IF EXISTS MRR.DimMerchantCategories;
GO

-- 2. Recreate with clean dimension scope
CREATE TABLE MRR.DimMerchantCategories
(
    merchant_category_id INT PRIMARY KEY,
    category_4           NVARCHAR(50) -- Only category_4 is an inherent merchant/catalog attribute
);
GO

-- 3. Populate cleanly from merchants catalog
INSERT INTO MRR.DimMerchantCategories (merchant_category_id, category_4)
SELECT 
    merchant_category_id,
    MAX(category_4) AS category_4
FROM MRR.stg_merchants
WHERE merchant_category_id IS NOT NULL
GROUP BY merchant_category_id;
GO

-- 4. Fallback for any category_id that appeared only in transactions
INSERT INTO MRR.DimMerchantCategories (merchant_category_id, category_4)
SELECT DISTINCT 
    merchant_category_id,
    'Undefined' AS category_4
FROM (
    SELECT merchant_category_id FROM MRR.stg_historical_transactions
    UNION ALL
    SELECT merchant_category_id FROM MRR.stg_new_merchant_transactions
) T
WHERE merchant_category_id IS NOT NULL
  AND merchant_category_id NOT IN (SELECT merchant_category_id FROM MRR.DimMerchantCategories);
GO

-- 3.5 DimMerchant
CREATE TABLE MRR.DimMerchant (
    merchant_id          NVARCHAR(50) PRIMARY KEY,
    merchant_group_id    INT,
    merchant_category_id INT
);

WITH DeduplicatedMerchants AS (
    SELECT
        merchant_id,
        merchant_group_id,
        merchant_category_id,
        ROW_NUMBER() OVER (PARTITION BY merchant_id ORDER BY (SELECT NULL)) AS rn
    FROM MRR.stg_merchants
)
INSERT INTO MRR.DimMerchant (merchant_id, merchant_group_id, merchant_category_id)
SELECT
    merchant_id,
    merchant_group_id,
    merchant_category_id
FROM DeduplicatedMerchants
WHERE rn = 1;

-- Fallback for Missing/Undefined Merchant
IF NOT EXISTS (SELECT 1 FROM MRR.DimMerchant WHERE merchant_id = 'Undefined')
BEGIN
    INSERT INTO MRR.DimMerchant (merchant_id, merchant_group_id, merchant_category_id)
    VALUES ('Undefined', NULL, NULL);
END;
GO

-- 3.6 DimCard
CREATE TABLE MRR.DimCard (
    card_id            NVARCHAR(50) PRIMARY KEY,
    first_active_month DATE,
    feature_1          INT,
    feature_2          INT,
    feature_3          INT,
    target             FLOAT
);

TRUNCATE TABLE MRR.DimCard;
GO

-- 1. Insert cards from train (with target)
INSERT INTO MRR.DimCard (card_id, first_active_month, feature_1, feature_2, feature_3, target)
SELECT 
    card_id,
    first_active_month,
    feature_1,
    feature_2,
    feature_3,
    target
FROM MRR.stg_train;

-- 2. Insert cards from test (target will be NULL)
INSERT INTO MRR.DimCard (card_id, first_active_month, feature_1, feature_2, feature_3, target)
SELECT 
    card_id,
    first_active_month,
    feature_1,
    feature_2,
    feature_3,
    NULL AS target
FROM MRR.stg_test
WHERE card_id NOT IN (SELECT card_id FROM MRR.DimCard);

-- 3. Safety Fallback: Capture any orphan card_ids appearing only in transaction logs
INSERT INTO MRR.DimCard (card_id, first_active_month, feature_1, feature_2, feature_3, target)
SELECT DISTINCT 
    card_id,
    NULL AS first_active_month,
    NULL AS feature_1,
    NULL AS feature_2,
    NULL AS feature_3,
    NULL AS target
FROM (
    SELECT card_id FROM MRR.stg_historical_transactions
    UNION
    SELECT card_id FROM MRR.stg_new_merchant_transactions
) T
WHERE card_id IS NOT NULL
  AND card_id NOT IN (SELECT card_id FROM MRR.DimCard);
GO

/* ==============================================================================
   VALIDATION 3: PRE-LOAD ORPHAN RECORD & INTEGRITY AUDIT
   Verifies that all foreign keys exist in dimensions prior to loading Fact.
   Every orphan count must be 0 to prevent constraint violations.
   ============================================================================== */
WITH AllStagingTransactions AS (
    SELECT 
        merchant_id, 
        merchant_category_id, 
        city_id, 
        subsector_id, 
        CAST(purchase_date AS DATE) AS purchase_date,
        card_id
    FROM MRR.stg_historical_transactions
    UNION ALL
    SELECT 
        merchant_id, 
        merchant_category_id, 
        city_id, 
        subsector_id, 
        CAST(purchase_date AS DATE) AS purchase_date,
        card_id
    FROM MRR.stg_new_merchant_transactions
)
SELECT 
    SUM(CASE WHEN DM.merchant_id IS NULL THEN 1 ELSE 0 END)          AS Orphan_Merchants,
    SUM(CASE WHEN MC.merchant_category_id IS NULL THEN 1 ELSE 0 END) AS Orphan_MerchantCategories,
    SUM(CASE WHEN DL.LocationKey IS NULL THEN 1 ELSE 0 END)          AS Orphan_Locations,
    SUM(CASE WHEN DS.subsector_id IS NULL THEN 1 ELSE 0 END)         AS Orphan_Subsectors,
    SUM(CASE WHEN DD.FullDate IS NULL THEN 1 ELSE 0 END)             AS Orphan_PurchaseDates,
    SUM(CASE WHEN DC.card_id IS NULL THEN 1 ELSE 0 END)              AS Orphan_Cards
FROM AllStagingTransactions T
LEFT JOIN MRR.DimMerchant DM 
    ON T.merchant_id = DM.merchant_id
LEFT JOIN MRR.DimMerchantCategories MC 
    ON T.merchant_category_id = MC.merchant_category_id
LEFT JOIN MRR.DimLocation DL 
    ON T.city_id = DL.city_id
LEFT JOIN MRR.DimSubsector DS 
    ON T.subsector_id = DS.subsector_id
LEFT JOIN MRR.DimDate DD 
    ON T.purchase_date = DD.FullDate
LEFT JOIN MRR.DimCard DC 
    ON T.card_id = DC.card_id;
GO


/* ==============================================================================
   PHASE 4: BUILD & POPULATE FACT TABLE (MRR.FactTransactions)
   ============================================================================== */

CREATE TABLE MRR.FactTransactions (
    transaction_key      INT IDENTITY(1,1) PRIMARY KEY,
    
    -- Foreign Keys
    merchant_id          NVARCHAR(50) FOREIGN KEY REFERENCES MRR.DimMerchant(merchant_id),
    merchant_category_id INT          FOREIGN KEY REFERENCES MRR.DimMerchantCategories(merchant_category_id),
    city_id		         INT          FOREIGN KEY REFERENCES MRR.DimLocation(city_id),
    subsector_id         INT          FOREIGN KEY REFERENCES MRR.DimSubsector(subsector_id),
    purchase_date        DATE         FOREIGN KEY REFERENCES MRR.DimDate(FullDate),
    card_id              NVARCHAR(50) FOREIGN KEY REFERENCES MRR.DimCard(card_id),
    
    -- Transaction-level Attributes / Degenerate Dimensions
    authorized_flag      VARCHAR(1),
    category_1           VARCHAR(1),
    category_2           INT,
    category_3           VARCHAR(10),
    transaction_type     VARCHAR(12),
    
    -- Metrics / Additive Measures
    installments         INT,
    month_lag            INT,
    purchase_amount      DECIMAL(18, 4)
);

-- Data Insertion

-- 1. Wipe previous loads
TRUNCATE TABLE MRR.FactTransactions;
GO

-- 2. Disable constraints for fast load
ALTER TABLE MRR.FactTransactions NOCHECK CONSTRAINT ALL;
GO

-- 3. Cache fallback key
DECLARE @FallbackCity INT = -1;

-- 4. Bulk Insert
INSERT INTO MRR.FactTransactions WITH (TABLOCK) (
    merchant_id,
    merchant_category_id,
    city_id,
    subsector_id,
    purchase_date,
    card_id,
    authorized_flag,
    category_1,
    category_2,
    category_3,
    installments,
    month_lag,
    purchase_amount,
    transaction_type
)
SELECT
    T.merchant_id,
    T.merchant_category_id,
    COALESCE(L.city_id, @FallbackCity) AS city_id,
    T.subsector_id,
    CAST(T.purchase_date AS DATE),
    T.card_id,
    T.authorized_flag,
    T.category_1,
    T.category_2,
    T.category_3,
    T.installments,
    T.month_lag,
    T.purchase_amount,
    T.transaction_type
FROM (
    SELECT *, 'Historical' AS transaction_type FROM MRR.stg_historical_transactions
    UNION ALL
    SELECT *, 'New' AS transaction_type FROM MRR.stg_new_merchant_transactions
) T
LEFT JOIN MRR.DimLocation L
    ON T.city_id = L.city_id;
GO

-- 5. Re-enable and validate all constraints
ALTER TABLE MRR.FactTransactions WITH CHECK CHECK CONSTRAINT ALL;
GO

/* ==============================================================================
   VALIDATION 4: POST-LOAD FACT RECONCILIATION & INTEGRITY
   Verifies row counts, metric consistency, and non-null key integrity
   ============================================================================== */
SELECT 
    (SELECT COUNT(*) FROM MRR.stg_historical_transactions) + 
    (SELECT COUNT(*) FROM MRR.stg_new_merchant_transactions) AS Total_Staging_Transactions,
    
    (SELECT COUNT(*) FROM MRR.FactTransactions) AS Fact_Total_Transactions,
    
    ((SELECT COUNT(*) FROM MRR.stg_historical_transactions) + 
     (SELECT COUNT(*) FROM MRR.stg_new_merchant_transactions)) - 
     (SELECT COUNT(*) FROM MRR.FactTransactions) AS Load_Row_Discrepancy,

    -- Measure reconciliation
    (SELECT ROUND(SUM(CAST(purchase_amount AS DECIMAL(18, 4))), 2) 
     FROM (SELECT purchase_amount FROM MRR.stg_historical_transactions 
           UNION ALL 
           SELECT purchase_amount FROM MRR.stg_new_merchant_transactions) S) AS Staging_Total_Spend,
           
    (SELECT ROUND(SUM(purchase_amount), 2) FROM MRR.FactTransactions) AS Fact_Total_Spend;

-- Grain and key completeness verification
SELECT 
    COUNT(*)                                                      AS Total_Fact_Rows,
    COUNT(DISTINCT transaction_key)                               AS Unique_Transaction_Keys,
    SUM(CASE WHEN merchant_id IS NULL THEN 1 ELSE 0 END)          AS Null_Merchants,
    SUM(CASE WHEN merchant_category_id IS NULL THEN 1 ELSE 0 END) AS Null_Categories,
    SUM(CASE WHEN city_id IS NULL THEN 1 ELSE 0 END)         AS Null_Locations,
    SUM(CASE WHEN subsector_id IS NULL THEN 1 ELSE 0 END)         AS Null_Subsectors,
    SUM(CASE WHEN purchase_date IS NULL THEN 1 ELSE 0 END)        AS Null_PurchaseDates,
    SUM(CASE WHEN card_id IS NULL THEN 1 ELSE 0 END)              AS Null_Cards
FROM MRR.FactTransactions;
GO

/* ==============================================================================
   PHASE 5: VIEWS FOR POWER BI
   ============================================================================== */

DROP VIEW IF EXISTS MRR.vw_CardCohortAnalytics;
DROP VIEW IF EXISTS MRR.vw_MerchantCategoryAnalytics;
DROP VIEW IF EXISTS MRR.vw_GeographicSpending;
GO

/* ------------------------------------------------------------------------------
   PAGE 1: GEOGRAPHIC SPENDING & REGIONAL EXPANSION
   - Target: Maps, City/State breakdowns, Volume KPIs, Auth flags
   ------------------------------------------------------------------------------ */
CREATE VIEW MRR.vw_GeographicSpending
AS
SELECT
    F.purchase_date,            -- Relates to DimDate[FullDate]
    F.city_id,
    L.state_id,
    F.authorized_flag,
    F.transaction_type,
    F.category_1,
    F.category_2,
    F.category_3,
    F.purchase_amount,
    F.installments

FROM MRR.FactTransactions F
LEFT JOIN MRR.DimLocation L 
    ON F.city_id = L.city_id;
GO

/* ------------------------------------------------------------------------------
   PAGE 2: MERCHANT & CATEGORY ANALYTICS
   - Target: Merchant ranking, Subsectors, Category 4, Reach & Decline rates
   ------------------------------------------------------------------------------ */
CREATE VIEW MRR.vw_MerchantCategoryAnalytics
AS
SELECT
    F.purchase_date,            -- Relates to DimDate[FullDate]
    F.merchant_id,
    F.merchant_category_id,
    MC.category_4,
    F.subsector_id,
    F.authorized_flag,
    F.transaction_type,
    F.card_id,
    F.purchase_amount

FROM MRR.FactTransactions F
LEFT JOIN MRR.DimMerchantCategories MC 
    ON F.merchant_category_id = MC.merchant_category_id;
GO

/* ------------------------------------------------------------------------------
   PAGE 3: CARDHOLDER COHORTS & LOYALTY ENGAGEMENT
   - Target: Feature segments, Target loyalty score, month_lag decay
   ------------------------------------------------------------------------------ */
CREATE VIEW MRR.vw_CardCohortAnalytics
AS
SELECT
    F.purchase_date,            -- Relates to DimDate[FullDate]
    C.first_active_month,
    C.feature_1,
    C.feature_2,
    C.feature_3,
    C.target,
    F.month_lag,
    F.authorized_flag,
    F.purchase_amount,
    F.installments

FROM MRR.FactTransactions F
INNER JOIN MRR.DimCard C 
    ON F.card_id = C.card_id;
GO