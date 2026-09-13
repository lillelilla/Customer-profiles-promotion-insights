/*=================================================================================
FILE: 02_build_basket_fact.sql

PURPOSE:
1. Store the project in-sample and holdout time definitions
   in one parameter table.
2. Convert product-level transactions into one row per basket.
3. Validate basket counts and sales totals.
4. Check which households appear in the in-sample and holdout periods.

SOURCE: 
- raw.transactions
	(Grain: 1 row per household × basket × product record.
	 One product-level transaction line within a shopping basket)
OUTPUTS:
- analytics.project_parameters
- analytics.fact_basket
	(Grain: 1 row per household × basket. 
	 One row represents one shopping basket/purchase occasion)

DEPENDENCIES: 01_data_audit.sql should be completed first.

IMPORTANT: raw.transactions is not modified.

RUN THIS FILE BEFORE:
- 03_build_customer_features.sql
- 04_build_holdout_and_model_inputs.sql

===================================================================================*/


-- 1. CREATE PROJECT PARAMETERS
-- Create the parameter table
/*
Store the in-sample and holdout definitions once so that 
later queries use a consistent time split.
This project currently uses one parameter set only,
identified by parameter_id = 1.
*/

CREATE TABLE IF NOT EXISTS analytics.project_parameters (
    parameter_id            SMALLINT PRIMARY KEY,
    in_sample_end_week      SMALLINT NOT NULL,
    holdout_start_week      SMALLINT NOT NULL,
    holdout_end_week        SMALLINT NOT NULL,
    in_sample_end_day       SMALLINT NOT NULL,
    holdout_start_day       SMALLINT NOT NULL,
    holdout_end_day         SMALLINT NOT NULL,
    holdout_weeks           SMALLINT NOT NULL,
    CHECK (parameter_id = 1)
);

-- Insert/update the values
/*
Insert/update the project's time parameters.
Week boundaries are fixed as following:
- In-sample ends at week 78.
- Holdout begins at week 79.
- Holdout ends at week 102.

The corresponding day boundaries are derived from the
observed DAY values in raw.transactions.
*/
INSERT INTO analytics.project_parameters (
    parameter_id,
    in_sample_end_week,
    holdout_start_week,
    holdout_end_week,
    in_sample_end_day,
    holdout_start_day,
    holdout_end_day,
    holdout_weeks
)

SELECT
    1,
    78,
    79,
    102,

    MAX(day) FILTER (
        WHERE week_no = 78
    ) AS in_sample_end_day,

    MIN(day) FILTER (
        WHERE week_no = 79
    ) AS holdout_start_day,

    MAX(day) FILTER (
        WHERE week_no = 102
    ) AS holdout_end_day,

    24

FROM raw.transactions

ON CONFLICT (parameter_id)
DO UPDATE SET
    in_sample_end_week = EXCLUDED.in_sample_end_week,
    holdout_start_week = EXCLUDED.holdout_start_week,
    holdout_end_week = EXCLUDED.holdout_end_week,
    in_sample_end_day = EXCLUDED.in_sample_end_day,
    holdout_start_day = EXCLUDED.holdout_start_day,
    holdout_end_day = EXCLUDED.holdout_end_day,
    holdout_weeks = EXCLUDED.holdout_weeks;
	

-----------------------------------------------------------------------------------
-- 2. VALIDATE PROJECT PARAMETERS
/*
Confirmed:

in_sample_end_week = 78
holdout_start_week = 79
holdout_end_week   = 102
in_sample_end_day  = 544
holdout_start_day  = 545
holdout_end_day    = 711
holdout_weeks      = 24

There is no unobserved day between the in-sample and
holdout periods.

The exact BG/NBD prediction horizon is 167 days:
711 - 544 = 167.
*/

SELECT
    parameter_id,

    in_sample_end_week,
    holdout_start_week,
    holdout_end_week,

    in_sample_end_day,
    holdout_start_day,
    holdout_end_day,

    holdout_weeks,

    -- Expected: 0
    holdout_start_week
        - in_sample_end_week
        - 1 AS unobserved_gap_weeks,

    -- Expected: 0
    holdout_start_day
        - in_sample_end_day
        - 1 AS unobserved_gap_days,

    -- Expected: 24
    holdout_end_week
        - holdout_start_week
        + 1 AS calculated_holdout_weeks,

    -- Days actually observed in holdout: 545 through 711
    -- Expected: 167
    holdout_end_day
        - holdout_start_day
        + 1 AS observed_holdout_days,

    -- Same 167-day horizon measured from continuous-time
    -- cutoff at the beginning of Day 545 (model time 544)
    holdout_end_day
        - in_sample_end_day
        AS prediction_horizon_days

