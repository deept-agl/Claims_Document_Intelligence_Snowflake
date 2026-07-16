USE ROLE HEALTHCARE_CLAIMS_AI_ROLE;
USE WAREHOUSE HEALTHCARE_CLAIMS_AI_WH;
USE DATABASE HEALTHCARE_CLAIMS_AI_DB;
USE SCHEMA CLAIMS;


CREATE OR REPLACE PROCEDURE VALIDATE_REQUIRED_DOCUMENTS
(
    P_CLAIM_ID VARCHAR
)
RETURNS OBJECT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    V_CLAIM_TYPE VARCHAR;
    V_MISSING_DOCUMENTS ARRAY;
BEGIN

    SELECT CLAIM_TYPE
    INTO :V_CLAIM_TYPE
    FROM PATIENT_CLAIMS
    WHERE CLAIM_ID = :P_CLAIM_ID;

    DELETE FROM CLAIM_VALIDATION_RESULTS
    WHERE CLAIM_ID = :P_CLAIM_ID
      AND VALIDATION_CATEGORY = 'DOCUMENT';

    SELECT ARRAY_AGG(REQUIRED_DOCUMENT)
    INTO :V_MISSING_DOCUMENTS
    FROM
    (
        SELECT COLUMN1 AS REQUIRED_DOCUMENT
        FROM VALUES
            ('CLAIM_FORM'),
            ('PRESCRIPTION'),
            ('DISCHARGE_SUMMARY'),
            ('HOSPITAL_INVOICE'),
            ('PAYMENT_RECEIPT')
    ) REQUIRED

    WHERE NOT EXISTS
    (
        SELECT 1
        FROM CLAIM_DOCUMENTS D
        WHERE D.CLAIM_ID = :P_CLAIM_ID
          AND D.DOCUMENT_TYPE = REQUIRED.REQUIRED_DOCUMENT
          AND D.PROCESSING_STATUS = 'EXTRACTED'
    );

    INSERT INTO CLAIM_VALIDATION_RESULTS
    (
        CLAIM_ID,
        VALIDATION_CATEGORY,
        VALIDATION_NAME,
        VALIDATION_STATUS,
        ACTUAL_VALUE,
        VALIDATION_MESSAGE,
        SEVERITY,
        REQUIRES_REVIEW,
        SOURCE_DOCUMENTS
    )
    SELECT
        :P_CLAIM_ID,
        'DOCUMENT',
        'Required documents available',

        IFF(
            ARRAY_SIZE(COALESCE(:V_MISSING_DOCUMENTS, ARRAY_CONSTRUCT())) = 0,
            'PASSED',
            'FAILED'
        ),

        TO_JSON(
            COALESCE(
                :V_MISSING_DOCUMENTS,
                ARRAY_CONSTRUCT()
            )
        ),

        IFF(
            ARRAY_SIZE(COALESCE(:V_MISSING_DOCUMENTS, ARRAY_CONSTRUCT())) = 0,
            'All mandatory documents are available.',
            'One or more mandatory documents are missing.'
        ),

        IFF(
            ARRAY_SIZE(COALESCE(:V_MISSING_DOCUMENTS, ARRAY_CONSTRUCT())) = 0,
            'INFO',
            'HIGH'
        ),

        ARRAY_SIZE(
            COALESCE(
                :V_MISSING_DOCUMENTS,
                ARRAY_CONSTRUCT()
            )
        ) > 0,

        COALESCE(
            :V_MISSING_DOCUMENTS,
            ARRAY_CONSTRUCT()
        );

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'claim_id', P_CLAIM_ID,
        'missing_documents',
        COALESCE(
            V_MISSING_DOCUMENTS,
            ARRAY_CONSTRUCT()
        )
    );

END;
$$;