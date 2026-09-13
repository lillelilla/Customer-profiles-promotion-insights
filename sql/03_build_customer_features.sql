/*=================================================================================
FILE: 03_build_customer_features.sql
PURPOSE:
	Create one in-sample modelling and profiling record per
	household.
	In-sample period: Through Day 544 / Week 78.
	The table contains:
	1. BG/NBD purchase-history inputs:
	   - frequency x
	   - recency t_x
	   - observation time T
	
	2. Historical customer-profile features:
	   - basket activity
	   - retailer sales value
	   - quantity
	   - retail loyalty-card discount behaviour
	   - manufacturer coupon behaviour
	   - retail coupon-match behaviour
SOURCE: 
	analytics.project_parameters
	analytics.fact_basket 
		(Grain: 1 row per household × basket.
		 One row represents one shopping basket/purchase occasion.)

OUTPUT:
	analytics.customer_features 
		(Grain: 1 row per in-sample household (groupby household_key))

DEPENDENCIES:
	01_data_audit.sql
	02_build_basket_fact.sql

IMPORTANT:
Only is_valid_purchase_basket = TRUE is treated as a
purchase occasion.

BG/NBD purchase-event definition:
One valid basket = one purchase occasion.

Day is used as the BG/NBD time unit.

For household i:
	frequencey x
	= number of repeat purchase occasions observed after the
	  initial purchase at t = 0.
	
	recency t_x
	= time of the last observed purchase on the customer's
	  purchase-time clock. Operationally:
	  t_x = elapsed time from the first observed basket to the
	  last observed basket.
	
	observation period T
	= elapsed time from the first observed basket to the end
	  of the in-sample observation period.

For one-time purchasers/households:
	x = 0
	t_x = 0
	T > 0

For repeat purchasers/households:
	x > 0
	0 < t_x <= T

Recall: 
Total households observed      = 2,500
In-sample households           = 2,498
Holdout households             = 2,425
Observed in both periods       = 2,423
In-sample only                 = 75
Holdout only                   = 2
=================================================================================*/


-- SELECT
--     column_name,
--     data_type
-- FROM information_schema.columns
-- WHERE table_schema = 'analytics'
--   AND table_name = 'customer_features'
-- ORDER BY ordinal_position;

-----------------------------------------------------------------------------------
----- VALIDATE HOW PURCHASE OCCASIONS SHOULD BE DEFINED ----
-----------------------------------------------------------------------------------
/* Purpose: validate whether the available time fields can distinguish and order
purchase occasions within a household.
For this project:
    one valid basket = one purchase occasion

The checks below test whether:
1. household_key + basket_day is sufficient, and
2. adding basket_trans_time uniquely distinguishes same-day baskets.

The goal is to confirm whether basket_id should remain the identifier
for distinct purchase occasions.
*/

-- 1. CHECK MULTIPLE BASKETS ON THE SAME DAY
--  Candidate identifier: household_key + basket_day
/*
Check whether a household can have more than one valid basket on the
same day during the in-sample period.

If multiple baskets occur on the same household-day, basket_day alone
cannot distinguish all purchase occasions.

Confirmed:
- Household-days with multiple baskets = 29,318
- Households affected = 2,146
- Maximum baskets on one household-day = 19
- About 86% (2,146 / 2,498) of in-sample households have at least one
  day with multiple baskets.

Interpretation:
Same-day multiple baskets are common.

Therefore, household_key + basket_day is not sufficient to uniquely
identify purchase occasions when each valid basket is retained as a
separate purchase occasion.
*/

WITH 
-- CTE 1: retrieve the last day of the in-sample period
params AS (
    SELECT
        in_sample_end_day
    FROM analytics.project_parameters
    WHERE parameter_id = 1
),
-- CTE 2: group fact_basket by household+day and count 
-- how many valid baskets each household had on that day
customer_day_activity AS (
    SELECT
        b.household_key,
        b.basket_day,
        COUNT(*) AS baskets_on_day
    FROM analytics.fact_basket AS b
    CROSS JOIN params AS p
    WHERE b.basket_day <= p.in_sample_end_day
    	AND b.is_valid_purchase_basket
    GROUP BY
        b.household_key,
        b.basket_day
)

