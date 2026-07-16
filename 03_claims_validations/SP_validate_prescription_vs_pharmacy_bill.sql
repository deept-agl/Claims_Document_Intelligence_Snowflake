USE ROLE HEALTHCARE_CLAIMS_AI_ROLE;
USE WAREHOUSE HEALTHCARE_CLAIMS_AI_WH;
USE DATABASE HEALTHCARE_CLAIMS_AI_DB;
USE SCHEMA CLAIMS;


CREATE OR REPLACE PROCEDURE VALIDATE_PRESCRIPTION_MEDICINES
(
    P_CLAIM_ID VARCHAR
)
RETURNS OBJECT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    V_PRESCRIPTION_COUNT NUMBER DEFAULT 0;
    V_PHARMACY_COUNT     NUMBER DEFAULT 0;
    V_UNMATCHED_COUNT    NUMBER DEFAULT 0;

    V_PRESCRIBED_ITEMS   ARRAY DEFAULT ARRAY_CONSTRUCT();
    V_PURCHASED_ITEMS    ARRAY DEFAULT ARRAY_CONSTRUCT();
    V_UNMATCHED_ITEMS    ARRAY DEFAULT ARRAY_CONSTRUCT();

    V_STATUS             VARCHAR;
    V_MESSAGE            VARCHAR;
    V_SEVERITY           VARCHAR;
    V_REQUIRES_REVIEW    BOOLEAN;