FROM analytics.project_parameters

WHERE parameter_id = 1;


-----------------------------------------------------------------------------------
-- 3. Build analytics.fact_basket
/* 
OBJECTIVE: Convert product-level transaction rows into basket-level rows so that 
purchase frequency reflects shopping occasions rather than individual products.

SOURCE: raw.transactions (grain: 1 row = 1 product-level transaction line within a basket)
OUTPUT: analytics.fact_basket (grain: 1 row = 1 household × 1 basket
                                            = 1 shopping/purchase occasion)
EXAMPLE:
	raw.transactions
	
	Household 2375 | Basket A | Product 1
	Household 2375 | Basket A | Product 2
	Household 2375 | Basket A | Product 3
	Household 2375 | Basket B | Product 4
	Household 2375 | Basket B | Product 5
	
	                    ↓ GROUP BY
	
	analytics.fact_basket
	
	Household 2375 | Basket A | 3 products | total quantity | total sales
	Household 2375 | Basket B | 2 products | total quantity | total sales

IMPORTANT:
	- A valid purchase basket contains at least one product-level
	row with quantity > 0.
	- Zero-quantity rows are NOT removed before aggregation.
	This preserves coupon/promotion/adjustment records that may
	belong to otherwise valid shopping baskets.
	- Only baskets cntoaining entirely of zero-quantity rows
	are later excluded from the BG/NBD purchase-event definition.

MONETARY INTERPRETATION:
	sales_value 
		= recorded amount received by the retailer.
		It is not necessarily equal to customer out-of-pocket
		spending when manufacturer coupons are used.
	
	retail_disc 
		= retailer loyalty-card discount. Funded by the retailer.
	coupon_disc 
		= manufacturer-funded coupon discount. Funded by the manufacturer.
		This reduces customer payment, and manufacturer reimburses retailer.
	coupon_match_disc 
		= retailer-funded match of a manufacturer coupon. Funded by the retailer.
		
	
	Raw discounts are normally stored as negative values.
	Basket-level *_amount fields convert these to positive
	amounts for easier interpretation.
	
	estimated_pre_retail_discount_value
		= basket_sales_value
		  + retailer-funded loyalty-card discount
		  + retailer-funded coupon match.

	Note that estimated_pre_retail_discount_value restores 
	retailer-funded discounts only. It should NOT be interpreted as:
	- customer out-of-pocket spending, or
	- guaranteed product list/shelf price.
*/


DROP TABLE IF EXISTS analytics.fact_basket;

CREATE TABLE analytics.fact_basket AS

SELECT
    household_key,
    basket_id,

    -- Raw-data validation confirmed that each basket belongs
    -- to exactly one day, week, store, and transaction time.
    CAST(MIN(day) AS SMALLINT)
        AS basket_day,

    CAST(MIN(week_no) AS SMALLINT)
        AS basket_week,

    CAST(MIN(store_id) AS INTEGER)
        AS store_id,

    CAST(MIN(trans_time) AS SMALLINT)
        AS basket_trans_time,

    -- Number of raw product-level transaction lines
    -- contained in the basket.
    CAST(COUNT(*) AS INTEGER)
        AS basket_product_lines_count,

    -- Number of distinct product IDs in the basket.
    CAST(COUNT(DISTINCT product_id) AS INTEGER)
        AS basket_unique_product_count,

    -- Total recorded quantity across all product-level rows.
    CAST(SUM(quantity) AS BIGINT)
        AS basket_total_quantity,

    -- Total recorded retailer sales value for the basket.
    CAST(
        SUM(sales_value)
        AS NUMERIC(14,2)
    ) AS basket_sales_value,

    -- Convert normally negative raw retailer discounts
    -- into positive analytical amounts.
    CAST(
        -SUM(retail_disc)
        AS NUMERIC(14,2)
    ) AS retail_discount_amount,

    -- Convert normally negative manufacturer coupon values
    -- into positive analytical amounts.
    CAST(
        -SUM(coupon_disc)
        AS NUMERIC(14,2)
    ) AS manufacturer_coupon_amount,

    -- Convert normally negative retailer coupon-match values
    -- into positive analytical amounts.
    CAST(
        -SUM(coupon_match_disc)
        AS NUMERIC(14,2)
    ) AS retail_coupon_match_amount,

    -- Estimated basket value before retailer-funded discounts.
    --
    -- This restores retail_disc and coupon_match_disc.
    -- Manufacturer coupons are not added back because
    -- sales_value already represents the retailer-side
    -- recorded sales amount.
    CAST(
        SUM(sales_value)
        - SUM(retail_disc)
        - SUM(coupon_match_disc)
        AS NUMERIC(14,2)
    ) AS estimated_pre_retail_discount_value,

    -- Did the basket contain at least one normally encoded
    -- discount of each type?
    --
    -- Negative values represent the normal discount sign.
    -- Exceptional positive retail_disc records are retained
    -- but do not by themselves trigger has_retail_discount.
    BOOL_OR(retail_disc < 0)
        AS has_retail_discount,

    BOOL_OR(coupon_disc < 0)
        AS has_manufacturer_coupon,

    BOOL_OR(coupon_match_disc < 0)
        AS has_retail_coupon_match,

    -- A valid purchase occasion contains at least one
    -- product-level row with positive quantity.
    BOOL_OR(quantity > 0)
        AS is_valid_purchase_basket