SELECT
    COUNT(*) AS household_days_with_multiple_baskets,  -- 29,318 unique (household, day) combinations where that household had more than one basket.
    COUNT(DISTINCT household_key)
        AS households_with_same_day_multiple_baskets,  -- 2,146 households had at least one day during the in-sample period when they made multiple valid basket purchases.
    MAX(baskets_on_day)
        AS max_baskets_same_day                        -- the most extreme household-day contained 19 separate valid baskets for the same household on the same day.
FROM customer_day_activity -- CTE 2
WHERE baskets_on_day > 1;  -- keeps only household-days where there were at least two baskets.


-- 2. CHECK MULTIPLE BASKETS ON THE SAME DAY & TIME
--    Candidate identifier: household_key + basket_day + basket_trans_time
/*
Purpose:
Check whether adding basket_trans_time can distinguish the same-day
purchase occasions identified above.
A timestamp group is defined as:
    one household + one day + one recorded transaction minute

If multiple distinct baskets share the same timestamp group, then
minute-level transaction time is also not sufficient to uniquely
identify every purchase occasion.

Confirmed:
- Timestamp groups with multiple baskets = 1,067
- Households affected = 604
- Baskets in tied timestamp groups = 2,139
- Additional baskets beyond one basket per timestamp = 1,072
- Maximum baskets at one timestamp = 3

Example: 
	Household   Day   Time    Basket
	101         20    14:35   A
	101         20    14:35   B
	
	102         21    09:10   C
	102         21    09:10   D
	102         21    09:10   E
	This results in:
	Duplicate timestamp groups = 2
	Households affected        = 2
	Baskets in tied groups     = 5
	Additional baskets         = (2-1) + (3-1) = 3
	Maximum baskets at timestamp = 3

Interpretation:
basket_trans_time provides additional within-day timing, but its
minute-level resolution does not uniquely distinguish every basket.

A shared timestamp does not mean the baskets are duplicates.
Distinct basket_id values are therefore retained as distinct
purchase occasions.
*/

WITH 
-- CTE 1: get the end of the in-sample period
params AS (
    SELECT
        in_sample_end_day
    FROM analytics.project_parameters
    WHERE parameter_id = 1
),

-- CTE 2: Identify household-day-minute combinations containing
-- more than one distinct valid basket.
same_timestamp_baskets AS (
    SELECT
        b.household_key,
        b.basket_day,
        b.basket_trans_time,
        COUNT(*) AS baskets_at_same_timestamp
    FROM analytics.fact_basket AS b
    CROSS JOIN params AS p
    WHERE b.basket_day <= p.in_sample_end_day
      AND b.is_valid_purchase_basket
    GROUP BY                        -- Create one group for every unique combination of
        b.household_key,            -- household + day + transaction minute
        b.basket_day,
        b.basket_trans_time
    HAVING COUNT(*) > 1
)

SELECT
    COUNT(*) AS duplicate_timestamp_groups,          -- 1,067 household-day-minute groups contain multiple baskets.
    COUNT(DISTINCT household_key)
        AS households_affected,                      -- 604 unique households have at least one case where multiple baskets share exactly the same recorded minute.
    SUM(baskets_at_same_timestamp)
        AS baskets_in_duplicate_timestamp_groups,    -- 2,139 baskets contained in those 1,067 tied timestamp groups.
    SUM(baskets_at_same_timestamp - 1)
        AS additional_baskets_due_to_timestamp_ties, -- 1,072 additional baskets = 2,139 total baskets - 1,067 timestamp groups
    MAX(baskets_at_same_timestamp)
        AS max_baskets_at_same_timestamp             -- 3 baskets is the most extreme case that have same household-day-minute
FROM same_timestamp_baskets;


-- Inspect examples of distinct baskets sharing the same
-- household + day + transaction time.
WITH params AS (
    SELECT
        in_sample_end_day
    FROM analytics.project_parameters
    WHERE parameter_id = 1
),

duplicate_timestamps AS (
    SELECT
        b.household_key,
        b.basket_day,
        b.basket_trans_time

    FROM analytics.fact_basket AS b

    CROSS JOIN params AS p

    WHERE b.basket_day <= p.in_sample_end_day
      AND b.is_valid_purchase_basket

    GROUP BY
        b.household_key,
        b.basket_day,
        b.basket_trans_time

    HAVING COUNT(*) > 1
)

SELECT
    b.household_key,
    b.basket_day,
    b.basket_trans_time,
    b.basket_id,
    b.store_id,
    b.basket_sales_value,
    b.basket_total_quantity

