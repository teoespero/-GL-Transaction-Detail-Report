/* =================================================================================================
   AUTHOR: Teo Espero, IT Administrator
   DATE WRITTEN: 01/29/2026

   SCRIPT NAME
   -------------------------------------------------------------------------------------------------
   GL Transaction Detail Report (Springbrook) with Cost Center / Department / Account Type Mapping

   DESCRIPTION
   -------------------------------------------------------------------------------------------------
   Returns detailed General Ledger transaction history (gl_history) joined to the Chart of Accounts
   (gl_chart) to provide:

     - Account number (acct_1-acct_2-acct_3-acct_4 formatted as 'xx-xx-xxx-xxx')
     - Cost Center name (based on acct_1)
     - Department name (based on acct_2)
     - Account Type category (based on first letter of gl_chart.account_type)
     - Account description and budget fields from gl_chart
     - Transaction debits/credits and transaction description from gl_history

   TABLES USED
   -------------------------------------------------------------------------------------------------
   Springbrook0.dbo.gl_chart
     - alfre, account_type, description, budget, encumbered_amt
     - acct_1..acct_4, fiscal_year

   Springbrook0.dbo.gl_history
     - fiscal_year, fiscal_period, dr_amount, cr_amount, description
     - acct_1..acct_4

   JOIN LOGIC
   -------------------------------------------------------------------------------------------------
   gl_history joins to gl_chart on:
     - fiscal_year
     - acct_1, acct_2, acct_3, acct_4

   BUSINESS DEFINITIONS
   -------------------------------------------------------------------------------------------------
   Cost Center (acct_1)
     01 = MW  (Marina Water)
     02 = MS  (Marina Sewer)
     03 = OW  (Ord Water)
     04 = OS  (Ord Sewer)
     05 = RW  (Recycled Water)
     07 = GSA (Groundwater Sustainability Agency)

   Department (acct_2)
     01 = Administration
     02 = O&M
     03 = Lab
     04 = Conservation
     05 = Engineering
     06 = Water Resources - MCWD
     07 = Water Resources - GSA

   Account Type Category (gl_chart.account_type first letter)
     A = Asset
     L = Liability
     F = Fund Balance
     R = Revenue
     E = Expense

   FILTERING (ALL if NULL)
   -------------------------------------------------------------------------------------------------
   1) Fiscal Range:
        @BegFiscalYear, @BegFiscalPeriod, @EndFiscalYear, @EndFiscalPeriod
      - Supports cross-year ranges using a sortable key: FiscalKey = (FiscalYear * 100) + FiscalPeriod
      - If you supply only fiscal year (no period), the script assumes full-year range for that year.

   2) Segment Ranges:
        @BegAcct1..@EndAcct1, @BegAcct2..@EndAcct2, @BegAcct3..@EndAcct3, @BegAcct4..@EndAcct4
      - If NULL, defaults to "all".

   3) Business-Friendly Selectors:
        @CostCenter (char(2)) maps to acct_1
        @Department (char(2)) maps to acct_2
      - If NULL, defaults to "all".
      - If specified, it applies as an exact match filter.

   4) Account Type:
        @AcctType = 'A','L','F','R','E' or NULL for all

   OUTPUT
   -------------------------------------------------------------------------------------------------
   One row per GL transaction line item (from gl_history) with attached chart attributes.

================================================================================================= */

DECLARE
    /* ---------------- Fiscal Range (optional; NULL = ALL) ---------------- */
    @BegFiscalYear    int = 2026,
    @BegFiscalPeriod  int = 1,
    @EndFiscalYear    int = 2026,
    @EndFiscalPeriod  int = 5,

    /* -------------- Segment Ranges (optional; NULL = ALL) ---------------- */
    @BegAcct1 int = NULL, @EndAcct1 int = NULL,
    @BegAcct2 int = NULL, @EndAcct2 int = NULL,
    @BegAcct3 int = NULL, @EndAcct3 int = NULL,
    @BegAcct4 int = NULL, @EndAcct4 int = NULL,

    /* -------- Business-Friendly Selectors (optional; NULL = ALL) --------- */
    @CostCenter  char(2) = NULL,  -- '01','02','03','04','05','07'
    @Department  char(2) = '05',  -- '01'..'07'

    /* -------------- Account Type (optional; NULL = ALL) ----------------- */
    @AcctType char(1) = 'E';     -- 'A','L','F','R','E'