FROM raw.transactions

GROUP BY
    household_key,
    basket_id;


-- Quick check the table 
SELECT * 
FROM analytics.fact_basket
LIMIT 2;


-----------------------------------------------------------------------------------
-- 4. ADD KEY, INDEXES, & STATISTICS
/* Composite primary key:
household_key + basket_id uniquely identifies one row in
analytics.fact_basket.
Although basket_id was confirmed to belong to one household,
the composite key explicitly reflects the analytical grain:
household × basket. 
*/

ALTER TABLE analytics.fact_basket
ADD CONSTRAINT pk_fact_basket            -- Add a rule named pk_fact_basket
PRIMARY KEY (household_key, basket_id);  -- These two columns together form the unique identifier for each row.


-- For in-sample / holdout day filters.
CREATE INDEX idx_fact_basket_day
    ON analytics.fact_basket (basket_day);

-- For household-level purchase histories ordered or filtered by day.
CREATE INDEX idx_fact_basket_household_day
    ON analytics.fact_basket (household_key, basket_day);

-- For weekly summaries and reporting.
CREATE INDEX idx_fact_basket_week
    ON analytics.fact_basket (basket_week);

	
-----------------------------------------------------------------------------------
-- 5. VALIDATE BASKET-TABLE GRAIN & ROW PRESERVATION
-- Validate basket-table grain 
SELECT *
FROM analytics.fact_basket
LIMIT 10;	

/* Check number of baskets in analytics.fact_basket vs. in raw.transactions
One raw basket_id should produce exactly one fact-table row.
Expected:
raw_distinct_baskets = 276,484
fact_basket_rows      = 276,484
difference            = 0
*/

SELECT
    raw.raw_distinct_baskets,
    fact.fact_basket_rows,

    fact.fact_basket_rows
        - raw.raw_distinct_baskets
        AS difference

FROM (
    SELECT
        COUNT(DISTINCT basket_id)
            AS raw_distinct_baskets
    FROM raw.transactions
) AS raw

CROSS JOIN (
    SELECT
        COUNT(*) AS fact_basket_rows
    FROM analytics.fact_basket
) AS fact;



/* Check whether every raw product-level transaction line was
included in exactly one basket aggregation.
Confirmed: sum of basket product lines = the number of raw transaction lines 
difference is 0
*/

SELECT
    raw.raw_transaction_lines,
    fact.fact_transaction_lines,

    fact.fact_transaction_lines
        - raw.raw_transaction_lines
        AS difference

FROM (
    SELECT
        COUNT(*) AS raw_transaction_lines
    FROM raw.transactions
) AS raw

CROSS JOIN (
    SELECT
        SUM(basket_product_lines_count)
            AS fact_transaction_lines
    FROM analytics.fact_basket
) AS fact;


-----------------------------------------------------------------------------------
-- 6. RECONCILE AGGREGATED MEASURES (QUANTITIES, SALES, DISCOUNTS)
/*
Check that aggregation from product lines to baskets preserves total recorded quantity, 
sales, and discount amounts.
Confirmed: all differences = 0.
*/

