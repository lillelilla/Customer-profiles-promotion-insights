/*=================================================================================
FILE: 04_build_holdout_and_model_inputs.sql

PURPOSE:
1. Create observed holdout outcomes for the households
   included in analytics.customer_features.
2. Validate that holdout outcomes reconcile with the
   underlying valid basket data.
3. Create the final SQL-to-Python dataset used for
   BG/NBD holdout evaluation and later customer profiling.

INPUTS:
- analytics.project_parameters 
- analytics.fact_basket 
	(Grain: 1 row per household × basket. 
	 One row represents one shopping basket/purchase occasion)
- analytics.customer_features 
	(Grain: 1 row per in-sample household) 

OUTPUTS:
- analytics.customer_holdout 
	(Grain: 1 row per in-sample household)
- analytics.bgnbd_model_input 
	(Grain: 1 row per in-sample household, only houshold that have positive purchase quantity)

DEPENDENCIES:
01_data_audit.sql
02_build_basket_fact.sql
03_build_customer_features.sql

IMPORTANT:
One valid basket = one purchase occasion.

Primary BG/NBD holdout outcome:
actual_holdout_baskets

The holdout table starts from analytics.customer_features.
Therefore, only households with an observed in-sample
purchase history are included.

Households with no valid holdout purchase remain in the
table with holdout outcomes equal to 0.

Holdout-only households are intentionally excluded from
BG/NBD evaluation because the model has no in-sample
purchase history for them.
=================================================================================*/

-----------------------------------------------------------------------------------
-- 1.CONFIRM HOLDOUT PERIOD & PREDICTION HORIZON IN PROJECT PARAMETERS

/*
Verified project parameters:

in_sample_end_day = 544
holdout_start_day = 545
holdout_end_day   = 711

There is no unobserved day between the in-sample and
holdout periods.

Days 545 through 711 inclusive contain:

711 - 545 + 1 = 167 observed days.

Under the continuous-time convention established in
03_build_customer_features.sql:

Day 1 at 00:00 = model time 0.

Therefore the beginning of Day 545 is model time 544,
and the BG/NBD prediction horizon is:

711 - 544 = 167 days.

The holdout is still described for reporting purposes as
24 labelled weeks: Weeks 79–102.
*/

SELECT
    in_sample_end_week,
    holdout_start_week,
    holdout_end_week,

    in_sample_end_day,
    holdout_start_day,
    holdout_end_day,

    holdout_weeks,

    -- Expected: 0.
    holdout_start_day
        - in_sample_end_day
        - 1 AS unobserved_gap_days,

    -- Expected: 167.
    holdout_end_day
        - holdout_start_day
        + 1 AS observed_holdout_days,

    -- Expected: 167.
    holdout_end_day
        - in_sample_end_day
        AS prediction_horizon_days

FROM analytics.project_parameters
WHERE parameter_id = 1;



-----------------------------------------------------------------------------------
-- 2. BUILD CUSTOMER HOLDOUT TABLE
/*
Purpose:
Build analytics.customer_holdout
Create one row per in-sample household containing the
customer's observed behaviour during the holdout period.

Primary BG/NBD evaluation outcome:
	actual_holdout_baskets
	Because one valid basket is defined as one purchase
	occasion, the model prediction and actual outcome use the
	same event definition.

Additional descriptive holdout measures are retained:
	actual_holdout_purchase_days
	= number of distinct calendar days with a valid purchase.
	
	actual_holdout_active_weeks
	= number of distinct weeks containing a valid purchase.
	
	actual_holdout_sales
	= recorded retailer sales value from valid holdout baskets.
	
	was_active_in_holdout
	= TRUE if the household had at least one valid holdout
	  purchase basket.

Important:
The final SELECT starts from analytics.customer_features.

Therefore:
- all 2,498 in-sample households remain represented;
- the 75 households with zero holdout purchases remain;
- the 2 holdout-only households are not introduced.
*/

DROP TABLE IF EXISTS analytics.customer_holdout;

CREATE TABLE analytics.customer_holdout AS

WITH
-- CTE 1: params
	-- Purpose: Retrieve the exact holdout day boundaries.
