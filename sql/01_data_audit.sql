/*=================================================================================
FILE: 01_data_audit.sql

PURPOSE: Inspect raw.transactions to understand and validate data. 
	- Check grain, NULLs, duplicates, 
	- Understand households - baskets - product lines - stores 
	- Check quantity/sales anomalies, discounts, trans_time, day/week consistency
SOURCE: raw.transactions
	- N=2,595,732 rows/ observations. One row = product purchase/receipt line. 
	- There are 2,500 unique households. 
	- Each household can have many purchase baskets. Each basket contains one or more product-level records.
	
===================================================================================*/


-- 1. OVERVIEW/ GRAIN/ COUNTS
-- Inspect a small sample
SELECT *
FROM raw.transactions
LIMIT 10;

-- Basic dataset dimensions and time coverage
SELECT
    COUNT(*) AS transaction_rows,                 -- 2,595,732 product-level transaction lines
    COUNT(DISTINCT household_key) AS households,  -- 2,500 unique households
    COUNT(DISTINCT basket_id) AS baskets,         -- 276,484 unique baskets
    COUNT(DISTINCT product_id) AS products,       -- 92,339 unique products
    COUNT(DISTINCT store_id) AS stores,           -- 582 unique stores
    MIN(day) AS first_day,                        -- day 1 (day is a sequential day counter)  
    MAX(day) AS last_day,						  -- day 711	
    MIN(week_no) AS first_week,                   -- Week 1        
    MAX(week_no) AS last_week        			  -- Week 102
FROM raw.transactions;

-----------------------------------------------------------------------------------
-- 2. CHECK MISSING VALUS (NULL)
-- Confirmed: no NULLs in all columns
SELECT
    COUNT(*) FILTER (WHERE household_key IS NULL) AS null_household_key,
    COUNT(*) FILTER (WHERE basket_id IS NULL) AS null_basket_id,
    COUNT(*) FILTER (WHERE day IS NULL) AS null_day,
    COUNT(*) FILTER (WHERE week_no IS NULL) AS null_week_no,
    COUNT(*) FILTER (WHERE product_id IS NULL) AS null_product_id,
    COUNT(*) FILTER (WHERE quantity IS NULL) AS null_quantity,
    COUNT(*) FILTER (WHERE sales_value IS NULL) AS null_sales_value,
    COUNT(*) FILTER (WHERE store_id IS NULL) AS null_store_id,
    COUNT(*) FILTER (WHERE trans_time IS NULL) AS null_trans_time,
    COUNT(*) FILTER (WHERE retail_disc IS NULL) AS null_retail_disc,
    COUNT(*) FILTER (WHERE coupon_disc IS NULL) AS null_coupon_disc,
    COUNT(*) FILTER (WHERE coupon_match_disc IS NULL) AS null_coupon_match_disc
FROM raw.transactions;

-----------------------------------------------------------------------------------
-- 3. CHECK TIME COVERAGE & TIME COLUMNS
-- Inspect weekly coverage
-- Confirmed: week_no is continuous from 1 to 102 
SELECT
    week_no,
    MIN(day) AS minimum_day,
    MAX(day) AS maximum_day,
    COUNT(DISTINCT day) AS observed_days,
    COUNT(*) AS product_lines,
    COUNT(DISTINCT basket_id) AS baskets,
    COUNT(DISTINCT household_key) AS households
FROM raw.transactions
GROUP BY week_no
ORDER BY week_no;

-- Check whether each day maps to exactly one week_no.
-- Result: 0 rows. Confirmed: each day map to exactly one week
SELECT
    day,
    COUNT(DISTINCT week_no) AS week_count
FROM raw.transactions
GROUP BY day
HAVING COUNT(DISTINCT week_no) > 1; 

-- Inspect whether week 79 follows week 78 for later in-sample / holdout split.
-- Confirmed: Week 78 → Days 538–544. Week 79 → Days 545–551
SELECT
    week_no,
    MIN(day) AS minimum_day,
    MAX(day) AS maximum_day,
    COUNT(DISTINCT day) AS observed_days
FROM raw.transactions
WHERE week_no BETWEEN 76 AND 81
GROUP BY week_no
ORDER BY week_no;

-----------------------------------------------------------------------------------
-- 4. INSPECT BASKET
-- Check whether basket_id can safely be treated as one shopping occasion?

