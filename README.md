# From Past Sales to Future Purchases
## Customer Profiles and Promotion Insights

This project combines **historical sales** with **expected future purchases** to create customer profiles, then compares their historical discount and coupon patterns.

The analysis shows that past sales are a strong signal of future activity, while forward-looking purchase predictions add useful differentiation for some customers. Promotion patterns provide additional context, but they do not support a simple **“more promotion = better future activity”** conclusion.

The profiles are therefore best used to identify where different promotion and engagement approaches may be worth exploring further.

---

## Project objective

Retailers often know how much customers purchased in the past, but historical sales alone do not necessarily tell the full story about future purchasing.

Two households may have generated similar historical sales while having different expected future purchase activity.

This project therefore asks:

> **How do customers with different combinations of historical sales and expected future purchases differ in their observed discount and coupon patterns, and what promotion or engagement hypotheses could these differences motivate for future testing?**

The goal is not to prescribe customer treatments directly, but to create a more forward-looking customer view that can support further analysis and experimentation.

---

## Dataset

This project uses the **dunnhumby Complete Journey** grocery retail dataset.

The transaction data is recorded at the **product level**, meaning one shopping basket may contain multiple transaction rows.

For this project:

- one **household** is treated as one customer
- one **basket** represents one shopping trip / purchase occasion
- product-level transaction rows are aggregated to basket level
- **2,498 households** are included in the modelling and customer-profile analysis

The raw dataset is **not included in this repository**.

---

## Analysis periods

The data is divided into two periods.

### Historical / model-building period

The first **544 days** are used to:

- calculate historical sales
- construct customer purchase-history measures
- fit the BG/NBD model
- calculate historical promotion measures
- define the final customer profiles

### Holdout period

The following **167 days** are kept separate from model fitting.

This period is used to compare:

- predicted future purchases
- actual future purchases

The holdout period therefore provides an **out-of-sample evaluation** of the model.

---

## Analytical workflow

The project follows this structure:

```text
Raw transaction data
        ↓
Basket-level transaction table
        ↓
Historical customer measures
        ↓
Historical sales analysis
        ↓
BG/NBD future-purchase model
        ↓
Holdout evaluation
        ↓
Historical sales × expected future purchases
        ↓
Customer profiles
        ↓
Promotion-pattern comparison
        ↓
Business hypotheses for further testing
```
---

## Tools and technologies

| Tool / Technology | How it was used |
|---|---|
| **PostgreSQL / SQL** | Data validation, basket-level aggregation, historical/holdout period definition, and preparation of customer-level sales, purchase, and promotion measures. |
| **Python** | Modelling, model evaluation, customer-profile analysis, promotion analysis, and visualization. |
| **pandas** | Data manipulation, joins, customer-level summaries, profile comparisons, and preparation of analysis outputs. |
| **NumPy** | Numerical calculations and array operations used in the analysis and visualizations. |
| **lifetimes** | Fitting the **BG/NBD model** and estimating household-level expected future purchases. |
| **SciPy** | Supporting statistical and distribution-related calculations. |
| **Matplotlib & Seaborn** | Creating presentation-ready analytical charts and profile comparisons. |
| **Jupyter Notebook** | Organizing the Python modelling, evaluation, analysis, visualizations, and interpretation workflow. |
| **Git / GitHub** | Version control, project organization, documentation, and project sharing. |
| **PowerPoint** | Translating analytical results into a business-focused presentation. |

---