params AS (
    SELECT
        holdout_start_day,
        holdout_end_day
    FROM analytics.project_parameters
    WHERE parameter_id = 1
),

-- CTE 2: holdout_activity
	/*
	Purpose:
	Aggregate valid holdout purchase baskets to one record per
	household that actually purchased during holdout.
	
	Households with no holdout purchase do not appear in this
	CTE. They will be restored by the later LEFT JOIN.
	 */
holdout_activity AS (
    SELECT
        b.household_key,

        -- Primary BG/NBD evaluation outcome:
        -- number of valid basket purchase occasions.
        CAST(
            COUNT(*)
            AS INTEGER
        ) AS actual_holdout_baskets,

        -- Descriptive:
        -- number of distinct days containing >= 1
        -- valid purchase.
        CAST(
            COUNT(DISTINCT b.basket_day)
            AS INTEGER
        ) AS actual_holdout_purchase_days,

        -- Descriptive:
        -- number of distinct weeks containing >= 1
        -- valid purchase.
        CAST(
            COUNT(DISTINCT b.basket_week)
            AS INTEGER
        ) AS actual_holdout_active_weeks,

        -- Total recorded retailer sales value from valid
        -- holdout purchase baskets.
        CAST(
            SUM(b.basket_sales_value)
            AS NUMERIC(16,2)
        ) AS actual_holdout_sales

    FROM analytics.fact_basket AS b

    CROSS JOIN params AS p

    WHERE b.basket_day
              BETWEEN p.holdout_start_day
                  AND p.holdout_end_day

      AND b.is_valid_purchase_basket

    GROUP BY
        b.household_key
)

	 
-- Final output
	/*
	Start from analytics.customer_features so every in-sample
	household is retained.
	LEFT JOIN is required because households with no holdout
	purchase have no row in holdout_activity.
	COALESCE converts their missing holdout outcomes to zero.
	*/
SELECT
    c.household_key,

    CAST(
        COALESCE(
            h.actual_holdout_baskets,
            0
        )
        AS INTEGER
    ) AS actual_holdout_baskets,

    CAST(
        COALESCE(
            h.actual_holdout_purchase_days,
            0
        )
        AS INTEGER
    ) AS actual_holdout_purchase_days,

    CAST(
        COALESCE(
            h.actual_holdout_active_weeks,
            0
        )
        AS INTEGER
    ) AS actual_holdout_active_weeks,

    CAST(
        COALESCE(
            h.actual_holdout_sales,
            0
        )
        AS NUMERIC(16,2)
    ) AS actual_holdout_sales,

    (
        COALESCE(
            h.actual_holdout_baskets,
            0
        ) > 0
    ) AS was_active_in_holdout

FROM analytics.customer_features AS c

LEFT JOIN holdout_activity AS h
    ON c.household_key = h.household_key;


-----------------------------------------------------------------------------------
-- 3. ADD PRIMARY KEY & FOREIGN KEY
/*
Primary key:
one holdout record per household.

Foreign key:
every household in customer_holdout must belong to the
in-sample customer population in customer_features.
*/

ALTER TABLE analytics.customer_holdout
ADD CONSTRAINT pk_customer_holdout
PRIMARY KEY (household_key);


ALTER TABLE analytics.customer_holdout
ADD CONSTRAINT fk_holdout_customer
FOREIGN KEY (household_key)
REFERENCES analytics.customer_features (household_key);

-----------------------------------------------------------------------------------
-- 4. VALIDATE HOLDOUT TABLE STRUCTURE
/*
Expected:
	rows              = 2,498
	unique_households = 2,498
	All invalid counts below should equal 0.
Logical hierarchy:
	actual_holdout_active_weeks
    <= actual_holdout_purchase_days
    <= actual_holdout_baskets
because:
- one active week can contain multiple purchase days;
- one purchase day can contain multiple baskets.
*/