/* Check whether each basket is associcated with with exactly one:
	- household, 
	- day, 
	- week, 
	- store,
	- transaction time (HHMM)
Confirmed that each basket_id is associcated with exaclty one household, one day, one week, 
one store, and one transaction time.
*/
WITH basket_inspection AS (
    SELECT
        basket_id,                                      -- For each basket_id: 
        COUNT(DISTINCT household_key) AS households,    -- how many unique households are linked to the basket
        COUNT(DISTINCT day) AS days,					-- how many unique days are linked to the basket				
        COUNT(DISTINCT week_no) AS weeks,               -- how many unique weeks are linked to the basket
        COUNT(DISTINCT store_id) AS stores,             -- how many unique stores are linked to the basket 
		COUNT(DISTINCT trans_time) AS transaction_times -- how many unique stores are linked to the basket 
    FROM raw.transactions
    GROUP BY basket_id
)
SELECT
    COUNT(*) AS baskets_checked,
    COUNT(*) FILTER (WHERE households > 1) AS multi_household_baskets,        -- 0
    COUNT(*) FILTER (WHERE days > 1) AS multi_day_baskets,                    -- 0
    COUNT(*) FILTER (WHERE weeks > 1) AS multi_week_baskets,                  -- 0
    COUNT(*) FILTER (WHERE stores > 1) AS multi_store_baskets,                -- 0
	COUNT(*) FILTER (WHERE transaction_times > 1) AS multi_trans_time_baskets -- 0
FROM basket_inspection;


-- Check whether the same product_id occurs on multiple transaction (product-level) lines within a basket.
-- Confirmed: 0 baskets with repeated products
SELECT
    COUNT(*) AS baskets_with_repeated_product
FROM (
    SELECT
        basket_id
    FROM raw.transactions
    GROUP BY basket_id
    HAVING COUNT(*) > COUNT(DISTINCT product_id)
);


-- Inspect the distribution of product-level lines per basket
-- to understand the basket-size distribution. 
WITH basket_sizes AS (
    SELECT
        basket_id,
        COUNT(*) AS product_lines
    FROM raw.transactions
    GROUP BY basket_id
)

SELECT
    MIN(product_lines) AS min_product_lines, -- 1
    AVG(product_lines) AS avg_product_lines, -- 9.38836

    PERCENTILE_CONT(0.50)
        WITHIN GROUP (ORDER BY product_lines)
        AS median_product_lines,             -- 5

    PERCENTILE_CONT(0.90)
        WITHIN GROUP (ORDER BY product_lines)
        AS p90_product_lines,                -- 24

    PERCENTILE_CONT(0.99)
        WITHIN GROUP (ORDER BY product_lines)
        AS p99_product_lines,                -- 58

    MAX(product_lines) AS max_product_lines  -- 168 (!)

FROM basket_sizes;

-----------------------------------------------------------------------------------
-- 5. CHECK DUPLICATES
-- Check exact duplicates (whose every column has identical values)
-- Confirmed: duplicate_groups = 0 and extra_duplicate_rows = 0
WITH duplicate_groups AS (
    SELECT
        household_key,
        basket_id,
        day,
        product_id,
        quantity,
        sales_value,
        store_id,
        retail_disc,
        trans_time,
        week_no,
        coupon_disc,
        coupon_match_disc,
        COUNT(*) AS identical_rows   -- count how many identical rows are in each group.   
    FROM raw.transactions
    GROUP BY
        household_key,
        basket_id,
        day,
        product_id,
        quantity,
        sales_value,
        store_id,
        retail_disc,
        trans_time,
        week_no,
        coupon_disc,
        coupon_match_disc
    HAVING COUNT(*) > 1              -- keep only groups where there is more than one identical row.
)
SELECT
    COUNT(*) AS duplicated_patterns, -- count the number of row patterns that repeat
    COALESCE(SUM(identical_rows - 1), 0) AS extra_rows  -- e.g. identical_rows = 3 -> extra_rows = 3 - 1 = 2; otherwise 0 
FROM duplicate_groups;