FROM analytics.fact_basket AS b

INNER JOIN duplicate_timestamps AS d
    ON b.household_key = d.household_key
   AND b.basket_day = d.basket_day
   AND b.basket_trans_time = d.basket_trans_time

ORDER BY
    b.household_key,
    b.basket_day,
    b.basket_trans_time,
    b.basket_id

LIMIT 100;

/* 
Final BG/NBD purchase-event decision: 

Purchase occasion = one valid basket.
	Distinct basket_id values are retained as distinct purchase
	occasions, including baskets that occur on the same day or
	share the same recorded minute.

Purchase timing = basket_day + basket_trans_time.
	basket_trans_time is recorded at minute-level resolution,
	so some distinct baskets share the same observed timestamp.

We do not:
- collapse these baskets,
- delete them, or
- manufacture artificial seconds to separate them.

The important customer-level BG/NBD condition will be
validated after customer_features is constructed:

For one-time purchasers: x = 0 and t_x = 0.

For repeat purchasers: x > 0 and t_x > 0.

Previously confirmed:
No repeat-purchase household has zero elapsed time between
its first and last observed purchases.

Therefore timestamp ties do not require changing the
basket-level purchase-event definition.
*/

-----------------------------------------------------------------------------------
----- BUILD CUSTOMER FEATURES TABLE ----
-----------------------------------------------------------------------------------
/* Four CTE stages:
	params
	   v
	in_sample_baskets
	   v
	bgnbd_features &
	customer_profile_features
	   v
	final join
*/

DROP TABLE IF EXISTS analytics.customer_features;

