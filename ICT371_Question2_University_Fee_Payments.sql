
/*
Student Name: YOUR FULL NAME
Student Number: YOUR STUDENT NUMBER
Course Code: ICT371
Assignment: Question 2 - University Fee Payments
*/

/* =====================================================
   STEP 1: REMOVE PREVIOUS QUESTION 2 OBJECTS
   ===================================================== */

DROP VIEW IF EXISTS v_fee_balances CASCADE;

DROP TABLE IF EXISTS
    payment_audit,
    daily_collections,
    payments,
    students
CASCADE;

DROP PROCEDURE IF EXISTS
    pr_receive_payment(INTEGER, NUMERIC, DATE);

DROP PROCEDURE IF EXISTS
    pr_refresh_collections(DATE);

DROP FUNCTION IF EXISTS
    fn_fee_balance(INTEGER);

DROP FUNCTION IF EXISTS
    fn_payment_audit();


/* =====================================================
   STEP 2: CREATE THE STUDENTS TABLE
   ===================================================== */

CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(30) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL,
    fee_due NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);


/* =====================================================
   STEP 3: CREATE THE PAYMENTS TABLE
   ===================================================== */

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL
        REFERENCES students(student_id),
    amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL
);


/* =====================================================
   STEP 4: CREATE THE PAYMENT AUDIT TABLE
   ===================================================== */

CREATE TABLE payment_audit (
    audit_id SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL
        REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL
        REFERENCES students(student_id),
    amount NUMERIC(12,2) NOT NULL,
    logged_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);


/* =====================================================
   STEP 5: CREATE THE DAILY COLLECTIONS TABLE
   ===================================================== */

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INTEGER NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);


/* =====================================================
   STEP 6: INSERT THREE STUDENTS
   Student 3 initially has no payments.
   ===================================================== */

INSERT INTO students
    (student_number, full_name, fee_due)
VALUES
    ('MU2026001', 'John Banda', 1000.00),
    ('MU2026002', 'Mary Phiri', 1500.00),
    ('MU2026003', 'Peter Zulu', 800.00);


/* =====================================================
   STEP 7: CREATE THE FEE BALANCE FUNCTION
   ===================================================== */

CREATE OR REPLACE FUNCTION fn_fee_balance(
    p_student_id INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12,2);
    v_total_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due
    INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Student ID % does not exist',
            p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0)
    INTO v_total_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee_due - v_total_paid;
END;
$$;


/* =====================================================
   STEP 8: CREATE THE PAYMENT AUDIT TRIGGER FUNCTION
   ===================================================== */

CREATE OR REPLACE FUNCTION fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (
        payment_id,
        student_id,
        amount,
        logged_at
    )
    VALUES (
        NEW.payment_id,
        NEW.student_id,
        NEW.amount,
        CURRENT_TIMESTAMP
    );

    RETURN NEW;
END;
$$;


/* =====================================================
   STEP 9: CREATE THE AFTER INSERT AUDIT TRIGGER
   ===================================================== */

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_payment_audit();


/* =====================================================
   STEP 10: CREATE THE PAYMENT PROCEDURE
   ===================================================== */

CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount NUMERIC,
    p_paid_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION
            'Payment amount must be greater than zero';
    END IF;

    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION
            'Payment date cannot be NULL';
    END IF;

    PERFORM 1
    FROM students
    WHERE student_id = p_student_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Student ID % does not exist',
            p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION
            'Payment exceeds outstanding balance. Balance: %, Payment: %',
            v_balance, p_amount;
    END IF;

    INSERT INTO payments (
        student_id,
        amount,
        paid_on
    )
    VALUES (
        p_student_id,
        p_amount,
        p_paid_on
    );

    -- The AFTER INSERT trigger automatically
    -- creates the payment audit record.
    -- fee_due is not changed.

END;
$$;


/* =====================================================
   STEP 11: RECORD SIX PAYMENTS THROUGH THE PROCEDURE
   ===================================================== */

-- Payments for John Banda

CALL pr_receive_payment(1, 250.00, CURRENT_DATE);
CALL pr_receive_payment(1, 150.00, CURRENT_DATE);
CALL pr_receive_payment(1, 100.00, CURRENT_DATE);