-----------------------------------------------------------------------------------
-- 6. CHECK QUANTITY & SALES VALUE 
/* 
quantity = recorded quantity of the product represented by a row (a product-line)
sales_value = amount received by the retailer for that product-line sale.
sales_value is not necessarily equal to customer out-of-pocket spending
when a manufacturer coupon is used.
*/
-- Inspect the quantity distribution and extreme values.
SELECT
    COUNT(*) FILTER (WHERE quantity < 0) AS negative_quantity_rows, -- 0 rows
    COUNT(*) FILTER (WHERE quantity = 0) AS zero_quantity_rows,     -- 14,466 rows (!)
	COUNT(*) FILTER (WHERE quantity > 0) AS positive_quantity,      -- 2,581,266 rows
    COUNT(*) FILTER (WHERE quantity > 100) AS quantity_over_100,    -- 23,136 rows
    COUNT(*) FILTER (WHERE sales_value < 0) AS negative_sales_rows, -- 0 rows with negative sales value  
    COUNT(*) FILTER (WHERE sales_value = 0) AS zero_sales_rows,     -- 18,879 rows with zero sales value
    MIN(quantity) AS minimum_quantity,        									-- 0 
	ROUND(AVG(quantity), 2) AS average_quantity,                                -- 100.43
	PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY quantity) AS median_quantity,  -- 1
	PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY quantity) AS p99_quantity,     -- 10
    MAX(quantity) AS maximum_quantity       									-- 89,638 is a single product-line quantity. (!) An extreme value, not the total number of products in a basket.
FROM raw.transactions;


-- Inspect the sales-value distribution.
SELECT
	COUNT(*) FILTER (WHERE sales_value < 0) AS negative_sales,  -- 0 rows
    COUNT(*) FILTER (WHERE sales_value = 0) AS zero_sales,      -- 18879 rows
    COUNT(*) FILTER (WHERE sales_value > 0) AS positive_sales,  -- 2,576,853 rows
    MIN(sales_value) AS min_sales,                                            -- $ 0.00 is the min sales value
	ROUND(AVG(sales_value), 2) AS average_quantity,                           -- $ 3.10 is the avg sales value
    PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY sales_value) AS p01_sales,   -- $ 0.2
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY sales_value) AS median_sales,-- $ 2 is the median sales value
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY sales_value) AS p99_sales,   -- $ 20 
    MAX(sales_value) AS max_sales                                             -- $ 840.00 is the max sales value
FROM raw.transactions;


-----------------------------------------------------------------------------------
-- 7. INSPECT ROWS WITH QUANTITY = 0
-- Investigate zero-quantity rows (product-line level)
/* Confirmed:
14,466 product-level rows have quantity = 0.
These rows affect:
- 12,583 baskets
- 1,991 households
- 4,244 products
Most zero-quantity rows also have sales_value = 0.
*/
SELECT
    COUNT(*) AS zero_quantity_rows,                       -- 14,466 rows 
    COUNT(DISTINCT basket_id) AS affected_baskets,        -- 12,538 baskets
    COUNT(DISTINCT household_key) AS affected_households, -- 1,991 households
    COUNT(DISTINCT product_id) AS affected_products,      -- 4,244 products

    COUNT(*) FILTER (WHERE sales_value < 0) AS negative_sales,  -- 0 rows
    COUNT(*) FILTER (WHERE sales_value = 0) AS zero_sales,      -- 14,428 rows with zero-quantity and zero-sales
    COUNT(*) FILTER (WHERE sales_value > 0) AS positive_sales,  -- 38 rows with zero-quantity but positive sales (!)

    MIN(sales_value) AS min_sales,   -- $ 0.00 
    MAX(sales_value) AS max_sales    -- $ 5.82
FROM raw.transactions
WHERE quantity = 0;

-- Inspect zero-quantity rows and their discount activity
/* Confirmed: 
Among the 14,466 zero-quantity rows:
	- 9,500 rows (65.7%) have no recorded discounts.
	- 4,955 rows (34.3%) have a manufacturer coupon discount.
	- 11 rows (0.11%) have a retail loyalty discount.
	- 0 have a coupon-match discount.
This suggests that at least some zero-quantity rows may
represent promotional, coupon-related, or transaction-adjustment
records rather than ordinary physical product purchases.
E.g., 
product_id       some product
quantity         0
sales_value      0
coupon_disc     -1.00
 */