CREATE TABLE analytics.customer_features AS
-- Declare CTEs
WITH
	-- CTE 1: 
	-- Purpose: get the end day of the in-sample period.
	params AS (
		SELECT
			in_sample_end_day -- 544
		FROM analytics.project_parameters
		WHERE parameter_id = 1
	),

	-- CTE 2: 
		-- Purpose: 
		-- 1. Keep only valid purchase baskets observed during the in-sample period.
		-- 2. Convert basket_day + basket_trans_time into continuous purchase time measured in days.
				-- Continuous-time convention:
					-- Day 1 at 00:00 = time 0
					-- Day 1 at 12:00 = time 0.5
					-- Day 2 at 00:00 = time 1
					-- ...
					-- Beginning of Day 545 = time 544
					-- Therefore the end of the in-sample period is represented by model time 544.
		-- Source: analytics.fact_basket & params CTE
	in_sample_baskets AS (
		SELECT
			b.*,
			-- Add basket purchase time expressed as continuous days from the
        	-- dataset time origin, where Day 1 at 00:00 = 0
			-- (convert basket_day + trans_time to days)
			CAST(                 							
				(b.basket_day - 1) 										   -- minus 1 so that Day 1 at 00:00 = time 0, Day 2 at 00:00 = time 1, etc.
				+ FLOOR(b.basket_trans_time / 100.0) / 24.0 			   -- HH portion of HHMM converted to fraction of day.So FLOOR(1430/100)=FLOOR(14.30)=14. Then 14/24 hours = 0.583333 days to convert hours to day
				+ MOD(b.basket_trans_time, 100) / 1440.0 AS numeric(14, 6) -- MM portion of HHMM converted to fraction of day. MOD(1430, 100)=30. Then 30/1440.0 mins = 0.0208333 days to convert mins to day
			) AS purchase_time_days
		FROM analytics.fact_basket AS b
		CROSS JOIN params AS p
		WHERE
			b.basket_day <= p.in_sample_end_day
			AND b.is_valid_purchase_basket
	),

	-- CTE 3: 
		  /* Purpose: Create the customer-level purchase-history variables needed by BG/NBD.
		     For each household:
				in_sample_baskets
					= total number of valid purchase occasions observed during
					  the in-sample period.
				frequency (x)
					= number of repeat purchases after the first purchase.
				recency_days (t_x)
					= elapsed time between the first and last purchase.	
				observation_days (T)
					= elapsed time between the first purchase and the end of
				      the in-sample observation period.
				days_since_last_purchase
					= traditional RFM-style recency:
				      elapsed time from the last purchase to the cutoff.
			Source: in_sample_baskets CTE & params CTE */
	bgnbd_features AS (
		SELECT
			b.household_key,
			
			-- How many valid baskets does this household have? 
			CAST(COUNT(*) AS integer) AS in_sample_baskets,
	
			-- The first purchase time 
			CAST(MIN(b.purchase_time_days) AS numeric(14, 6)) AS first_purchase_time_days,
			
			-- The last purchase time
			CAST(MAX(b.purchase_time_days) AS numeric(14, 6)) AS last_purchase_time_days,
			
			-- Frequency x: number of repeat purchases after the first purchase.
			CAST(COUNT(*) - 1 AS integer) AS frequency,
			
			-- Recency t_x: how much time passed between the first and most recent purchase
				-- first purchase ---------------- last purchase
				--             <------ 30 days ----->
			CAST(
				MAX(b.purchase_time_days) 
				- MIN(b.purchase_time_days) 
				AS numeric(14, 6)
			) AS recency_days,
			
			-- observation period T: how long has this customer been observed since their first purchase?
			-- (from first purchase t=0 to end of the in-sample observation period)
			CAST(
				p.in_sample_end_day 
				- MIN(b.purchase_time_days) 
				AS numeric(14, 6)
			) AS observation_days,
			
			-- traditional RFM-style meaning of recency:
			-- how long has it been since the customer's latest purchase
			-- last purchase ---------------- cutoff (end of observation period)
			--              <---- 20 days ---->
			CAST(
				p.in_sample_end_day 
				- MAX(b.purchase_time_days) 
				AS numeric(14, 6)
			) AS days_since_last_purchase
			
		FROM in_sample_baskets AS b
		CROSS JOIN params AS p
		GROUP BY
			b.household_key,
			p.in_sample_end_day
	),

	-- CTE 4
		/* Purpose: Create historical in-sample features for later customer profiling 
		   and comparison with BG/NBD future activity.
		   These variables are NOT inputs required by BG/NBD itself. They describe 
		    historical customer activity, value, and discount/coupon behaviour.
		   Source: in_sample_baskets CTE
		*/
	customer_profile_features AS (
		SELECT
			-- For each household:
			b.household_key,
			
			-- Number of distinct weeks in which the household made at least one valid purchase
			CAST(COUNT(DISTINCT b.basket_week) AS integer) AS active_weeks,
			
			-- Total recorded retailer sales value across valid in-sample baskets
			CAST(SUM(b.basket_sales_value) AS numeric(16, 2)) AS historical_sales,
			
			-- Average recorded retailer sales value per valid in-sample basket
			CAST(AVG(b.basket_sales_value) AS numeric(14, 2)) AS average_basket_value,
			
			-- Total recorded quantity across valid in-sample baskets
			CAST(SUM(b.basket_total_quantity) AS bigint) AS historical_quantity,
			
			-- Retail loyalty-card discounts
			-- Share of valid baskets containing at least one normally encoded retail loyalty-card discount.
			-- e.g. retail_discount_basket_rate = 0.60, meaning 60% of the customer's baskets contained a retail discount.
			CAST(
				AVG(
					CAST(b.has_retail_discount AS integer) -- converts the Boolean into 1 and 0. Then take the average of those 1s and 0s.
				) AS numeric(12, 6)
			) AS retail_discount_basket_rate,
			
			-- Average retail discount amount across ALL valid baskets, including baskets with zero discount.
			CAST(AVG(b.retail_discount_amount) AS numeric(14, 4)) AS retail_discount_per_basket,
			
			-- Total retail loyalty-card discount amount recorded across valid in-sample baskets.
			CAST(SUM(b.retail_discount_amount) AS numeric(16, 2)) AS total_retail_discount,
			
			-- Manufacturer coupons
			-- Share of valid baskets containing a manufacturer coupon
			CAST(
				AVG(CAST(b.has_manufacturer_coupon AS integer)) AS numeric(12, 6)
			) AS manufacturer_coupon_basket_rate,
			
			-- Total manufacturer coupon amount recorded across valid in-sample baskets.
			CAST(
				SUM(b.manufacturer_coupon_amount) AS numeric(16, 2)
			) AS total_manufacturer_coupon,
			
			-- Average manufacturer coupon amount among baskets where a manufacturer coupon was actually used
				-- NULLIF prevents division by zero for households
				-- that never used a manufacturer coupon.
			CAST(
				SUM(b.manufacturer_coupon_amount) / NULLIF(
					SUM(
						CAST(b.has_manufacturer_coupon AS integer) -- If a customer never used a manufacturer coupon, then NULLIF(0, 0). Returns NULL. Avoid something / 0
					),
					0
				) AS numeric(14, 4)
			) AS manufacturer_coupon_amount_per_redeeming_basket,
			
			-- Retail coupon match
			-- Share of valid baskets containing a retailer coupon match.
			CAST(
				AVG(CAST(b.has_retail_coupon_match AS integer)) AS numeric(12, 6)
			) AS retail_coupon_match_basket_rate,
			
			-- Average retailer coupon-match amount across ALL
	        -- valid baskets, including baskets with zero match.
			CAST(
				AVG(b.retail_coupon_match_amount) AS numeric(14, 4)
			) AS retail_coupon_match_per_basket,
			
			-- Total retailer coupon-match amount.
			CAST(
				SUM(b.retail_coupon_match_amount) AS numeric(16, 2)
			) AS total_retail_coupon_match,
			
			-- Pre-retailer-discount value
				-- Estimated total basket value before retailer-funded
		        -- loyalty-card discounts and retailer coupon matches.
		        -- This may later be useful as a denominator for
		        -- discount-intensity measures.
		        -- It should NOT be interpreted as customer
		        -- out-of-pocket spending.
			CAST(
				SUM(b.estimated_pre_retail_discount_value) AS numeric(16, 2)
			) AS estimated_pre_retail_discount_value
		FROM in_sample_baskets AS b
		GROUP BY b.household_key
	)