BEGIN

    /* Remove previous result for this validation */
    DELETE FROM CLAIM_VALIDATION_RESULTS
    WHERE CLAIM_ID = :P_CLAIM_ID
      AND VALIDATION_CATEGORY = 'MEDICAL'
      AND VALIDATION_NAME =
          'Prescription and pharmacy medicine match';


    /*==========================================================
      1. Count medicines extracted from prescription
      ==========================================================*/

    SELECT
        COUNT(DISTINCT
            REGEXP_REPLACE(
                UPPER(F.VALUE::VARCHAR),
                '[^A-Z0-9]',
                ''
            )
        ),
        COALESCE(
            ARRAY_AGG(DISTINCT F.VALUE::VARCHAR),
            ARRAY_CONSTRUCT()
        )
    INTO
        :V_PRESCRIPTION_COUNT,
        :V_PRESCRIBED_ITEMS
    FROM
    (
        SELECT
            E.DOCUMENT_ID,
            E.EXTRACTED_RESPONSE
        FROM DOCUMENT_EXTRACTIONS AS E
        WHERE E.CLAIM_ID = :P_CLAIM_ID
          AND E.DOCUMENT_TYPE = 'PRESCRIPTION'
          AND E.EXTRACTION_STATUS = 'EXTRACTED'
        QUALIFY ROW_NUMBER() OVER
        (
            PARTITION BY E.DOCUMENT_ID
            ORDER BY E.EXTRACTED_AT DESC
        ) = 1
    ) AS P,
    LATERAL FLATTEN
    (
        INPUT => P.EXTRACTED_RESPONSE:medicines:medicine_name,
        OUTER => TRUE
    ) AS F
    WHERE F.VALUE IS NOT NULL
      AND NOT IS_NULL_VALUE(F.VALUE);


    /*==========================================================
      2. Count medicines extracted from pharmacy invoice
      ==========================================================*/

    SELECT
        COUNT(DISTINCT
            REGEXP_REPLACE(
                UPPER(F.VALUE::VARCHAR),
                '[^A-Z0-9]',
                ''
            )
        ),
        COALESCE(
            ARRAY_AGG(DISTINCT F.VALUE::VARCHAR),
            ARRAY_CONSTRUCT()
        )
    INTO
        :V_PHARMACY_COUNT,
        :V_PURCHASED_ITEMS
    FROM
    (
        SELECT
            E.DOCUMENT_ID,
            E.EXTRACTED_RESPONSE
        FROM DOCUMENT_EXTRACTIONS AS E
        WHERE E.CLAIM_ID = :P_CLAIM_ID
          AND E.DOCUMENT_TYPE = 'PHARMACY_INVOICE'
          AND E.EXTRACTION_STATUS = 'EXTRACTED'
        QUALIFY ROW_NUMBER() OVER
        (
            PARTITION BY E.DOCUMENT_ID
            ORDER BY E.EXTRACTED_AT DESC
        ) = 1
    ) AS P,
    LATERAL FLATTEN
    (
        INPUT => P.EXTRACTED_RESPONSE:medicine_items:medicine_name,
        OUTER => TRUE
    ) AS F
    WHERE F.VALUE IS NOT NULL
      AND NOT IS_NULL_VALUE(F.VALUE);


    /*==========================================================
      3. Find pharmacy medicines not present in prescription
      ==========================================================*/

    WITH LATEST_EXTRACTIONS AS
    (
        SELECT
            E.DOCUMENT_ID,
            E.DOCUMENT_TYPE,
            E.EXTRACTED_RESPONSE
        FROM DOCUMENT_EXTRACTIONS AS E
        WHERE E.CLAIM_ID = :P_CLAIM_ID
          AND E.DOCUMENT_TYPE IN
          (
              'PRESCRIPTION',
              'PHARMACY_INVOICE'
          )
          AND E.EXTRACTION_STATUS = 'EXTRACTED'
        QUALIFY ROW_NUMBER() OVER
        (
            PARTITION BY E.DOCUMENT_ID
            ORDER BY E.EXTRACTED_AT DESC
        ) = 1
    ),

    PRESCRIBED_MEDICINES AS
    (
        SELECT DISTINCT
            F.VALUE::VARCHAR AS MEDICINE_NAME,

            REGEXP_REPLACE(
                UPPER(F.VALUE::VARCHAR),
                '[^A-Z0-9]',
                ''
            ) AS NORMALIZED_MEDICINE_NAME

        FROM LATEST_EXTRACTIONS AS E,
        LATERAL FLATTEN
        (
            INPUT => E.EXTRACTED_RESPONSE:medicines:medicine_name
        ) AS F

        WHERE E.DOCUMENT_TYPE = 'PRESCRIPTION'
          AND F.VALUE IS NOT NULL
          AND NOT IS_NULL_VALUE(F.VALUE)
    ),

    PURCHASED_MEDICINES AS
    (
        SELECT DISTINCT
            F.VALUE::VARCHAR AS MEDICINE_NAME,

            REGEXP_REPLACE(
                UPPER(F.VALUE::VARCHAR),
                '[^A-Z0-9]',
                ''
            ) AS NORMALIZED_MEDICINE_NAME

        FROM LATEST_EXTRACTIONS AS E,
        LATERAL FLATTEN
        (
            INPUT =>
                E.EXTRACTED_RESPONSE:medicine_items:medicine_name
        ) AS F

        WHERE E.DOCUMENT_TYPE = 'PHARMACY_INVOICE'
          AND F.VALUE IS NOT NULL
          AND NOT IS_NULL_VALUE(F.VALUE)
    ),

    UNMATCHED AS
    (
        SELECT
            PHARMACY.MEDICINE_NAME
        FROM PURCHASED_MEDICINES AS PHARMACY

        WHERE NOT EXISTS
        (
            SELECT 1
            FROM PRESCRIBED_MEDICINES AS PRESCRIPTION

            WHERE
                PHARMACY.NORMALIZED_MEDICINE_NAME =
                PRESCRIPTION.NORMALIZED_MEDICINE_NAME

                OR PHARMACY.NORMALIZED_MEDICINE_NAME LIKE
                   '%' ||
                   PRESCRIPTION.NORMALIZED_MEDICINE_NAME ||
                   '%'

                OR PRESCRIPTION.NORMALIZED_MEDICINE_NAME LIKE
                   '%' ||
                   PHARMACY.NORMALIZED_MEDICINE_NAME ||
                   '%'
        )
    )

    SELECT
        COUNT(*),
        COALESCE(
            ARRAY_AGG(MEDICINE_NAME),
            ARRAY_CONSTRUCT()
        )
    INTO
        :V_UNMATCHED_COUNT,
        :V_UNMATCHED_ITEMS
    FROM UNMATCHED;


    /*==========================================================
      4. Determine validation status
      ==========================================================*/

    V_STATUS :=
        CASE
            WHEN V_PRESCRIPTION_COUNT = 0
             AND V_PHARMACY_COUNT = 0
                THEN 'WARNING'

            WHEN V_PRESCRIPTION_COUNT = 0
                THEN 'WARNING'

            WHEN V_PHARMACY_COUNT = 0
                THEN 'WARNING'

            WHEN V_UNMATCHED_COUNT > 0
                THEN 'FAILED'

            ELSE 'PASSED'
        END;


    V_MESSAGE :=
        CASE
            WHEN V_PRESCRIPTION_COUNT = 0
             AND V_PHARMACY_COUNT = 0
                THEN
                    'No medicines were extracted from either the prescription or pharmacy invoice.'

            WHEN V_PRESCRIPTION_COUNT = 0
                THEN
                    'No medicines were extracted from the prescription.'

            WHEN V_PHARMACY_COUNT = 0
                THEN
                    'No medicines were extracted from the pharmacy invoice.'

            WHEN V_UNMATCHED_COUNT > 0
                THEN
                    'One or more purchased medicines were not found in the prescription.'

            ELSE
                'All purchased medicines were found in the prescription.'
        END;


    V_SEVERITY :=
        CASE
            WHEN V_STATUS = 'FAILED'
                THEN 'HIGH'

            WHEN V_STATUS = 'WARNING'
                THEN 'MEDIUM'

            ELSE 'INFO'
        END;


    V_REQUIRES_REVIEW :=
        V_STATUS <> 'PASSED';


    /*==========================================================
      5. Insert validation result
      ==========================================================*/

    INSERT INTO CLAIM_VALIDATION_RESULTS
    (
        VALIDATION_ID,
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
        UUID_STRING(),
        :P_CLAIM_ID,
        'MEDICAL',
        'Prescription and pharmacy medicine match',
        :V_STATUS,

        'All purchased medicines should be supported by the prescription.',

        TO_JSON(
            OBJECT_CONSTRUCT(
                'prescribed_medicines',
                    :V_PRESCRIBED_ITEMS,

                'purchased_medicines',
                    :V_PURCHASED_ITEMS,

                'unmatched_medicines',
                    :V_UNMATCHED_ITEMS,

                'prescribed_medicine_count',
                    :V_PRESCRIPTION_COUNT,

                'purchased_medicine_count',
                    :V_PHARMACY_COUNT,

                'unmatched_medicine_count',
                    :V_UNMATCHED_COUNT
            )
        ),

        :V_MESSAGE,
        :V_SEVERITY,
        :V_REQUIRES_REVIEW,

        ARRAY_CONSTRUCT(
            'PRESCRIPTION',
            'PHARMACY_INVOICE'
        );


    /*==========================================================
      6. Return result
      ==========================================================*/

    RETURN OBJECT_CONSTRUCT_KEEP_NULL(
        'status',
            V_STATUS,

        'prescribed_medicine_count',
            V_PRESCRIPTION_COUNT,

        'purchased_medicine_count',
            V_PHARMACY_COUNT,

        'unmatched_medicine_count',
            V_UNMATCHED_COUNT,

        'prescribed_medicines',
            V_PRESCRIBED_ITEMS,

        'purchased_medicines',
            V_PURCHASED_ITEMS,

        'unmatched_medicines',
            V_UNMATCHED_ITEMS,

        'message',
            V_MESSAGE
    );

END;
$$;

