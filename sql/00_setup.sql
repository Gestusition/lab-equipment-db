-- =====================================================================
-- 00 SETUP
-- Drops every module schema, installs extensions and defines the
-- helpers shared by all modules. Safe to run repeatedly.
-- =====================================================================

DROP SCHEMA IF EXISTS test      CASCADE;
DROP SCHEMA IF EXISTS report    CASCADE;
DROP SCHEMA IF EXISTS audit     CASCADE;
DROP SCHEMA IF EXISTS finance   CASCADE;
DROP SCHEMA IF EXISTS service   CASCADE;
DROP SCHEMA IF EXISTS booking   CASCADE;
DROP SCHEMA IF EXISTS training  CASCADE;
DROP SCHEMA IF EXISTS inventory CASCADE;
DROP SCHEMA IF EXISTS org       CASCADE;

-- btree_gist lets exclusion constraints combine "=" on scalar columns
-- with "&&" (overlap) on range columns.
CREATE EXTENSION IF NOT EXISTS btree_gist;
-- dblink opens a second connection from inside SQL; the test suite uses
-- it to run genuinely concurrent transactions.
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE SCHEMA org;
CREATE SCHEMA inventory;
CREATE SCHEMA training;
CREATE SCHEMA booking;
CREATE SCHEMA service;
CREATE SCHEMA finance;
CREATE SCHEMA audit;
CREATE SCHEMA report;

-- Reusable domains -----------------------------------------------------

DROP DOMAIN IF EXISTS public.email_address CASCADE;
CREATE DOMAIN public.email_address AS text
    CHECK (VALUE ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$');

DROP DOMAIN IF EXISTS public.money_amount CASCADE;
CREATE DOMAIN public.money_amount AS numeric(12,2)
    CHECK (VALUE >= 0);

-- Shared helper: raise a business-rule violation with a stable SQLSTATE
-- so tests can tell rule violations apart from ordinary errors.
-- P0001 is the generic PL/pgSQL "raise_exception" code; we use custom
-- codes in the 'LB' class (LaB) instead.
--   LB001 membership   LB002 authorization  LB003 availability
--   LB004 workflow     LB005 history        LB006 hierarchy
--   LB007 budget       LB008 specialization
CREATE OR REPLACE FUNCTION public.rule_violation(p_code text, p_message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION USING ERRCODE = p_code, MESSAGE = p_message;
END $$;