/* =========================================================================================
   PRACTICAL EXAMPLES (copy one example at a time into the DECLARE section above)
   =========================================================================================

   Example 1: All transactions (no filters)
     -- leave everything NULL

   Example 2: FY 2026 only (all periods)
     @BegFiscalYear = 2026,
     @EndFiscalYear = 2026

   Example 3: FY 2025 Period 3 through FY 2026 Period 2 (cross-year)
     @BegFiscalYear = 2025, @BegFiscalPeriod = 3,
     @EndFiscalYear = 2026, @EndFiscalPeriod = 2

   Example 4: MW (01) + Engineering (05) only, all years/periods
     @CostCenter = '01',
     @Department = '05'

   Example 5: Expenses only for MW (01), FY 2026
     @BegFiscalYear = 2026, @EndFiscalYear = 2026,
     @CostCenter = '01',
     @AcctType = 'E'

   Example 6: Account segment range (acct3 and acct4 ranges), FY 2026
     @BegFiscalYear = 2026, @EndFiscalYear = 2026,
     @BegAcct3 = 100, @EndAcct3 = 199,
     @BegAcct4 = 0,   @EndAcct4 = 999

================================================================================================= */


/* =========================
   Normalize fiscal range
   ========================= */
DECLARE
    @BegFY int = ISNULL(@BegFiscalYear, 0),
    @BegFP int = ISNULL(@BegFiscalPeriod, 0),
    @EndFY int = ISNULL(@EndFiscalYear, 9999),
    @EndFP int = ISNULL(@EndFiscalPeriod, 99);

-- If user supplies only a year, assume full-year coverage.
IF @BegFiscalYear IS NOT NULL AND @BegFiscalPeriod IS NULL SET @BegFP = 0;
IF @EndFiscalYear IS NOT NULL AND @EndFiscalPeriod IS NULL SET @EndFP = 99;

DECLARE
    @BegFiscalKey int = (@BegFY * 100) + @BegFP,
    @EndFiscalKey int = (@EndFY * 100) + @EndFP;


/* =========================
   Normalize account ranges
   ========================= */
DECLARE
    @A1Beg int = ISNULL(@BegAcct1, 0),      @A1End int = ISNULL(@EndAcct1, 9999),
    @A2Beg int = ISNULL(@BegAcct2, 0),      @A2End int = ISNULL(@EndAcct2, 9999),
    @A3Beg int = ISNULL(@BegAcct3, 0),      @A3End int = ISNULL(@EndAcct3, 999999),
    @A4Beg int = ISNULL(@BegAcct4, 0),      @A4End int = ISNULL(@EndAcct4, 999999),

    -- Normalize selectors
    @CostCenterInt int = TRY_CAST(@CostCenter AS int),
    @DepartmentInt int = TRY_CAST(@Department AS int),
    @AcctTypeNorm  char(1) = NULLIF(UPPER(LTRIM(RTRIM(@AcctType))), '');


