USE ROLE HEALTHCARE_CLAIMS_AI_ROLE;
USE WAREHOUSE HEALTHCARE_CLAIMS_AI_WH;
USE DATABASE HEALTHCARE_CLAIMS_AI_DB;
USE SCHEMA CLAIMS;

CREATE OR REPLACE PROCEDURE
HEALTHCARE_CLAIMS_AI_DB.CLAIMS.VALIDATE_COMPLETE_CLAIM
(
    P_CLAIM_ID VARCHAR
)
RETURNS OBJECT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    V_DOCUMENT_RESULT   OBJECT;
    V_IDENTITY_RESULT   OBJECT;
    V_DATE_RESULT       OBJECT;
    V_MEDICAL_RESULT    OBJECT;
    V_FINANCIAL_RESULT  OBJECT;
    V_QUALITY_RESULT    OBJECT;

    V_CLAIM_COUNT       NUMBER DEFAULT 0;
    V_FAILED_COUNT      NUMBER DEFAULT 0;
    V_WARNING_COUNT     NUMBER DEFAULT 0;
    V_PASSED_COUNT      NUMBER DEFAULT 0;
    V_TOTAL_COUNT       NUMBER DEFAULT 0;

    V_MEDICAL_FAILED    NUMBER DEFAULT 0;
    V_FINANCIAL_FAILED  NUMBER DEFAULT 0;
    V_OTHER_FAILED      NUMBER DEFAULT 0;

    V_RECOMMENDATION    VARCHAR;
    V_FINAL_STATUS      VARCHAR;
    V_FINAL_MESSAGE     VARCHAR;
    V_REQUIRES_REVIEW   BOOLEAN;
    V_SEVERITY          VARCHAR;