SELECT
    COUNT(*) AS rows,

    COUNT(DISTINCT household_key)
        AS unique_households,

    COUNT(*) FILTER (
        WHERE household_key IS NULL
    ) AS null_household_keys,

    COUNT(*) FILTER (
        WHERE actual_holdout_baskets < 0
    ) AS negative_basket_counts,

    COUNT(*) FILTER (
        WHERE actual_holdout_purchase_days < 0
    ) AS negative_purchase_day_counts,

    COUNT(*) FILTER (
        WHERE actual_holdout_active_weeks < 0
    ) AS negative_active_week_counts,

    COUNT(*) FILTER (
        WHERE actual_holdout_sales < 0
    ) AS negative_sales_values,

    -- A household cannot have more purchase days than baskets.
    COUNT(*) FILTER (
        WHERE actual_holdout_purchase_days
              > actual_holdout_baskets
    ) AS purchase_days_greater_than_baskets,

    -- A household cannot have more active weeks than
    -- purchase days.
    COUNT(*) FILTER (
        WHERE actual_holdout_active_weeks
              > actual_holdout_purchase_days
    ) AS active_weeks_greater_than_purchase_days,

    -- Activity flag must agree with basket count.
    COUNT(*) FILTER (
        WHERE was_active_in_holdout
              <> (actual_holdout_baskets > 0)
    ) AS inconsistent_active_flags,

    -- If there are zero purchase baskets, all count
    -- outcomes and recorded sales should also be zero.
    COUNT(*) FILTER (
        WHERE actual_holdout_baskets = 0
          AND (
                 actual_holdout_purchase_days <> 0
              OR actual_holdout_active_weeks <> 0
              OR actual_holdout_sales <> 0
          )
    ) AS inconsistent_zero_purchase_rows

FROM analytics.customer_holdout;

-----------------------------------------------------------------------------------
-- 4. VALIDATE EXPECTED HOLDOUT COHORT 
/*
The table contains the 2,498 households observed during the
in-sample period.

Confirmed expected results:
	holdout_rows             = 2,498
	purchasing_households    = 2,423
		Households with >= 1 valid purchase during holdout.
	zero_purchase_households = 75
		Households with no observed valid purchase during holdout.
		The 75 households should NOT be labelled churned.
		They simply have zero observed purchases during the defined
		167-day holdout period.
*/

SELECT
    COUNT(*) AS holdout_rows,

    COUNT(*) FILTER (
        WHERE actual_holdout_baskets > 0
    ) AS purchasing_households,

    COUNT(*) FILTER (
        WHERE actual_holdout_baskets = 0
    ) AS zero_purchase_households

FROM analytics.customer_holdout;

-----------------------------------------------------------------------------------
-- 6. RECONCILE HOLDOUT OUTCOMES TO FACT BASKET 
/*
Purpose:
Independently calculate holdout basket count and sales from
analytics.fact_basket for the same 2,498-household in-sample
cohort, then compare them with analytics.customer_holdout.

This confirms that the household-level aggregation neither
loses nor duplicates valid holdout purchase activity.

Important:
The fact_basket comparison is restricted to households in
analytics.customer_features.

This intentionally excludes the 2 holdout-only households.

Confirmed: 
basket_difference = 0
sales_difference  = 0.00
*/

WITH params AS (
    SELECT
        holdout_start_day,
        holdout_end_day
    FROM analytics.project_parameters
    WHERE parameter_id = 1
),

holdout_table_totals AS (
    SELECT
        SUM(actual_holdout_baskets)
            AS customer_holdout_baskets,

        SUM(actual_holdout_sales)
            AS customer_holdout_sales

    FROM analytics.customer_holdout
),

fact_basket_totals AS (
    SELECT
        COUNT(*)
            AS fact_basket_holdout_baskets,

        SUM(b.basket_sales_value)
            AS fact_basket_holdout_sales

    FROM analytics.fact_basket AS b

    CROSS JOIN params AS p

    WHERE b.basket_day
              BETWEEN p.holdout_start_day
                  AND p.holdout_end_day

      AND b.is_valid_purchase_basket

      AND b.household_key IN (
          SELECT
              household_key
          FROM analytics.customer_features
      )
)

SELECT
    -- Basket reconciliation
    h.customer_holdout_baskets,
    f.fact_basket_holdout_baskets,

    h.customer_holdout_baskets
        - f.fact_basket_holdout_baskets
        AS basket_difference,

    -- Sales reconciliation
    h.customer_holdout_sales,
    f.fact_basket_holdout_sales,

    h.customer_holdout_sales
        - f.fact_basket_holdout_sales
        AS sales_difference

