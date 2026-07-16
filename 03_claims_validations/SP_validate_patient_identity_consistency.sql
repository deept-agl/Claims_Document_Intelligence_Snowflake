USE ROLE HEALTHCARE_CLAIMS_AI_ROLE;
USE WAREHOUSE HEALTHCARE_CLAIMS_AI_WH;
USE DATABASE HEALTHCARE_CLAIMS_AI_DB;
USE SCHEMA CLAIMS;


CREATE OR REPLACE PROCEDURE VALIDATE_PATIENT_IDENTITY
(
    P_CLAIM_ID VARCHAR
)
RETURNS OBJECT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    V_EXPECTED_NAME       VARCHAR;
    V_EXPECTED_NORMALIZED VARCHAR;
    V_DOCUMENT_COUNT      NUMBER DEFAULT 0;
    V_MISSING_COUNT       NUMBER DEFAULT 0;
    V_MISMATCH_COUNT      NUMBER DEFAULT 0;
    V_EXTRACTED_NAMES     VARCHAR;
    V_STATUS              VARCHAR;
    V_MESSAGE             VARCHAR;
BEGIN

    SELECT
        PATIENT_NAME,
        REGEXP_REPLACE(
            UPPER(PATIENT_NAME),
            '[^A-Z0-9]',
            ''
        )
    INTO
        :V_EXPECTED_NAME,
        :V_EXPECTED_NORMALIZED
    FROM PATIENT_CLAIMS
    WHERE CLAIM_ID = :P_CLAIM_ID;

    DELETE FROM CLAIM_VALIDATION_RESULTS
    WHERE CLAIM_ID = :P_CLAIM_ID
      AND VALIDATION_CATEGORY = 'IDENTITY';

    WITH LATEST_EXTRACTIONS AS
    (
        SELECT
            DOCUMENT_TYPE,
            EXTRACTED_RESPONSE:patient_name::VARCHAR
                AS EXTRACTED_PATIENT_NAME
        FROM DOCUMENT_EXTRACTIONS
        WHERE CLAIM_ID = :P_CLAIM_ID
          AND EXTRACTION_STATUS = 'EXTRACTED'
        QUALIFY ROW_NUMBER() OVER
        (
            PARTITION BY DOCUMENT_ID
            ORDER BY EXTRACTED_AT DESC
        ) = 1
    )
    SELECT
        COUNT(*),

        COUNT_IF(
            EXTRACTED_PATIENT_NAME IS NULL
            OR TRIM(EXTRACTED_PATIENT_NAME) = ''
        ),

        COUNT_IF(
            EXTRACTED_PATIENT_NAME IS NOT NULL
            AND REGEXP_REPLACE(
                    UPPER(EXTRACTED_PATIENT_NAME),
                    '[^A-Z0-9]',
                    ''
                ) <> :V_EXPECTED_NORMALIZED
        ),

        LISTAGG(
            DOCUMENT_TYPE || ': ' ||
            COALESCE(EXTRACTED_PATIENT_NAME, 'NOT EXTRACTED'),
            ' | '
        ) WITHIN GROUP (ORDER BY DOCUMENT_TYPE)

    INTO
        :V_DOCUMENT_COUNT,
        :V_MISSING_COUNT,
        :V_MISMATCH_COUNT,
        :V_EXTRACTED_NAMES

    FROM LATEST_EXTRACTIONS;

    V_STATUS :=
        CASE
            WHEN V_DOCUMENT_COUNT = 0
                THEN 'WARNING'
            WHEN V_MISMATCH_COUNT > 0
                THEN 'FAILED'
            WHEN V_MISSING_COUNT > 0
                THEN 'WARNING'
            ELSE 'PASSED'
        END;

    V_MESSAGE :=
        CASE
            WHEN V_DOCUMENT_COUNT = 0
                THEN 'No extracted documents are available for identity validation.'
            WHEN V_MISMATCH_COUNT > 0
                THEN 'Patient name does not match across all submitted documents.'
            WHEN V_MISSING_COUNT > 0
                THEN 'Patient name could not be extracted from one or more documents.'
            ELSE 'Patient name is consistent across the submitted documents.'
        END;

    INSERT INTO CLAIM_VALIDATION_RESULTS
    (
        CLAIM_ID,
        VALIDATION_CATEGORY,
        VALIDATION_NAME,
        VALIDATION_STATUS,
        EXPECTED_VALUE,
        ACTUAL_VALUE,
        VALIDATION_MESSAGE,
        SEVERITY,
        REQUIRES_REVIEW,
        SOURCE_DOCUMENTS
    )
    SELECT
        :P_CLAIM_ID,
        'IDENTITY',
        'Patient identity consistency',
        :V_STATUS,
        :V_EXPECTED_NAME,
        :V_EXTRACTED_NAMES,
        :V_MESSAGE,
        IFF(:V_STATUS = 'FAILED', 'HIGH', 'MEDIUM'),
        :V_STATUS <> 'PASSED',
        ARRAY_CONSTRUCT(
            'CLAIM_FORM',
            'PRESCRIPTION',
            'DISCHARGE_SUMMARY',
            'HOSPITAL_INVOICE',
            'PHARMACY_INVOICE',
            'DIAGNOSTIC_REPORT',
            'PAYMENT_RECEIPT'
        )
    ;

    RETURN OBJECT_CONSTRUCT(
        'status', V_STATUS,
        'expected_patient_name', V_EXPECTED_NAME,
        'missing_name_count', V_MISSING_COUNT,
        'mismatch_count', V_MISMATCH_COUNT,
        'message', V_MESSAGE
    );

END;
$$;