SELECT
    -- Quantity
    raw.raw_quantity,
    fact.fact_quantity,

    fact.fact_quantity
        - raw.raw_quantity
        AS quantity_difference,

    -- Sales
    raw.raw_sales,
    fact.fact_sales,

    fact.fact_sales
        - raw.raw_sales
        AS sales_difference,

    -- Retail loyalty-card discount
    raw.raw_retail_discount,
    fact.fact_retail_discount,

    fact.fact_retail_discount
        - raw.raw_retail_discount
        AS retail_discount_difference,

    -- Manufacturer coupon
    raw.raw_manufacturer_coupon,
    fact.fact_manufacturer_coupon,

    fact.fact_manufacturer_coupon
        - raw.raw_manufacturer_coupon
        AS manufacturer_coupon_difference,

    -- Retail coupon match
    raw.raw_retail_coupon_match,
    fact.fact_retail_coupon_match,

    fact.fact_retail_coupon_match
        - raw.raw_retail_coupon_match
        AS retail_coupon_match_difference

FROM (
    SELECT
        SUM(quantity)
            AS raw_quantity,

        SUM(sales_value)
            AS raw_sales,

        -SUM(retail_disc)
            AS raw_retail_discount,

        -SUM(coupon_disc)
            AS raw_manufacturer_coupon,

        -SUM(coupon_match_disc)
            AS raw_retail_coupon_match

    FROM raw.transactions
) AS raw

CROSS JOIN (
    SELECT
        SUM(basket_total_quantity)
            AS fact_quantity,

        SUM(basket_sales_value)
            AS fact_sales,

        SUM(retail_discount_amount)
            AS fact_retail_discount,

        SUM(manufacturer_coupon_amount)
            AS fact_manufacturer_coupon,

        SUM(retail_coupon_match_amount)
            AS fact_retail_coupon_match

    FROM analytics.fact_basket
) AS fact;



/*
Check whether any basket-level discount amount becomes
negative after aggregation.

Positive raw retail_disc exceptions were intentionally
retained, so a negative basket-level retail_discount_amount
would not automatically be deleted; it should be inspected.

Expected for manufacturer coupon and coupon match:
0 negative basket-level amounts.
Confirmed: No negative amounts for all three discounts. 
*/

SELECT
    COUNT(*) FILTER (
        WHERE retail_discount_amount < 0
    ) AS negative_retail_discount_amounts,

    COUNT(*) FILTER (
        WHERE manufacturer_coupon_amount < 0
    ) AS negative_manufacturer_coupon_amounts,

    COUNT(*) FILTER (
        WHERE retail_coupon_match_amount < 0
    ) AS negative_retail_coupon_match_amounts

FROM analytics.fact_basket;



-----------------------------------------------------------------------------------
-- 7. VALIDATE VALID VS. NON-VALID PURCHASE BASKETS 

/*
A valid purchase basket contains at least one raw
product-level row with quantity > 0.

From the raw-data audit:
	- 595 baskets contain no positive-quantity product rows.
Confirmed: is_valid_purchase_basket: 
	- TRUE: 275889
	- FALSE: 595
*/
SELECT
    is_valid_purchase_basket,
    COUNT(*) AS baskets,
    SUM(basket_sales_value) AS recorded_sales,
    SUM(basket_total_quantity) AS recorded_quantity

FROM analytics.fact_basket
GROUP BY is_valid_purchase_basket
ORDER BY is_valid_purchase_basket DESC;

-- Inspect examples of baskets excluded from the
-- BG/NBD purchase-event definition.
SELECT
    household_key,
    basket_id,
    basket_day,
    basket_week,
    basket_trans_time,
    basket_product_lines_count,
    basket_unique_product_count,
    basket_total_quantity,
    basket_sales_value,
    manufacturer_coupon_amount,
    retail_discount_amount

FROM analytics.fact_basket

WHERE NOT is_valid_purchase_basket

ORDER BY
    basket_sales_value DESC,
    basket_id

LIMIT 100;

/*
Decision:
For the core project, only:
    is_valid_purchase_basket = TRUE
will be used for:
- purchase/basket counts,
- in-sample customer features,
- BG/NBD frequency and timing,
- holdout purchase outcomes.
The 595 non-valid baskets remain in analytics.fact_basket.
They are not deleted.
This preserves the basket-level source history while keeping
the model's purchase-event definition explicit.
*/

-----------------------------------------------------------------------------------
-- 8. EXPLORE IN-SAMPLE & HOLDOUT ACTIVITY