;WITH Chart AS (
    SELECT
        c.fiscal_year,
        c.acct_1, c.acct_2, c.acct_3, c.acct_4,

        AccountNumber =
            RIGHT('00' + CAST(c.acct_1 AS varchar(2)), 2) + '-' +
            RIGHT('00' + CAST(c.acct_2 AS varchar(2)), 2) + '-' +
            RIGHT('000' + CAST(c.acct_3 AS varchar(3)), 3) + '-' +
            RIGHT('000' + CAST(c.acct_4 AS varchar(3)), 3),

        c.alfre,
        c.account_type,

        AccountTypeCategory =
            CASE LEFT(LTRIM(RTRIM(ISNULL(c.account_type,''))), 1)
                WHEN 'A' THEN 'A - Asset'
                WHEN 'L' THEN 'L - Liability'
                WHEN 'F' THEN 'F - Fund Balance'
                WHEN 'R' THEN 'R - Revenue'
                WHEN 'E' THEN 'E - Expense'
                ELSE 'Unknown'
            END,

        AccountDescription = c.description,
        c.budget,
        c.encumbered_amt,

        CostCenterName =
            CASE RIGHT('00' + CAST(c.acct_1 AS varchar(2)), 2)
                WHEN '01' THEN 'MW - Marina Water'
                WHEN '02' THEN 'MS - Marina Sewer'
                WHEN '03' THEN 'OW - Ord Water'
                WHEN '04' THEN 'OS - Ord Sewer'
                WHEN '05' THEN 'RW - Recycled Water'
                WHEN '07' THEN 'GSA - Groundwater Sustainability Agency'
                ELSE 'Other/Unknown'
            END,

        DepartmentName =
            CASE RIGHT('00' + CAST(c.acct_2 AS varchar(2)), 2)
                WHEN '01' THEN 'Administration'
                WHEN '02' THEN 'O&M'
                WHEN '03' THEN 'Lab'
                WHEN '04' THEN 'Conservation'
                WHEN '05' THEN 'Engineering'
                WHEN '06' THEN 'Water Resources - MCWD'
                WHEN '07' THEN 'Water Resources - GSA'
                ELSE 'Other/Unknown'
            END
    FROM Springbrook0.dbo.gl_chart c
    WHERE
        -- Segment ranges (ALL if NULL)
        c.acct_1 BETWEEN @A1Beg AND @A1End
        AND c.acct_2 BETWEEN @A2Beg AND @A2End
        AND c.acct_3 BETWEEN @A3Beg AND @A3End
        AND c.acct_4 BETWEEN @A4Beg AND @A4End

        -- Business-friendly selectors (ALL if NULL)
        AND (@CostCenterInt IS NULL OR c.acct_1 = @CostCenterInt)
        AND (@DepartmentInt IS NULL OR c.acct_2 = @DepartmentInt)

        -- Account type filter (ALL if NULL)
        AND (
            @AcctTypeNorm IS NULL
            OR LEFT(LTRIM(RTRIM(ISNULL(c.account_type,''))), 1) = @AcctTypeNorm
        )
),
Hist AS (
    SELECT
        h.gl_history_id,
        h.fiscal_year,
        h.fiscal_period,
        FiscalKey = (h.fiscal_year * 100) + h.fiscal_period,

        h.acct_1, h.acct_2, h.acct_3, h.acct_4,

        h.dr_amount,
        h.cr_amount,
        HistoryDescription = h.description
    FROM Springbrook0.dbo.gl_history h
    WHERE
        -- Fiscal range (ALL if NULL)
        ((h.fiscal_year * 100) + h.fiscal_period) BETWEEN @BegFiscalKey AND @EndFiscalKey

        -- Segment ranges (ALL if NULL)
        AND h.acct_1 BETWEEN @A1Beg AND @A1End
        AND h.acct_2 BETWEEN @A2Beg AND @A2End
        AND h.acct_3 BETWEEN @A3Beg AND @A3End
        AND h.acct_4 BETWEEN @A4Beg AND @A4End

        -- Business-friendly selectors (ALL if NULL)
        AND (@CostCenterInt IS NULL OR h.acct_1 = @CostCenterInt)
        AND (@DepartmentInt IS NULL OR h.acct_2 = @DepartmentInt)
)
SELECT
    -- Account & fiscal identifiers
    AccountNumber = c.AccountNumber,
    h.fiscal_year,
    h.fiscal_period,

    -- Mapped business definitions
    c.CostCenterName,
    c.DepartmentName,

    -- Chart attributes
    c.alfre,
    c.account_type,
    c.AccountTypeCategory,
    c.AccountDescription,
    c.budget,
    c.encumbered_amt,

    -- History detail
    h.dr_amount,
    h.cr_amount,
    --NetAmount = ISNULL(h.cr_amount, 0) - ISNULL(h.dr_amount, 0),
    TransactionDescription = h.HistoryDescription
FROM Hist h
INNER JOIN Chart c
    ON  c.fiscal_year = h.fiscal_year
    AND c.acct_1 = h.acct_1
    AND c.acct_2 = h.acct_2
    AND c.acct_3 = h.acct_3
    AND c.acct_4 = h.acct_4
ORDER BY
    c.CostCenterName,          -- MW, MS, OW, OS, RW, GSA
    c.DepartmentName,          -- Admin, O&M, Engineering, etc.
    c.AccountNumber,           -- xx-xx-xxx-xxx
    h.fiscal_year,
    h.fiscal_period,
    h.gl_history_id;