SELECT
    COUNT(*) AS zero_quantity_rows,   -- 14,466 rows

    COUNT(*) FILTER (                 -- 11 rows
        WHERE retail_disc <> 0
    ) AS retail_discount_rows,

    COUNT(*) FILTER (                 -- 4,955 rows
        WHERE coupon_disc <> 0
    ) AS coupon_discount_rows,

    COUNT(*) FILTER (                 -- 0 rows 
        WHERE coupon_match_disc <> 0
    ) AS coupon_match_rows,

    COUNT(*) FILTER (                 -- 9,500 rows 
        WHERE retail_disc = 0
          AND coupon_disc = 0
          AND coupon_match_disc = 0
    ) AS no_discount_rows
FROM raw.transactions
WHERE quantity = 0;


-- Check 38 rows (product-line level) with zero-quantity but positive sales (!)
SELECT
    household_key,
    basket_id,
    day,
    product_id,
    quantity,
    sales_value,
    retail_disc,
    coupon_disc,
    coupon_match_disc,
    store_id
FROM raw.transactions
WHERE quantity = 0
  AND sales_value > 0
ORDER BY sales_value DESC;

-- Count the number of baskets contain only zero-quantity product rows.
/* Confirmed: 595 baskets.
Relative to 276,484 baskets, that is only about 0.2% of all baskets, 
so this is a small edge case. 
These baskets may not represent valid purchase occasions for BG/NBD 
if they contain no actually purchased positive-quantity items.
*/
WITH zero_quantity_only_baskets  AS (
    SELECT
        basket_id
    FROM raw.transactions
    GROUP BY basket_id
    HAVING MAX(quantity) = 0 
)

SELECT
    COUNT(*) AS zero_quantity_only_baskets    -- 595 baskets contain only zero-quantity product rows.
FROM zero_quantity_only_baskets;


-- Characterize 595 baskets containing quantity = 0
/*	- 416 households affected
	- 592 baskets with no positive sales at all
	-   3 baskets with some positive sales
*/
WITH zero_quantity_only_baskets AS (
    SELECT
        basket_id
    FROM raw.transactions
    GROUP BY basket_id
	HAVING MAX(quantity) = 0 
)

SELECT
    COUNT(DISTINCT t.basket_id) AS baskets,             -- 595 baskets contain only zero-quantity product rows.
    COUNT(DISTINCT t.household_key) AS households,      -- 416 households
    COUNT(*) AS zero_quantity_rows,                   	-- 706 rows with zero quantity
	 COUNT(*) FILTER (WHERE t.sales_value = 0) AS zero_sales_rows,     -- 703 rows with zero sales
    COUNT(*) FILTER (WHERE t.sales_value > 0) AS positive_sales_rows,  -- 3 rows with positive sales
    COUNT(DISTINCT t.basket_id) 
		FILTER (WHERE t.sales_value > 0
    	) AS baskets_with_positive_sales,               -- 3 baskets with positive sales
    SUM(t.sales_value) AS total_sales                   -- $ 0.43
FROM raw.transactions AS t
INNER JOIN zero_quantity_only_baskets AS b
	ON t.basket_id = b.basket_id;

/*
Decision:

A valid purchase occasion is defined as a basket containing
at least one product-level row with quantity > 0.

The 595 baskets containing no positive-quantity product rows
are retained in raw.transactions but will not be counted as
valid purchase occasions for BG/NBD modeling.

This preserves the raw source while making the analytical
purchase-event definition explicit and reproducible.
*/



-----------------------------------------------------------------------------------
-- 8. CHECK DISCOUNTS

-- Count product-level rows with each type of non-zero discount.
SELECT
    COUNT(*) FILTER (WHERE retail_disc <> 0) AS retail_disc_rows,                   -- retail loyality discount: 1,303,028
    COUNT(*) FILTER (WHERE coupon_disc <> 0) AS manufacturer_coupon_disc_rows,      -- manufacturer coupon discount: 36,422
    COUNT(*) FILTER (WHERE coupon_match_disc <> 0) AS retail_coupon_match_disc_rows -- retail coupon match discount: 17,449
FROM raw.transactions;

-- Check discount signs
/* 
Discount fields are expected to be:
- negative when a discount is recorded
- zero when no discount is recorded
*/
SELECT
    'retail_disc',
    COUNT(*) FILTER (WHERE retail_disc < 0) AS negative_rows,  
    COUNT(*) FILTER (WHERE retail_disc = 0) AS zero_rows,
    COUNT(*) FILTER (WHERE retail_disc > 0) AS positive_rows,   -- 10 positive values need inspection (!)
    MIN(retail_disc) AS minimum_value,
    MAX(retail_disc) AS maximum_value
