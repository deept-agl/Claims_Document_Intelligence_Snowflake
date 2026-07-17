USE ROLE HEALTHCARE_CLAIMS_AI_ROLE;
USE WAREHOUSE HEALTHCARE_CLAIMS_AI_WH;
USE DATABASE HEALTHCARE_CLAIMS_AI_DB;
USE SCHEMA CLAIMS;


CREATE OR REPLACE FUNCTION EXTRACT_DOCUMENT_DATA
(
    STAGE_NAME STRING,
    FILE_PATH STRING
    --INPUT_TEMPLATE_ID STRING
)
RETURNS OBJECT
LANGUAGE SQL
AS
$$
    SELECT AI_EXTRACT(
        file => TO_FILE(
            STAGE_NAME,
            FILE_PATH
        ),
        responseFormat => (
            SELECT RESPONSE_FORMAT
            FROM PROMPT_TEMPLATES
            WHERE TEMPLATE_ID = INPUT_TEMPLATE_ID
              AND 
              IS_ACTIVE = TRUE
            QUALIFY ROW_NUMBER() OVER (
                ORDER BY TEMPLATE_VERSION DESC
            ) = 1
        ),
        scores => TRUE,
        config => {
            'scale_factor': 2.0
        }
    )
$$;

--Load files for a patient and in optional path put folder name



 /*============================================================
   TEST THE EXTRACTION FUNCTION
   ============================================================ */ 

SELECT
    HEALTHCARE_CLAIMS_AI_DB.CLAIMS.EXTRACT_DOCUMENT_DATA(
        '@HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENT_STAGE',
        'Gregorio366_Auer97_f5dcd418/handwritten_prescription.png',
        'PRESCRIPTION_V1'
    ) AS EXTRACTION_RESULT;

SELECT
    HEALTHCARE_CLAIMS_AI_DB.CLAIMS.EXTRACT_DOCUMENT_DATA(
        '@HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENT_STAGE',
        'Gregorio366_Auer97_f5dcd418/claim_form.pdf',
        'CLAIM_FORM_V1'
    ) AS EXTRACTION_RESULT;

SELECT
    HEALTHCARE_CLAIMS_AI_DB.CLAIMS.EXTRACT_DOCUMENT_DATA(
        '@HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENT_STAGE',
        'Gregorio366_Auer97_f5dcd418/diagnostic_report.pdf',
        'DIAGNOSTIC_REPORT_V1'
    ) AS EXTRACTION_RESULT;