FROM holdout_table_totals AS h

CROSS JOIN fact_basket_totals AS f;

-----------------------------------------------------------------------------------
-- 7. CONFIRM THE 2 HOLDOUT_ONLY HOUSEHOLDS
/*
Purpose:
Identify households that made at least one valid purchase
during holdout but do not exist in customer_features.

These households first enter the observed purchase data
after the in-sample cutoff.

Confirmed:
holdout_only_households = 2

They are intentionally excluded from BG/NBD holdout
evaluation because there is no in-sample purchase history
from which to construct x, t_x, and T.
*/

WITH params AS (
    SELECT
        holdout_start_day,
        holdout_end_day
    FROM analytics.project_parameters
    WHERE parameter_id = 1
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
)

SELECT
    COUNT(*) AS holdout_only_households

FROM holdout_households AS h

LEFT JOIN analytics.customer_features AS c
    ON h.household_key = c.household_key

WHERE c.household_key IS NULL;


-----------------------------------------------------------------------------------
-- 8. CREATE MODEL INPUT TABLE 
-- 
/*
Purpose:
Create analytics.bgnbd_model_input as the final SQL -> Python model dataset,
containing:
1. Required BG/NBD inputs
   - frequency
   - recency_days
   - observation_days

2. Exact prediction horizon
   - prediction_horizon_days

3. Actual future outcome
   - actual_holdout_baskets

4. Additional holdout outcomes

5. Historical customer activity/value variables

6. Historical retail discount and coupon behaviour

Only BG/NBD-eligible in-sample households are included.

Because all 2,498 customer_features records have already
been validated as eligible, the expected view population
is also 2,498 households.
*/

CREATE OR REPLACE VIEW analytics.bgnbd_model_input AS

WITH params AS (
    SELECT
        holdout_end_day
            - in_sample_end_day
            AS prediction_horizon_days

    FROM analytics.project_parameters

    WHERE parameter_id = 1
)

SELECT
    c.household_key,

    /* -----------------------------
    Required BG/NBD inputs
    ------------------------------ */

    -- x
    c.frequency,

    -- t_x
    c.recency_days,

    -- T
    c.observation_days,

    -- Exact future period over which predicted purchase
    -- counts will be compared with observed baskets.
    p.prediction_horizon_days,

    /* -----------------------------
    Primary holdout outcome
    ------------------------------ */

    -- Actual number of valid purchase occasions observed
    -- during the 167-day holdout period.
    h.actual_holdout_baskets,

    /* -----------------------------
    Additional holdout information
    ------------------------------ */

    h.actual_holdout_purchase_days,
    h.actual_holdout_active_weeks,
    h.actual_holdout_sales,
    h.was_active_in_holdout,

    /* -----------------------------
    Historical activity/value
    ------------------------------ */

    c.in_sample_baskets,
    c.active_weeks,
    c.days_since_last_purchase,
    c.historical_sales,
    c.average_basket_value,
    c.historical_quantity,

    /* -----------------------------
    Retail loyalty-card discounts
    ------------------------------ */

    c.retail_discount_basket_rate,
    c.retail_discount_per_basket,
    c.total_retail_discount,

    /* -----------------------------
    Manufacturer coupons
    ------------------------------ */

    c.manufacturer_coupon_basket_rate,
    c.total_manufacturer_coupon,
    c.manufacturer_coupon_amount_per_redeeming_basket,

    /* -----------------------------
    Retail coupon matches
    ------------------------------ */

    c.retail_coupon_match_basket_rate,
    c.retail_coupon_match_per_basket,
    c.total_retail_coupon_match,

    /* -----------------------------
    Estimated pre-retailer-discount value
    ------------------------------ */

    c.estimated_pre_retail_discount_value

FROM analytics.customer_features AS c

INNER JOIN analytics.customer_holdout AS h
    ON c.household_key = h.household_key

CROSS JOIN params AS p

WHERE c.is_bgnbd_eligible;