-- Summarize in-sample and holdout activity
/*
To confirm that both analytical periods contain sufficient
valid purchase activity before customer-level modeling.
Only valid purchase baskets are included.
*/

WITH params AS (
    SELECT
        in_sample_end_day,
        holdout_start_day,
        holdout_end_day
    FROM analytics.project_parameters
    WHERE parameter_id = 1
),

period_activity AS (
    SELECT
        b.*,
        CASE
            WHEN b.basket_day <= p.in_sample_end_day
                THEN 'In-sample'
            WHEN b.basket_day BETWEEN
                 p.holdout_start_day
                 AND p.holdout_end_day
                THEN 'Holdout'
            ELSE 'Outside analysis'
        END AS period

    FROM analytics.fact_basket AS b
    CROSS JOIN params AS p
    WHERE b.is_valid_purchase_basket
)

SELECT
    period,
    COUNT(*) AS purchase_baskets,
    COUNT(DISTINCT household_key)
        AS active_households,
    SUM(basket_sales_value)
        AS recorded_sales
FROM period_activity
GROUP BY period
ORDER BY MIN(basket_day);


-----------------------------------------------------------------------------------
-- 9. VALIDATE CUSTOMER OVERLAP BETWEEN IN-SAMPLE & HOLDOUT PERIOD 
/****** 9. Validate customer overlap between periods ******/

/*
Purpose:
Determine which households are observed during the
in-sample and holdout periods.

Only valid purchase baskets count as customer activity.

Confirmed expected results:

Total households observed      = 2,500
In-sample households           = 2,498
Holdout households             = 2,425
Observed in both periods       = 2,423
In-sample only                 = 75
Holdout only                   = 2

About 97.0% of in-sample households make at least one
valid purchase during holdout.

The 75 in-sample-only households are NOT labelled churned;
they simply have zero observed holdout purchases.

The 2 holdout-only households will not be included in
BG/NBD holdout evaluation because no in-sample purchasing
history is available for them.

                          HOLDOUT (weeks 79–102)
                          Purchase   No purchase
                         ------------------------
IN-SAMPLE   Purchase       2,423   |    75      
weeks 1–78           	 ------------------------
            No purchase      2     |
                     	 ------------------------	
*/

WITH params AS (
    SELECT
        in_sample_end_day,
        holdout_start_day,
        holdout_end_day
    FROM analytics.project_parameters
    WHERE parameter_id = 1
),

in_sample_households AS (
    SELECT DISTINCT
        b.household_key

    FROM analytics.fact_basket AS b

    CROSS JOIN params AS p

    WHERE b.basket_day <= p.in_sample_end_day
      AND b.is_valid_purchase_basket
),

holdout_households AS (
    SELECT DISTINCT
        b.household_key

    FROM analytics.fact_basket AS b

    CROSS JOIN params AS p

    WHERE b.basket_day
              BETWEEN p.holdout_start_day
                  AND p.holdout_end_day

      AND b.is_valid_purchase_basket
),

customer_membership AS (
    SELECT
        COALESCE(
            i.household_key,
            h.household_key
        ) AS household_key,

        (i.household_key IS NOT NULL)
            AS is_in_sample,

        (h.household_key IS NOT NULL)
            AS is_in_holdout

    FROM in_sample_households AS i

    FULL OUTER JOIN holdout_households AS h
        ON i.household_key = h.household_key
)

SELECT
    COUNT(*) AS total_households_observed,
	
    COUNT(*) FILTER (
        WHERE is_in_sample
    ) AS in_sample_households,

    COUNT(*) FILTER (
        WHERE is_in_holdout
    ) AS holdout_households,

    COUNT(*) FILTER (
        WHERE is_in_sample
          AND is_in_holdout
    ) AS households_in_both_periods,

    COUNT(*) FILTER (
        WHERE is_in_sample
          AND NOT is_in_holdout
    ) AS in_sample_only_households,

    COUNT(*) FILTER (
        WHERE NOT is_in_sample
          AND is_in_holdout
    ) AS holdout_only_households,

    ROUND(
        100.0
        * COUNT(*) FILTER (
            WHERE is_in_sample
              AND is_in_holdout
        )
        / NULLIF(
            COUNT(*) FILTER (
                WHERE is_in_sample
            ),
            0
        ),
        1
    ) AS pct_in_sample_active_in_holdout

FROM customer_membership;