FROM raw.transactions

UNION ALL  -- stack the results vertically.

SELECT
    'coupon_disc',
    COUNT(*) FILTER (WHERE coupon_disc < 0),
    COUNT(*) FILTER (WHERE coupon_disc = 0),
    COUNT(*) FILTER (WHERE coupon_disc > 0),
    MIN(coupon_disc),
    MAX(coupon_disc)
FROM raw.transactions

UNION ALL  -- stack the results vertically.

SELECT
    'coupon_match_disc',
    COUNT(*) FILTER (WHERE coupon_match_disc < 0),
    COUNT(*) FILTER (WHERE coupon_match_disc = 0),
    COUNT(*) FILTER (WHERE coupon_match_disc > 0),
    MIN(coupon_match_disc),
    MAX(coupon_match_disc)
FROM raw.transactions;


-- Inspect the 10 positive retail_disc rows 
/* Result: 
	- 8 of the 10 rows have QUANTITY = 0, only 2 rows have QUANTITY = 1
	- Several sales_value values are identical or very close to the positive retail royalty discount
	- None has a manufacturer coupon or retail coupon match discount
These could be potential transaction adjustments or exceptional records 
that require investigation, rather than ordinary retail discounts.
*/

SELECT
    household_key,
    basket_id,
    day,
    product_id,
    quantity,
    sales_value,
    retail_disc,
    coupon_disc,
    coupon_match_disc,
    store_id
FROM raw.transactions
WHERE retail_disc > 0
ORDER BY retail_disc DESC;

-- Inspect complete baskets containing positive retail_disc rows.
-- Check whether they are part of normal baskets/shopping trips
SELECT *
FROM raw.transactions
WHERE basket_id IN (
    SELECT DISTINCT basket_id
    FROM raw.transactions
    WHERE retail_disc > 0
)
ORDER BY basket_id, product_id;

-- Check whether those baskets contain normal purchased products 
SELECT
    basket_id,
    COUNT(*) AS total_rows,   -- 8 baskets
    COUNT(*) FILTER (WHERE quantity > 0) AS positive_quantity_rows,
    COUNT(*) FILTER (WHERE quantity = 0) AS zero_quantity_rows,
    SUM(quantity) AS total_quantity,
    SUM(sales_value) AS basket_sales
FROM raw.transactions
WHERE basket_id IN (
    SELECT DISTINCT basket_id
    FROM raw.transactions
    WHERE retail_disc > 0
)
GROUP BY basket_id
ORDER BY basket_id;

/* 
Result: These 10 positive retail_disc values occur across 8 baskets. 
All these 8 baskets contain normal purchases, indicating that 
they represent genuine shopping occasions rather than erroneous baskets. 

Decision: Not yet understood why these 10 product records have positive retailer discounts. 
> Keep them for now until understood
*/


-- Check relationships among the three discount fields. 
SELECT
    -- How many product-level rows have at least one non-zero discount field? 1,319,401
    COUNT(*) FILTER (
        WHERE retail_disc <> 0
           OR coupon_disc <> 0
           OR coupon_match_disc <> 0
    ) AS product_lines_with_any_discount,
    -- Exception check: coupon match recorded without a manufacturer coupon: 0
    COUNT(*) FILTER (
        WHERE coupon_match_disc <> 0
          AND coupon_disc = 0
    ) AS match_without_manufacturer_coupon,

    -- Exception check: retailer coupon-match magnitude exceeds the manufacturer-coupon magnitude: 23 (!) 
    COUNT(*) FILTER (
        WHERE ABS(coupon_match_disc)
              > ABS(coupon_disc)
    ) AS match_greater_than_manufacturer_coupon
FROM raw.transactions;


-- Inspect 23 coupon-match amount exceptions (!)
SELECT *
FROM raw.transactions

WHERE ABS(ROUND(coupon_match_disc, 2))
      > ABS(ROUND(coupon_disc, 2))

ORDER BY basket_id;


-----------------------------------------------------------------------------------
-- 9. CHECK TRANSACTION TIME 
/*
Purpose:
Determine whether trans_time can provide within-day timing
for BG/NBD purchase baskkets/shopping occasions.
*/

