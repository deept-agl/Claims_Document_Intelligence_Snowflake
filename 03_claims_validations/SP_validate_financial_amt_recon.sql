
USE ROLE HEALTHCARE_CLAIMS_AI_ROLE;
USE WAREHOUSE HEALTHCARE_CLAIMS_AI_WH;
USE DATABASE HEALTHCARE_CLAIMS_AI_DB;
USE SCHEMA CLAIMS;

CREATE OR REPLACE PROCEDURE VALIDATE_FINANCIAL_DETAILS
(
    P_CLAIM_ID VARCHAR
)
RETURNS OBJECT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    V_CLAIMED_AMOUNT       NUMBER(18,2);
    V_HOSPITAL_AMOUNT      NUMBER(18,2);
    V_PHARMACY_AMOUNT      NUMBER(18,2);
    V_RECEIPT_AMOUNT       NUMBER(18,2);
    V_SUPPORTED_AMOUNT     NUMBER(18,2);
    V_CLAIM_DIFFERENCE     NUMBER(18,2);
    V_RECEIPT_DIFFERENCE   NUMBER(18,2);
    V_STATUS               VARCHAR;
    V_MESSAGE              VARCHAR;
    V_ACTUAL_VALUE         VARCHAR;
    V_TOLERANCE            NUMBER(18,2) DEFAULT 1.00;
BEGIN

    SELECT CLAIMED_AMOUNT
    INTO :V_CLAIMED_AMOUNT
    FROM PATIENT_CLAIMS
    WHERE CLAIM_ID = :P_CLAIM_ID;

    DELETE FROM CLAIM_VALIDATION_RESULTS
    WHERE CLAIM_ID = :P_CLAIM_ID
      AND VALIDATION_CATEGORY = 'FINANCIAL';

    WITH LATEST_EXTRACTIONS AS
    (
        SELECT
            DOCUMENT_ID,
            DOCUMENT_TYPE,
            EXTRACTED_RESPONSE
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
        MAX(
            CASE
                WHEN DOCUMENT_TYPE = 'HOSPITAL_INVOICE'
                THEN TRY_TO_DECIMAL(
                    REGEXP_REPLACE(
                        EXTRACTED_RESPONSE:invoice_total::VARCHAR,
                        '[^0-9.-]',
                        ''
                    ),
                    18,
                    2
                )
            END
        ),

        MAX(
            CASE
                WHEN DOCUMENT_TYPE = 'PHARMACY_INVOICE'
                THEN TRY_TO_DECIMAL(
                    REGEXP_REPLACE(
                        EXTRACTED_RESPONSE:invoice_total::VARCHAR,
                        '[^0-9.-]',
                        ''
                    ),
                    18,
                    2
                )
            END
        ),

        MAX(
            CASE
                WHEN DOCUMENT_TYPE = 'PAYMENT_RECEIPT'
                THEN TRY_TO_DECIMAL(
                    REGEXP_REPLACE(
                        EXTRACTED_RESPONSE:amount_paid::VARCHAR,
                        '[^0-9.-]',
                        ''
                    ),
                    18,
                    2
                )
            END
        )

    INTO
        :V_HOSPITAL_AMOUNT,
        :V_PHARMACY_AMOUNT,
        :V_RECEIPT_AMOUNT

    FROM LATEST_EXTRACTIONS;

    V_SUPPORTED_AMOUNT :=
        COALESCE(V_HOSPITAL_AMOUNT, 0)
        + COALESCE(V_PHARMACY_AMOUNT, 0);

    V_CLAIM_DIFFERENCE :=
        COALESCE(V_CLAIMED_AMOUNT, 0)
        - COALESCE(V_SUPPORTED_AMOUNT, 0);

    V_RECEIPT_DIFFERENCE :=
        COALESCE(V_RECEIPT_AMOUNT, 0)
        - COALESCE(V_SUPPORTED_AMOUNT, 0);

    V_STATUS :=
        CASE
            WHEN V_HOSPITAL_AMOUNT IS NULL
                THEN 'WARNING'

            WHEN ABS(V_CLAIM_DIFFERENCE) > V_TOLERANCE
                THEN 'FAILED'

            WHEN V_RECEIPT_AMOUNT IS NULL
                THEN 'WARNING'

            WHEN ABS(V_RECEIPT_DIFFERENCE) > V_TOLERANCE
                THEN 'FAILED'

            ELSE 'PASSED'
        END;

    V_MESSAGE :=
        CASE
            WHEN V_HOSPITAL_AMOUNT IS NULL
                THEN 'Hospital invoice total could not be extracted.'

            WHEN ABS(V_CLAIM_DIFFERENCE) > V_TOLERANCE
                THEN 'Claimed amount does not match the supported invoice amount.'

            WHEN V_RECEIPT_AMOUNT IS NULL
                THEN 'Payment receipt amount could not be extracted.'

            WHEN ABS(V_RECEIPT_DIFFERENCE) > V_TOLERANCE
                THEN 'Payment receipt amount does not match the supported invoice amount.'

            ELSE 'Claimed amount, invoice totals and payment receipt are consistent.'
        END;

    V_ACTUAL_VALUE := TO_JSON(
        OBJECT_CONSTRUCT(
            'claimed_amount', V_CLAIMED_AMOUNT,
            'hospital_invoice_amount', V_HOSPITAL_AMOUNT,
            'pharmacy_invoice_amount', V_PHARMACY_AMOUNT,
            'supported_amount', V_SUPPORTED_AMOUNT,
            'payment_receipt_amount', V_RECEIPT_AMOUNT,
            'claim_difference', V_CLAIM_DIFFERENCE,
            'receipt_difference', V_RECEIPT_DIFFERENCE
        )
    );

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
        'FINANCIAL',
        'Claim amount reconciliation',
        :V_STATUS,
        'Claimed and paid amounts should match supported invoice totals.',
        :V_ACTUAL_VALUE,
        :V_MESSAGE,
        IFF(:V_STATUS = 'FAILED', 'HIGH', 'MEDIUM'),
        :V_STATUS <> 'PASSED',
        ARRAY_CONSTRUCT(
            'CLAIM_FORM',
            'HOSPITAL_INVOICE',
            'PHARMACY_INVOICE',
            'PAYMENT_RECEIPT'
        )
        ;

    RETURN OBJECT_CONSTRUCT(
        'status', V_STATUS,
        'claimed_amount', V_CLAIMED_AMOUNT,
        'supported_amount', V_SUPPORTED_AMOUNT,
        'payment_receipt_amount', V_RECEIPT_AMOUNT,
        'claim_difference', V_CLAIM_DIFFERENCE,
        'message', V_MESSAGE
    );

END;
$$;