-- Final output: one row per in-sample household.
SELECT
    -- Household identifier
    g.household_key,

    /* BG/NBD purchase-history features */
    g.in_sample_baskets,
    g.first_purchase_time_days,
    g.last_purchase_time_days,
    g.frequency,
    g.recency_days,
    g.observation_days,

    /* Traditional RFM-style recency */
    g.days_since_last_purchase,

    /* Historical customer activity/value */
    p.active_weeks,
    p.historical_sales,
    p.average_basket_value,
    p.historical_quantity,

    /* Retail loyalty-card discount behaviour */
    p.retail_discount_basket_rate,
    p.retail_discount_per_basket,
    p.total_retail_discount,

    /* Manufacturer coupon behaviour */
    p.manufacturer_coupon_basket_rate,
    p.total_manufacturer_coupon,
    p.manufacturer_coupon_amount_per_redeeming_basket,

    /* Retail coupon-match behaviour */
    p.retail_coupon_match_basket_rate,
    p.retail_coupon_match_per_basket,
    p.total_retail_coupon_match,

    /* Estimated value before retailer-funded discounts */
    p.estimated_pre_retail_discount_value,

    /*
    BG/NBD eligibility / consistency flag.

    Required relationships:

    frequency = in_sample_baskets - 1

    frequency = 0
        ⇒ recency_days = 0

    frequency > 0
        ⇒ recency_days > 0

    0 <= recency_days <= observation_days

    observation_days > 0
    */
    (
        g.in_sample_baskets >= 1

        AND g.frequency
            = g.in_sample_baskets - 1

        AND g.frequency >= 0

        AND g.recency_days >= 0

        AND g.observation_days > 0

        AND g.recency_days
            <= g.observation_days

        AND (
            (
                g.frequency = 0
                AND g.recency_days = 0
            )
            OR
            (
                g.frequency > 0
                AND g.recency_days > 0
            )
        )
    ) AS is_bgnbd_eligible

FROM bgnbd_features AS g

INNER JOIN customer_profile_features AS p
    ON g.household_key = p.household_key;

/*
Both CTEs originate from exactly the same set of valid
in-sample baskets.

Therefore their expected household populations are
identical.

INNER JOIN is appropriate because the final table should
contain complete customer records with both:
- BG/NBD purchase-history features, and
- historical customer-profile features.
*/
	
-----------------------------------------------------------------------------------
----- ADD PRIMARY KEY ----
-----------------------------------------------------------------------------------
-- One row should exist per in-sample household. The primary key enforces this grain.
ALTER TABLE analytics.customer_features
ADD CONSTRAINT pk_customer_features 
PRIMARY KEY (household_key);


-----------------------------------------------------------------------------------
----- VALIDATE CUSTOMER FEATURES VS. FACT BASKET ----
-----------------------------------------------------------------------------------
-- Validate the in-sameple customer features 
/*
Check that the customer-level aggregation preserves:
- in-sample household count
- valid in-sample basket count
- recorded sales
- recorded quantity

Confirmed: all differences = 0. */