-- Payments for Mary Phiri

CALL pr_receive_payment(2, 400.00, CURRENT_DATE);
CALL pr_receive_payment(2, 300.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 200.00, CURRENT_DATE - 1);

-- Peter Zulu initially has no payments.


/* =====================================================
   STEP 12: CREATE THE OUTSTANDING FEE BALANCES VIEW
   ===================================================== */

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    fn_fee_balance(s.student_id) AS outstanding_balance
FROM students s
WHERE fn_fee_balance(s.student_id) > 0;


/* =====================================================
   STEP 13: CREATE THE COMPOSITE INDEX
   ===================================================== */

CREATE INDEX idx_payments_student_paid_on
ON payments (student_id, paid_on);


/* =====================================================
   STEP 14: CREATE THE DAILY COLLECTIONS PROCEDURE
   ===================================================== */

CREATE OR REPLACE PROCEDURE pr_refresh_collections(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION
            'Collection date cannot be NULL';
    END IF;

    INSERT INTO daily_collections (
        collection_date,
        payment_count,
        total_amount
    )
    SELECT
        p_day,
        COUNT(*)::INTEGER,
        COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day

    ON CONFLICT (collection_date)
    DO UPDATE SET
        payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;

END;
$$;


/* =====================================================
   STEP 15: GENERATE DAILY COLLECTION SUMMARIES
   ===================================================== */

CALL pr_refresh_collections(CURRENT_DATE);

CALL pr_refresh_collections(CURRENT_DATE - 1);


/* =====================================================
   STEP 16: SCHEDULE THE DAILY COLLECTION JOB
   Runs daily at 01:00 for the previous day.
   Requires pg_cron to be installed and configured.
   ===================================================== */

DO $$
DECLARE
    v_job_id BIGINT;
BEGIN
    BEGIN
        EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_cron';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE
            'pg_cron could not be enabled: %',
            SQLERRM;
    END;

    IF to_regclass('cron.job') IS NOT NULL THEN

        FOR v_job_id IN
            EXECUTE
                'SELECT jobid FROM cron.job WHERE jobname = $1'
            USING 'university-daily-collections'
        LOOP
            EXECUTE 'SELECT cron.unschedule($1)'
            USING v_job_id;
        END LOOP;

        EXECUTE
            'SELECT cron.schedule($1, $2, $3)'
        INTO v_job_id
        USING
            'university-daily-collections',
            '0 1 * * *',
            'CALL pr_refresh_collections(CURRENT_DATE - 1);';

        RAISE NOTICE
            'Daily collections job scheduled. Job ID: %',
            v_job_id;

    ELSE
        RAISE NOTICE
            'pg_cron is not available. The scheduled job needs server configuration.';
    END IF;
END;
$$;


/* =====================================================
   STEP 17: TEST THE FEE BALANCE FUNCTION
   ===================================================== */

SELECT
    student_id,
    full_name,
    fn_fee_balance(student_id) AS outstanding_balance
FROM students
ORDER BY student_id;


/* =====================================================
   STEP 18: DISPLAY ALL STUDENTS
   ===================================================== */

SELECT *
FROM students
ORDER BY student_id;


/* =====================================================
   STEP 19: DISPLAY ALL PAYMENTS
   ===================================================== */

SELECT *
FROM payments
ORDER BY payment_id;


/* =====================================================
   STEP 20: DISPLAY THE AUTOMATIC PAYMENT AUDIT
   ===================================================== */

SELECT *
FROM payment_audit
ORDER BY audit_id;


/* =====================================================
   STEP 21: DISPLAY THE OUTSTANDING FEE VIEW
   ===================================================== */

SELECT *
FROM v_fee_balances
ORDER BY student_number;


/* =====================================================
   STEP 22: DISPLAY DAILY COLLECTION SUMMARIES
   ===================================================== */

SELECT *
FROM daily_collections
ORDER BY collection_date;


/* =====================================================
   STEP 23: SHOW THE EXPLAIN PLAN FOR THE INDEX QUERY
   ===================================================== */

EXPLAIN
SELECT *
FROM payments
WHERE student_id = 1
AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;


/* =====================================================
   END OF QUESTION 2
   ===================================================== */
