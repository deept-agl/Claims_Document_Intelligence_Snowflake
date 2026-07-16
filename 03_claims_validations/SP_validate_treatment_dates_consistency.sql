USE ROLE HEALTHCARE_CLAIMS_AI_ROLE;
USE WAREHOUSE HEALTHCARE_CLAIMS_AI_WH;
USE DATABASE HEALTHCARE_CLAIMS_AI_DB;
USE SCHEMA CLAIMS;


CREATE OR REPLACE PROCEDURE VALIDATE_TREATMENT_DATES
(
    P_CLAIM_ID VARCHAR
)
RETURNS OBJECT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    V_ADMISSION_DATE_COUNT  NUMBER DEFAULT 0;
    V_DISCHARGE_DATE_COUNT  NUMBER DEFAULT 0;
    V_ADMISSION_VARIANTS    NUMBER DEFAULT 0;
    V_DISCHARGE_VARIANTS    NUMBER DEFAULT 0;

    V_MIN_ADMISSION_DATE    DATE;
    V_MAX_ADMISSION_DATE    DATE;
    V_MIN_DISCHARGE_DATE    DATE;
    V_MAX_DISCHARGE_DATE    DATE;

    V_STATUS                VARCHAR;
    V_MESSAGE               VARCHAR;
    V_ACTUAL_VALUE          VARCHAR;

BEGIN

    DELETE FROM CLAIM_VALIDATION_RESULTS
    WHERE CLAIM_ID = :P_CLAIM_ID
      AND VALIDATION_CATEGORY = 'TREATMENT_DATE';


    WITH LATEST_EXTRACTIONS AS
    (
        SELECT
            DOCUMENT_ID,
            DOCUMENT_TYPE,

            COALESCE(
                TRY_TO_DATE(
                    EXTRACTED_RESPONSE:admission_date::VARCHAR,
                    'DD-MM-YYYY'
                ),
                TRY_TO_DATE(
                    EXTRACTED_RESPONSE:admission_date::VARCHAR,
                    'YYYY-MM-DD'
                ),
                TRY_TO_DATE(
                    EXTRACTED_RESPONSE:date_of_admission::VARCHAR,
                    'DD-MM-YYYY'
                ),
                TRY_TO_DATE(
                    EXTRACTED_RESPONSE:date_of_admission::VARCHAR,
                    'YYYY-MM-DD'
                )
            ) AS ADMISSION_DATE,

            COALESCE(
                TRY_TO_DATE(
                    EXTRACTED_RESPONSE:discharge_date::VARCHAR,
                    'DD-MM-YYYY'
                ),
                TRY_TO_DATE(
                    EXTRACTED_RESPONSE:discharge_date::VARCHAR,
                    'YYYY-MM-DD'
                ),
                TRY_TO_DATE(
                    EXTRACTED_RESPONSE:date_of_discharge::VARCHAR,
                    'DD-MM-YYYY'
                ),
                TRY_TO_DATE(
                    EXTRACTED_RESPONSE:date_of_discharge::VARCHAR,
                    'YYYY-MM-DD'
                )
            ) AS DISCHARGE_DATE

        FROM DOCUMENT_EXTRACTIONS

        WHERE CLAIM_ID = :P_CLAIM_ID

          AND DOCUMENT_TYPE IN
          (
              'CLAIM_FORM',
              'DISCHARGE_SUMMARY',
              'HOSPITAL_INVOICE'
          )

          AND EXTRACTION_STATUS = 'EXTRACTED'

        QUALIFY ROW_NUMBER() OVER
        (
            PARTITION BY DOCUMENT_ID
            ORDER BY EXTRACTED_AT DESC
        ) = 1
    )

    SELECT
        COUNT(ADMISSION_DATE),
        COUNT(DISCHARGE_DATE),

        COUNT(DISTINCT ADMISSION_DATE),
        COUNT(DISTINCT DISCHARGE_DATE),

        MIN(ADMISSION_DATE),
        MAX(ADMISSION_DATE),

        MIN(DISCHARGE_DATE),
        MAX(DISCHARGE_DATE)

    INTO
        :V_ADMISSION_DATE_COUNT,
        :V_DISCHARGE_DATE_COUNT,

        :V_ADMISSION_VARIANTS,
        :V_DISCHARGE_VARIANTS,

        :V_MIN_ADMISSION_DATE,
        :V_MAX_ADMISSION_DATE,

        :V_MIN_DISCHARGE_DATE,
        :V_MAX_DISCHARGE_DATE

    FROM LATEST_EXTRACTIONS;


    V_STATUS :=
        CASE
            WHEN V_ADMISSION_DATE_COUNT = 0
              OR V_DISCHARGE_DATE_COUNT = 0
                THEN 'WARNING'

            WHEN V_ADMISSION_VARIANTS > 1
              OR V_DISCHARGE_VARIANTS > 1
                THEN 'FAILED'

            WHEN V_MIN_ADMISSION_DATE > V_MAX_DISCHARGE_DATE
                THEN 'FAILED'

            ELSE 'PASSED'
        END;


    V_MESSAGE :=
        CASE
            WHEN V_ADMISSION_DATE_COUNT = 0
              OR V_DISCHARGE_DATE_COUNT = 0
                THEN
                    'Admission or discharge date is missing from the extracted documents.'

            WHEN V_ADMISSION_VARIANTS > 1
                THEN
                    'Admission date is inconsistent across the submitted documents.'

            WHEN V_DISCHARGE_VARIANTS > 1
                THEN
                    'Discharge date is inconsistent across the submitted documents.'

            WHEN V_MIN_ADMISSION_DATE > V_MAX_DISCHARGE_DATE
                THEN
                    'Admission date is later than discharge date.'

            ELSE
                'Admission and discharge dates are consistent.'
        END;


    V_ACTUAL_VALUE :=
        TO_JSON(
            OBJECT_CONSTRUCT_KEEP_NULL(
                'minimum_admission_date',
                V_MIN_ADMISSION_DATE,

                'maximum_admission_date',
                V_MAX_ADMISSION_DATE,

                'minimum_discharge_date',
                V_MIN_DISCHARGE_DATE,

                'maximum_discharge_date',
                V_MAX_DISCHARGE_DATE,

                'admission_date_count',
                V_ADMISSION_DATE_COUNT,

                'discharge_date_count',
                V_DISCHARGE_DATE_COUNT,

                'admission_date_variants',
                V_ADMISSION_VARIANTS,

                'discharge_date_variants',
                V_DISCHARGE_VARIANTS
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
        'TREATMENT_DATE',
        'Admission and discharge date consistency',
        :V_STATUS,

        'Matching dates across claim form, discharge summary and hospital invoice',

        :V_ACTUAL_VALUE,
        :V_MESSAGE,

        CASE
            WHEN :V_STATUS = 'FAILED'
                THEN 'HIGH'

            WHEN :V_STATUS = 'WARNING'
                THEN 'MEDIUM'

            ELSE 'INFO'
        END,

        :V_STATUS <> 'PASSED',

        ARRAY_CONSTRUCT(
            'CLAIM_FORM',
            'DISCHARGE_SUMMARY',
            'HOSPITAL_INVOICE'
        );


    RETURN OBJECT_CONSTRUCT_KEEP_NULL(
        'status',
        V_STATUS,

        'admission_date',
        V_MIN_ADMISSION_DATE,

        'discharge_date',
        V_MAX_DISCHARGE_DATE,

        'admission_date_count',
        V_ADMISSION_DATE_COUNT,

        'discharge_date_count',
        V_DISCHARGE_DATE_COUNT,

        'message',
        V_MESSAGE
    );

END;
$$;