BEGIN

    /*==========================================================
      1. Validate claim ID
      ==========================================================*/

    SELECT COUNT(*)
    INTO :V_CLAIM_COUNT
    FROM HEALTHCARE_CLAIMS_AI_DB.CLAIMS.PATIENT_CLAIMS AS C
    WHERE C.CLAIM_ID = :P_CLAIM_ID;


    IF (V_CLAIM_COUNT = 0) THEN

        RETURN OBJECT_CONSTRUCT(
            'status', 'FAILED',
            'claim_id', P_CLAIM_ID,
            'message', 'Claim ID was not found.'
        );

    END IF;


    /*==========================================================
      2. Remove previous validation results
      ==========================================================*/

    DELETE FROM
        HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_VALIDATION_RESULTS AS V
    WHERE V.CLAIM_ID = :P_CLAIM_ID;


    /*==========================================================
      3. Execute individual validations

      Each child procedure must insert its own validation row.
      ==========================================================*/

    CALL HEALTHCARE_CLAIMS_AI_DB.CLAIMS.VALIDATE_REQUIRED_DOCUMENTS(
        :P_CLAIM_ID
    )
    INTO :V_DOCUMENT_RESULT;


    CALL HEALTHCARE_CLAIMS_AI_DB.CLAIMS.VALIDATE_PATIENT_IDENTITY(
        :P_CLAIM_ID
    )
    INTO :V_IDENTITY_RESULT;


    CALL HEALTHCARE_CLAIMS_AI_DB.CLAIMS.VALIDATE_TREATMENT_DATES(
        :P_CLAIM_ID
    )
    INTO :V_DATE_RESULT;



    CALL HEALTHCARE_CLAIMS_AI_DB.CLAIMS.VALIDATE_PRESCRIPTION_MEDICINES(
        :P_CLAIM_ID
    )
    INTO :V_MEDICAL_RESULT;
    


    CALL HEALTHCARE_CLAIMS_AI_DB.CLAIMS.VALIDATE_FINANCIAL_DETAILS(
        :P_CLAIM_ID
    )
    INTO :V_FINANCIAL_RESULT;


    /*
    CALL HEALTHCARE_CLAIMS_AI_DB.CLAIMS.VALIDATE_EXTRACTION_QUALITY(
        :P_CLAIM_ID,
        0.75
    )
    INTO :V_QUALITY_RESULT;
    */


    /*==========================================================
      4. Count validation results
      ==========================================================*/

    SELECT
        COUNT_IF(V.VALIDATION_STATUS = 'FAILED'),
        COUNT_IF(V.VALIDATION_STATUS = 'WARNING'),
        COUNT_IF(V.VALIDATION_STATUS = 'PASSED'),
        COUNT(*),

        COUNT_IF(
            V.VALIDATION_CATEGORY = 'MEDICAL'
            AND V.VALIDATION_STATUS = 'FAILED'
        ),

        COUNT_IF(
            V.VALIDATION_CATEGORY = 'FINANCIAL'
            AND V.VALIDATION_STATUS = 'FAILED'
        ),

        COUNT_IF(
            V.VALIDATION_CATEGORY IN
            (
                'DOCUMENT',
                'IDENTITY',
                'TREATMENT_DATE',
                'EXTRACTION_QUALITY'
            )
            AND V.VALIDATION_STATUS = 'FAILED'
        )

    INTO
        :V_FAILED_COUNT,
        :V_WARNING_COUNT,
        :V_PASSED_COUNT,
        :V_TOTAL_COUNT,
        :V_MEDICAL_FAILED,
        :V_FINANCIAL_FAILED,
        :V_OTHER_FAILED

    FROM
        HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_VALIDATION_RESULTS AS V

    WHERE
        V.CLAIM_ID = :P_CLAIM_ID;


    /*==========================================================
      5. Determine recommendation
      ==========================================================*/

    V_RECOMMENDATION :=
        CASE
            WHEN V_MEDICAL_FAILED > 0
                THEN 'MEDICAL_REVIEW_REQUIRED'

            WHEN V_FINANCIAL_FAILED > 0
                THEN 'FINANCIAL_REVIEW_REQUIRED'

            WHEN V_OTHER_FAILED > 0
                THEN 'MORE_INFORMATION_REQUIRED'

            WHEN V_WARNING_COUNT > 0
                THEN 'MANUAL_REVIEW_REQUIRED'

            ELSE 'READY_FOR_APPROVAL'
        END;


    V_FINAL_STATUS :=
        CASE
            WHEN V_FAILED_COUNT > 0
                THEN 'FAILED'

            WHEN V_WARNING_COUNT > 0
                THEN 'WARNING'

            ELSE 'PASSED'
        END;


    V_REQUIRES_REVIEW :=
        CASE
            WHEN V_FINAL_STATUS = 'PASSED'
                THEN FALSE
            ELSE TRUE
        END;


    V_SEVERITY :=
        CASE
            WHEN V_FAILED_COUNT > 0
                THEN 'HIGH'

            WHEN V_WARNING_COUNT > 0
                THEN 'MEDIUM'

            ELSE 'INFO'
        END;


    V_FINAL_MESSAGE :=
        CASE
            WHEN V_RECOMMENDATION = 'MEDICAL_REVIEW_REQUIRED'
                THEN
                    'Medical validation failed. The claim requires medical review.'

            WHEN V_RECOMMENDATION = 'FINANCIAL_REVIEW_REQUIRED'
                THEN
                    'Financial validation failed. The claim requires financial review.'

            WHEN V_RECOMMENDATION = 'MORE_INFORMATION_REQUIRED'
                THEN
                    'Required information is missing or inconsistent.'

            WHEN V_RECOMMENDATION = 'MANUAL_REVIEW_REQUIRED'
                THEN
                    'The claim contains warnings that require manual review.'

            ELSE
                'All completed validations passed. The claim is ready for approval.'
        END;


    /*==========================================================
      6. Insert consolidated validation result
      ==========================================================*/

    INSERT INTO
        HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_VALIDATION_RESULTS
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
        'CLAIM_DECISION',
        'Overall claim validation',
        :V_FINAL_STATUS,
        'All mandatory claim validations should pass.',

        TO_JSON(
            OBJECT_CONSTRUCT(
                'recommendation', :V_RECOMMENDATION,
                'total_validations', :V_TOTAL_COUNT,
                'passed_validations', :V_PASSED_COUNT,
                'warning_validations', :V_WARNING_COUNT,
                'failed_validations', :V_FAILED_COUNT
            )
        ),

        :V_FINAL_MESSAGE,
        :V_SEVERITY,
        :V_REQUIRES_REVIEW,
        ARRAY_CONSTRUCT('ALL_SUBMITTED_DOCUMENTS');


    /*==========================================================
      7. Update claim status
      ==========================================================*/

    UPDATE
        HEALTHCARE_CLAIMS_AI_DB.CLAIMS.PATIENT_CLAIMS AS C
    SET
        C.CLAIM_STATUS = :V_RECOMMENDATION
    WHERE
        C.CLAIM_ID = :P_CLAIM_ID;


    /*==========================================================
      8. Return validation summary
      ==========================================================*/

    RETURN OBJECT_CONSTRUCT_KEEP_NULL(
        'status', 'SUCCESS',
        'claim_id', P_CLAIM_ID,

        'total_validations', V_TOTAL_COUNT,
        'passed_validations', V_PASSED_COUNT,
        'warning_validations', V_WARNING_COUNT,
        'failed_validations', V_FAILED_COUNT,

        'recommendation', V_RECOMMENDATION,

        'document_validation', V_DOCUMENT_RESULT,
        'identity_validation', V_IDENTITY_RESULT,
        'date_validation', V_DATE_RESULT,
        'medical_validation', V_MEDICAL_RESULT,
        'financial_validation', V_FINANCIAL_RESULT,
        'quality_validation', V_QUALITY_RESULT
    );

END;
$$;


CALL HEALTHCARE_CLAIMS_AI_DB.CLAIMS.VALIDATE_COMPLETE_CLAIM(
    'CLM-01005'
);