WITH params AS (
    SELECT
        in_sample_end_day
    FROM analytics.project_parameters
    WHERE parameter_id = 1
),

fact_totals AS (
    SELECT
        COUNT(DISTINCT b.household_key)
            AS fact_households,

        COUNT(*)
            AS fact_baskets,

        SUM(b.basket_sales_value)
            AS fact_sales,

        SUM(b.basket_total_quantity)
            AS fact_quantity

    FROM analytics.fact_basket AS b

    CROSS JOIN params AS p

    WHERE b.basket_day <= p.in_sample_end_day
      AND b.is_valid_purchase_basket
),

customer_totals AS (
    SELECT
        COUNT(*)
            AS customer_rows,

        SUM(in_sample_baskets)
            AS customer_baskets,

        SUM(historical_sales)
            AS customer_sales,

        SUM(historical_quantity)
            AS customer_quantity

    FROM analytics.customer_features
)

SELECT
    -- Households
    f.fact_households,
    c.customer_rows,

    c.customer_rows
        - f.fact_households
        AS household_difference,  -- 0

    -- Baskets
    f.fact_baskets,
    c.customer_baskets,

    c.customer_baskets
        - f.fact_baskets
        AS basket_difference,     -- 0

    -- Sales
    f.fact_sales,
    c.customer_sales,

    c.customer_sales
        - f.fact_sales
        AS sales_difference,     -- 0

    -- Quantity
    f.fact_quantity,
    c.customer_quantity,

    c.customer_quantity
        - f.fact_quantity
        AS quantity_difference   -- 0

FROM fact_totals AS f

CROSS JOIN customer_totals AS c;




-----------------------------------------------------------------------------------
----- VALIDATE BG/NBD MATHEMATICAL RELATIONSHIPS ----
-----------------------------------------------------------------------------------
/*
Confirmed:
	customers = 2,498
	unique_households = 2,498
	bgnbd_eligible_customers = 2,498
	All invalid counts equal 0.
*/
SELECT
    COUNT(*) AS customers,

    COUNT(DISTINCT household_key)
        AS unique_households,

    COUNT(*) FILTER (
        WHERE in_sample_baskets < 1
    ) AS no_in_sample_baskets,

    COUNT(*) FILTER (
        WHERE frequency
              <> in_sample_baskets - 1
    ) AS invalid_frequency,

    COUNT(*) FILTER (
        WHERE frequency < 0
    ) AS negative_frequency,

    COUNT(*) FILTER (
        WHERE recency_days < 0
    ) AS negative_recency,

    COUNT(*) FILTER (
        WHERE observation_days <= 0
    ) AS nonpositive_observation_time,

    COUNT(*) FILTER (
        WHERE recency_days
              > observation_days
    ) AS recency_greater_than_observation,

    -- One-time purchaser must have t_x = 0.
    COUNT(*) FILTER (
        WHERE frequency = 0
          AND recency_days <> 0
    ) AS invalid_one_time_customers,

    -- Repeat purchaser must have t_x > 0.
    COUNT(*) FILTER (
        WHERE frequency > 0
          AND recency_days <= 0
    ) AS invalid_repeat_customers,

    COUNT(*) FILTER (
        WHERE is_bgnbd_eligible
    ) AS bgnbd_eligible_customers

FROM analytics.customer_features;


-----------------------------------------------------------------------------------
----- VALIDATE 11 ONE-TIME HOUSEHOLDS ----
-----------------------------------------------------------------------------------
/*
Confirmed:
11 households have only one valid in-sample purchase.

For these households:
x = 0
t_x = 0
T > 0

Confirmed: 
one_time_purchasers = 11
minimum_recency_days = 0
maximum_recency_days = 0
minimum_observation_days > 0
maximum_observation_days = 497.369444
*/

SELECT
    COUNT(*) AS one_time_purchasers,
    MIN(recency_days) AS minimum_recency_days,
    MAX(recency_days) AS maximum_recency_days,
    MIN(observation_days) AS minimum_observation_days,
    MAX(observation_days) AS maximum_observation_days
FROM analytics.customer_features
WHERE frequency = 0;

