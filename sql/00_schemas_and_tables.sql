
/* ====================================================================================
File: 00_create_schemas_and_raw_tables.sql

Purpose:
Create the database, schemas, and raw table 

Input: transaction_data.csv
Output: 
- 1 database: dunnhumby_completejourney
- 2 schemas: raw and analytics
- 1 table: raw.transaction
======================================================================================= */

/* ==========================================================
1. Create database and schemas
============================================================= */
-- Create the database
CREATE DATABASE IF NOT EXISTS dunnhumby_completejourney;
-- Create two schemas
CREATE SCHEMA IF NOT EXISTS raw; 
CREATE SCHEMA IF NOT EXISTS analytics;
-- Check if schemas were created successfully
SELECT schema_name
FROM information_schema.schemata 
WHERE schema_name IN ('raw', 'analytics');

/* ==========================================================
2. Import CSV files and create raw data tables 
============================================================= */
-- Create raw.transactions
CREATE TABLE IF NOT EXISTS raw.transactions (
    household_key       INTEGER,
    basket_id           BIGINT, 
    day                 SMALLINT,
    product_id          INTEGER,
    quantity            INTEGER,
    sales_value         NUMERIC(12,2),
    store_id            INTEGER,
    retail_disc         NUMERIC(12,2),
    trans_time          SMALLINT,
    week_no             SMALLINT,
    coupon_disc         NUMERIC(12,2),
    coupon_match_disc   NUMERIC(12,2)
);

-- Check row count, first records, and all required columns*/
SELECT COUNT(*) AS imported_rows
FROM raw.transactions;

SELECT * 
FROM raw.transactions
LIMIT 20;

SELECT
    ordinal_position,
    column_name,
    data_type,
    numeric_precision,
    numeric_scale
FROM information_schema.columns
WHERE table_schema = 'raw'
  AND table_name = 'transactions'
ORDER BY ordinal_position;