-----------------------------------------------------------------------------------
-- 9. VALIDATE THE FINAL SQL -> PYTHON DATASET
/*
Purpose: Validate analytics.bgnbd_model_input
Confirmed:
	model_rows        = 2,498
	unique_households = 2,498
	all NULL/invalid counts = 0
*/

SELECT
    COUNT(*) AS model_rows,

    COUNT(DISTINCT household_key)
        AS unique_households,

    COUNT(*) FILTER (
        WHERE frequency IS NULL
    ) AS null_frequency,

    COUNT(*) FILTER (
        WHERE recency_days IS NULL
    ) AS null_recency,

    COUNT(*) FILTER (
        WHERE observation_days IS NULL
    ) AS null_observation_time,

    COUNT(*) FILTER (
        WHERE prediction_horizon_days IS NULL
    ) AS null_prediction_horizon,

    COUNT(*) FILTER (
        WHERE actual_holdout_baskets IS NULL
    ) AS null_holdout_baskets,

    COUNT(*) FILTER (
        WHERE actual_holdout_baskets < 0
    ) AS negative_holdout_baskets

FROM analytics.bgnbd_model_input;


/* Confirm that every model record uses the same exact
holdout prediction horizon.
Confirmed:
	distinct_horizons = 1
	min_horizon_days  = 167
	max_horizon_days  = 167
*/
SELECT
    COUNT(DISTINCT prediction_horizon_days)
        AS distinct_horizons,

    MIN(prediction_horizon_days)
        AS min_horizon_days,

    MAX(prediction_horizon_days)
        AS max_horizon_days

FROM analytics.bgnbd_model_input;



-- Inspect several final model-input records.
SELECT
    household_key,

    frequency,
    recency_days,
    observation_days,
    prediction_horizon_days,

    actual_holdout_baskets,

    in_sample_baskets,
    historical_sales,

    retail_discount_basket_rate,
    manufacturer_coupon_basket_rate,
    retail_coupon_match_basket_rate

FROM analytics.bgnbd_model_input
ORDER BY household_key
LIMIT 20;
	
/* =========================================================
04_build_holdout_and_model_inputs.sql — final decisions

HOLDOUT PERIOD

Holdout:
Days 545–711 inclusive
Weeks 79–102

Reporting description:
24 labelled holdout weeks.

Exact BG/NBD prediction horizon:
167 days.

MODELING COHORT

analytics.customer_holdout starts from
analytics.customer_features.

Therefore:
- 2,498 in-sample households are retained.
- 2,423 have >= 1 valid holdout purchase basket.
- 75 have zero observed holdout purchases.
- 2 holdout-only households are intentionally excluded.

The 75 zero-purchase households are not labelled churned.
They simply have zero observed purchases during the
defined holdout period.

PRIMARY HOLDOUT OUTCOME

actual_holdout_baskets
= number of valid purchase baskets during holdout.

This matches the in-sample BG/NBD event definition:

one valid basket = one purchase occasion.

ADDITIONAL HOLDOUT MEASURES

actual_holdout_purchase_days
= distinct days containing a valid purchase.

actual_holdout_active_weeks
= distinct weeks containing a valid purchase.

actual_holdout_sales
= recorded retailer sales value across valid holdout
  baskets.

These variables are descriptive.
The primary BG/NBD count-evaluation outcome remains
actual_holdout_baskets.

FINAL SQL-TO-PYTHON VIEW

analytics.bgnbd_model_input contains:
- frequency x
- recency t_x
- observation time T
- exact 167-day prediction horizon
- actual holdout basket count
- historical customer profile variables
- historical discount/coupon behaviour

Expected population:
2,498 BG/NBD-eligible households.

NEXT STEP

Python will:

1. load analytics.bgnbd_model_input;

2. validate x, t_x, T and the 167-day horizon once more;

3. construct a simple historical purchase-rate benchmark;

4. fit the BG/NBD model using the in-sample
   frequency, recency, and observation time;

5. predict expected basket purchases over 167 days;

6. compare predicted baskets with
   actual_holdout_baskets;

7. evaluate whether BG/NBD improves on the simple
   benchmark;

8. use predicted future activity together with historical
   customer value and discount/coupon behaviour for the
   later customer-profile analysis.
========================================================= */