/* =========================================================
02_build_basket_fact.sql — final decisions

PROJECT TIME SPLIT

In-sample:
- Through week 78
- Through Day 544

Holdout:
- Weeks 79–102
- Days 545–711
- 24 labelled weeks
- 167 exact observed days

BASKET FACT GRAIN

analytics.fact_basket:
1 row = 1 household × 1 basket
      = 1 shopping / purchase occasion candidate.

VALID PURCHASE DEFINITION

A valid purchase basket contains at least one raw
product-level row with quantity > 0.

595 baskets fail this rule.
They remain in analytics.fact_basket but are not used as
purchase occasions in BG/NBD or holdout purchase counts.

MONETARY TREATMENT

Raw discount fields are retained unchanged in
raw.transactions.

Basket-level analytical discount amounts convert normally
negative raw discounts into positive amounts.

estimated_pre_retail_discount_value restores retailer-funded
discounts and should not be interpreted as customer
out-of-pocket spending.

CUSTOMER COHORT

2,498 households have at least one valid purchase during
the in-sample period.

Of these:
- 2,423 also purchase during holdout.
- 75 have zero observed holdout purchases.

2 households first appear during holdout and therefore do
not belong to the BG/NBD evaluation cohort.

NEXT STEP

03_build_customer_features.sql will:
- examine same-day / same-minute purchase timing,
- finalize the BG/NBD purchase-time representation,
- construct frequency x,
- construct recency t_x,
- construct observation time T,
- build historical customer-profile features.
========================================================= */

 
/*
Sales value and discount interpretation
---------------------------------------

Discount fields are stored as negative values:

- retail_disc:
  Retailer-funded loyalty-card discount.

- coupon_match_disc:
  Retailer-funded discount that matches a manufacturer coupon.

- coupon_disc:
  Manufacturer-funded coupon.
  This reduces what the customer pays, but the retailer is reimbursed
  by the manufacturer.

Key interpretation
------------------

1. No discount

   Example:
   quantity           = 1
   sales_value        = 1.67
   retail_disc        = 0
   coupon_disc        = 0
   coupon_match_disc  = 0

   No discount was applied.
   Customer payment = sales_value = 1.67.


2. Retailer loyalty-card discount

   Example:
   quantity           = 2
   sales_value        = 2.00
   retail_disc        = -1.34
   coupon_disc        = 0
   coupon_match_disc  = 0

   Retailer-funded discount amount = 1.34.

   Estimated value before retailer-funded discount:
       sales_value - retail_disc
       = 2.00 - (-1.34)
       = 3.34

   Per unit:
       estimated pre-discount value = 3.34 / 2 = 1.67
       discounted sales value       = 2.00 / 2 = 1.00

   With no manufacturer coupon:
       estimated customer payment = sales_value = 2.00


3. Manufacturer coupon + retailer coupon match

   Example:
   quantity           = 2
   sales_value        = 2.89
   retail_disc        = 0
   coupon_disc        = -0.55
   coupon_match_disc  = -0.45

   Retailer-funded coupon-match amount = 0.45.

   Estimated value before retailer-funded discount:
       sales_value - coupon_match_disc
       = 2.89 - (-0.45)
       = 3.34

   Estimated customer payment:
       sales_value + coupon_disc
       = 2.89 + (-0.55)
       = 2.34

   The manufacturer-funded coupon reduces customer payment by 0.55.
   The manufacturer reimburses the retailer for that amount.


How the fields are used
-----------------------

- sales_value:
  Use as the transaction sales measure for customer-value analysis.

- sales_value + coupon_disc:
  Use to estimate customer out-of-pocket spending.

- retail_disc, coupon_disc, coupon_match_disc:
  Analyze separately when studying loyalty and coupon behavior.

- Discount amounts:
  Convert negative raw discounts to positive amounts for reporting.

  Example:
      retail_disc        = -2.00  -> retail discount amount = 2.00
      coupon_match_disc  = -1.00  -> coupon match amount    = 1.00


Estimated pre-retailer-discount value
-------------------------------------

This restores retailer-funded discounts:

    sales_value
    - retail_disc
    - coupon_match_disc

Example:

    sales_value        =  8.00
    retail_disc        = -2.00
    coupon_match_disc  = -1.00

    estimated_pre_retail_discount_value
        = 8.00 - (-2.00) - (-1.00)
        = 11.00

Important:
This is an estimated value before retailer-funded discounts only.

It should NOT be interpreted as:
- the exact product list/shelf price, or
- customer out-of-pocket spending.
*/