-- Check transaction-time range and missing values.
SELECT
    MIN(trans_time) AS min_trans_time,   -- 0
    MAX(trans_time) AS max_trans_time,   -- 2359

    COUNT(*) FILTER (
        WHERE trans_time IS NULL
    ) AS null_trans_times,

    COUNT(DISTINCT trans_time)
        AS distinct_trans_times          -- 1440 disinct values

FROM raw.transactions;

-- Check whether observed trans_time values are consistent with HHMM encoding.
-- Confirmed: invalid_hhmm_values = 0. The observed values are consistent with HHMM encoding.
SELECT
    COUNT(*) FILTER (
        WHERE trans_time < 0
           OR trans_time > 2359
           OR MOD(trans_time, 100) > 59
    ) AS invalid_hhmm_values

FROM raw.transactions;


-- Check whether each basket has exactly one transaction time.
-- Confirmed: 0 baskets with multiple transaction times.
SELECT
    COUNT(*) AS baskets_with_multiple_trans_times

FROM (
    SELECT
        basket_id
    FROM raw.transactions
    GROUP BY basket_id

    HAVING COUNT(DISTINCT trans_time) > 1
);

-- Check whether any basket lacks a recorded transaction time.
-- Confirmed: 0 baskets.
SELECT
    COUNT(*) AS baskets_without_trans_time

FROM (
    SELECT
        basket_id
    FROM raw.transactions
    GROUP BY basket_id

    HAVING COUNT(trans_time) = 0
);



---------------------------------------------------------------------------
-- 10. CHECK EXTREME/ UNUSUAL OBSERVATIONS

-- Inspect selected unusual quantity and sales observations.
-- This is exploratory and does not imply that these rows are erroneous.
SELECT *
FROM raw.transactions

WHERE quantity <= 0
   OR sales_value <= 0
   OR quantity > 100
   OR sales_value > 1000

ORDER BY
    ABS(sales_value) DESC,
    ABS(quantity) DESC

LIMIT 100;


-- Summarize the number of rows meeting each unusual-value condition.
-- Summarize the number and percentage of rows meeting each unusual-value condition.
SELECT
    COUNT(*) AS total_rows,

    COUNT(*) FILTER (WHERE quantity = 0) AS zero_quantity_rows,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE quantity = 0) / COUNT(*),
        2
    ) AS zero_quantity_pct,

    COUNT(*) FILTER (WHERE quantity > 100) AS quantity_over_100_rows,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE quantity > 100) / COUNT(*),
        2
    ) AS quantity_over_100_pct,

    COUNT(*) FILTER (WHERE sales_value = 0) AS zero_sales_rows,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE sales_value = 0) / COUNT(*),
        2
    ) AS zero_sales_pct,

    COUNT(*) FILTER (WHERE sales_value > 1000) AS sales_over_1000_rows,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE sales_value > 1000) / COUNT(*),
        2
    ) AS sales_over_1000_pct

FROM raw.transactions;

/* =========================================================
Documented data-quality decisions

1. Raw grain
One raw row represents one product-level transaction line.
It does not represent one shopping trip.

2. Purchase occasion
basket_id is treated as the shopping/purchase occasion after
confirming that each basket belongs to one household, day,
week, and store.

3. Raw source preservation
raw.transactions remains unchanged.

4. Zero-quantity records
14,466 rows have quantity = 0.

595 baskets contain no positive-quantity product lines.
These baskets are retained in the raw layer but are not
treated as valid purchase occasions for BG/NBD.

A valid purchase basket therefore contains at least one row
with quantity > 0.

5. Discount signs
coupon_disc and coupon_match_disc follow the expected
zero-or-negative sign convention.

10 positive retail_disc rows were investigated. They occur
within otherwise valid shopping baskets and are retained.

6. Monetary precision
Discount amounts are interpreted at normal two-decimal
currency precision.

7. Transaction time
trans_time values are consistent with HHMM encoding and each
basket has one recorded transaction time.

The basket-level analytical layer will therefore retain
basket_day and basket_trans_time for purchase timing.
========================================================= 

01_data_audit.sql
    Raw grain, integrity, anomalies
            ↓
02_build_basket_fact.sql
    Project parameters
    + basket analytical layer
    + basket/cohort reconciliation
            ↓
03_build_customer_features.sql
    Purchase-event timing
    + x, t_x, T
    + historical profiles
            ↓
04_build_holdout_and_model_inputs.sql
    Future outcomes
    + model-input view
            ↓
Python
*/