--- Inspect BG/NBD distributions
SELECT
	MIN(frequency) AS min_frequency,
	PERCENTILE_CONT(0.25) WITHIN GROUP (
		ORDER BY
			frequency
	) AS q1_frequency,
	PERCENTILE_CONT(0.50) WITHIN GROUP (
		ORDER BY
			frequency
	) AS median_frequency,
	PERCENTILE_CONT(0.75) WITHIN GROUP (
		ORDER BY
			frequency
	) AS q3_frequency,
	MAX(frequency) AS max_frequency,
	MIN(recency_days) AS min_recency_days,
	PERCENTILE_CONT(0.50) WITHIN GROUP (
		ORDER BY
			recency_days
	) AS median_recency_days,
	MAX(recency_days) AS max_recency_days,
	MIN(observation_days) AS min_observation_days,
	PERCENTILE_CONT(0.50) WITHIN GROUP (
		ORDER BY
			observation_days
	) AS median_observation_days,
	MAX(observation_days) AS max_observation_days
FROM
	analytics.customer_features;

-----------------------------------------------------------------------------------
----- VALIDATE TRADITIONAL RECENCY CALCULATION ----
-----------------------------------------------------------------------------------
/*
By construction:
observation_days
	= recency_days + days_since_last_purchase
or equivalently:
days_since_last_purchase
	= observation_days - recency_days
Confirmed: invalid_recency_identity = 0.
*/

SELECT
    COUNT(*) FILTER (
        WHERE ABS(
            days_since_last_purchase
            - (
                observation_days
                - recency_days
            )
        ) > 0.000001
    ) AS invalid_recency_identity

FROM analytics.customer_features;

-----------------------------------------------------------------------------------
----- CHECK REQUIRED BG/NBD COLUMNS FOR NULL ----
-----------------------------------------------------------------------------------
/*
BG/NBD requires frequency, recency, and observation time
for every modeled household.
Confirmed: 
0 for all.
*/
SELECT
    COUNT(*) FILTER (
        WHERE frequency IS NULL
    ) AS null_frequency,

    COUNT(*) FILTER (
        WHERE recency_days IS NULL
    ) AS null_recency,

    COUNT(*) FILTER (
        WHERE observation_days IS NULL
    ) AS null_observation_time

FROM analytics.customer_features;

-----------------------------------------------------------------------------------
----- CHECK BG/NBD COLUMNS DISTRIBUTIONS ----
-----------------------------------------------------------------------------------
/*
Purpose:
Understand the distributions of x, t_x, and T before
moving into Python model fitting.
*/

SELECT
    -- Frequency x
    MIN(frequency)
        AS min_frequency,

    PERCENTILE_CONT(0.25)
        WITHIN GROUP (
            ORDER BY frequency
        ) AS q1_frequency,

    PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY frequency
        ) AS median_frequency,

    PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY frequency
        ) AS q3_frequency,

    MAX(frequency)
        AS max_frequency,

    -- Recency t_x
    MIN(recency_days)
        AS min_recency_days,

    PERCENTILE_CONT(0.25)
        WITHIN GROUP (
            ORDER BY recency_days
        ) AS q1_recency_days,

    PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY recency_days
        ) AS median_recency_days,

    PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY recency_days
        ) AS q3_recency_days,

    MAX(recency_days)
        AS max_recency_days,

    -- Observation period T
    MIN(observation_days)
        AS min_observation_days,

    PERCENTILE_CONT(0.25)
        WITHIN GROUP (
            ORDER BY observation_days
        ) AS q1_observation_days,

    PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY observation_days
        ) AS median_observation_days,

    PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY observation_days
        ) AS q3_observation_days,

    MAX(observation_days)
        AS max_observation_days

FROM analytics.customer_features;


-----------------------------------------------------------------------------------
----- VALIDATE HISTORICAL CUSTOMER-PROFILE FEATURES ----
-----------------------------------------------------------------------------------
-- Discount/coupon usage rates must fall between 0 and 1.
-- Confirmed: 0 invalid values for all three measures.
SELECT
    COUNT(*) FILTER (
        WHERE retail_discount_basket_rate
              NOT BETWEEN 0 AND 1
    ) AS invalid_retail_discount_rates,

    COUNT(*) FILTER (
        WHERE manufacturer_coupon_basket_rate
              NOT BETWEEN 0 AND 1
    ) AS invalid_manufacturer_coupon_rates,

    COUNT(*) FILTER (
        WHERE retail_coupon_match_basket_rate
              NOT BETWEEN 0 AND 1
    ) AS invalid_retail_coupon_match_rates

FROM analytics.customer_features;


--Validate manufacturer coupon conditional average.
/*
If manufacturer_coupon_basket_rate = 0:
manufacturer_coupon_amount_per_redeeming_basket should be NULL.

If manufacturer_coupon_basket_rate > 0:
manufacturer_coupon_amount_per_redeeming_basket should not
be NULL.

Confirmed:
0 inconsistent rows for both checks.
*/

SELECT
    COUNT(*) FILTER (
        WHERE manufacturer_coupon_basket_rate = 0
          AND manufacturer_coupon_amount_per_redeeming_basket
              IS NOT NULL
    ) AS nonusers_with_coupon_average,

    COUNT(*) FILTER (
        WHERE manufacturer_coupon_basket_rate > 0
          AND manufacturer_coupon_amount_per_redeeming_basket
              IS NULL
    ) AS users_without_coupon_average

FROM analytics.customer_features;

-- Check key totals for unexpected negatives
/*
Customer-level discount totals are expected to be
non-negative after converting normally negative raw
discounts into positive analytical amounts.
Any exceptions need to be inspected. 
Confirmed: all 0
*/

SELECT
    COUNT(*) FILTER (
        WHERE total_retail_discount < 0
    ) AS customers_with_negative_retail_discount,

    COUNT(*) FILTER (
        WHERE total_manufacturer_coupon < 0
    ) AS customers_with_negative_manufacturer_coupon,

    COUNT(*) FILTER (
        WHERE total_retail_coupon_match < 0
    ) AS customers_with_negative_retail_coupon_match,

    COUNT(*) FILTER (
        WHERE estimated_pre_retail_discount_value < 0
    ) AS customers_with_negative_pre_discount_value

FROM analytics.customer_features;



-----------------------------------------------------------------------------------
----- INSPECT UNUSUAL CUSTOMER PROFILES ----
-----------------------------------------------------------------------------------
-- Inspect customers with the largest number of
-- in-sample purchase occasions.
SELECT
    household_key,
    in_sample_baskets,
    frequency,
    recency_days,
    observation_days,
    days_since_last_purchase,
    active_weeks,
    historical_sales,
    average_basket_value
FROM analytics.customer_features
ORDER BY in_sample_baskets DESC
LIMIT 20;


-- Inspect customers with the highest recorded
-- in-sample retailer sales value.
SELECT
    household_key,
    in_sample_baskets,
    historical_sales,
    average_basket_value,
    historical_quantity,

    retail_discount_basket_rate,
    manufacturer_coupon_basket_rate,
    retail_coupon_match_basket_rate
FROM analytics.customer_features
ORDER BY historical_sales DESC
LIMIT 20;

/* =========================================================
03_build_customer_features.sql — final decisions

GRAIN

analytics.customer_features:
1 row = 1 household observed during the in-sample period.

Expected population:
2,498 households.

PURCHASE OCCASION

One valid basket = one BG/NBD purchase occasion.

Same-day and same-minute baskets remain separate when they
have distinct basket_id values.

TIME REPRESENTATION

Purchase timing uses continuous days derived from:

basket_day + basket_trans_time

with:

Day 1 at 00:00 = model time 0.

The in-sample cutoff at the beginning of Day 545 is model
time 544.

BG/NBD VARIABLES

frequency
= x
= valid repeat purchase baskets after the first basket.

recency_days
= t_x
= elapsed time from first to last observed purchase.

observation_days
= T
= elapsed time from first observed purchase to the end of
  the in-sample observation period.

For the 11 one-time purchasers:

x = 0
t_x = 0
T > 0

For the 2,487 repeat purchasers:

x > 0
0 < t_x <= T

All 2,498 households have been confirmed as BG/NBD eligible.

CUSTOMER-PROFILE FEATURES

Historical profile variables are calculated using only
valid in-sample purchase baskets.

No holdout information enters analytics.customer_features.

NEXT STEP

04_build_holdout_and_model_inputs.sql will:

1. create one holdout outcome record for each of these
   2,498 in-sample households;

2. preserve zero-purchase holdout customers as
   actual_holdout_baskets = 0;

3. exclude the two holdout-only households from model
   evaluation;

4. reconcile holdout basket counts and sales;

5. create the final SQL-to-Python BG/NBD model-input view.
========================================================= */


















