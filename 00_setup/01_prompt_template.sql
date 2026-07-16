
USE ROLE HEALTHCARE_CLAIMS_AI_ROLE;
USE WAREHOUSE HEALTHCARE_CLAIMS_AI_WH;
USE DATABASE HEALTHCARE_CLAIMS_AI_DB;
USE SCHEMA CLAIMS;

/* ============================================================
   PROMPT TEMPLATE 
  
   ============================================================ */
CREATE OR REPLACE TABLE PROMPT_TEMPLATES
(
    TEMPLATE_ID          VARCHAR,
    DOCUMENT_TYPE        VARCHAR,
    TEMPLATE_DESCRIPTION VARCHAR,
    TEMPLATE_VERSION     NUMBER,
    RESPONSE_FORMAT      VARIANT,
    IS_ACTIVE            BOOLEAN DEFAULT TRUE,
    CREATED_AT           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),

    PRIMARY KEY (TEMPLATE_ID, TEMPLATE_VERSION)
);

/* ============================================================
   PROMPT TEMPLATE -Insert individual documents templates
   ============================================================ */


/* ============================================================
   PROMPT TEMPLATE -CLAIMS FORM
   ============================================================ */
INSERT INTO PROMPT_TEMPLATES
(
    TEMPLATE_ID,
    DOCUMENT_TYPE,
    TEMPLATE_DESCRIPTION,
    TEMPLATE_VERSION,
    RESPONSE_FORMAT
)
SELECT
    'CLAIM_FORM_V1',
    'CLAIM_FORM',
    'Extract patient and insurance claim details',
    1,
    PARSE_JSON($$
    {
      "schema": {
        "type": "object",
        "properties": {
          "claim_id": {
            "description": "Claim ID shown on the insurance claim form",
            "type": "string"
          },
          "patient_id": {
            "description": "Patient or member ID",
            "type": "string"
          },
          "patient_name": {
            "description": "Full name of the patient",
            "type": "string"
          },
          "policy_number": {
            "description": "Insurance policy number",
            "type": "string"
          },
          "insurance_provider": {
            "description": "Insurance company or payer name",
            "type": "string"
          },
          "claim_type": {
            "description": "Claim type such as hospitalization, outpatient, or day care",
            "type": "string"
          },
          "hospital_name": {
            "description": "Hospital or healthcare facility name",
            "type": "string"
          },
          "admission_date": {
            "description": "Patient admission date. Return YYYY-MM-DD when possible",
            "type": "string"
          },
          "discharge_date": {
            "description": "Patient discharge date. Return YYYY-MM-DD when possible",
            "type": "string"
          },
          "primary_diagnosis": {
            "description": "Primary diagnosis written on the claim form",
            "type": "string"
          },
          "claimed_amount": {
            "description": "Total reimbursement amount requested",
            "type": "string"
          },
          "patient_signature_present": {
            "description": "Return YES if a signature or handwritten mark is present in the patient signature area. Otherwise return NO. Do not authenticate the signer",
            "type": "string"
          }
        }
      }
    }
    $$);


    /* ============================================================
   PROMPT TEMPLATE -HANDWRITTEN PRESCRIPTION 
   ============================================================ */
   INSERT INTO PROMPT_TEMPLATES
(
    TEMPLATE_ID,
    DOCUMENT_TYPE,
    TEMPLATE_DESCRIPTION,
    TEMPLATE_VERSION,
    RESPONSE_FORMAT
)
SELECT
    'PRESCRIPTION_V1',
    'PRESCRIPTION',
    'Extract printed and handwritten prescription details',
    1,
    PARSE_JSON($$
    {
      "schema": {
        "type": "object",
        "properties": {
          "patient_name": {
            "description": "Patient name, including handwritten text",
            "type": "string"
          },
          "patient_age": {
            "description": "Patient age",
            "type": "string"
          },
          "doctor_name": {
            "description": "Prescribing doctor name, including handwritten text",
            "type": "string"
          },
          "hospital_or_clinic": {
            "description": "Hospital or clinic name",
            "type": "string"
          },
          "prescription_date": {
            "description": "Prescription date. Return YYYY-MM-DD when possible",
            "type": "string"
          },
          "diagnosis": {
            "description": "Printed or handwritten diagnosis exactly as written",
            "type": "string"
          },
          "follow_up_instructions": {
            "description": "Printed or handwritten follow-up instructions",
            "type": "string"
          },
          "doctor_signature_present": {
            "description": "Return YES if a signature or handwritten mark appears in the doctor signature area. Otherwise return NO. Do not authenticate the signer",
            "type": "string"
          },
          "medicines": {
            "description": "Extract all prescribed medicines and handwritten instructions",
            "type": "object",
            "column_ordering": [
              "medicine_name",
              "strength",
              "dosage",
              "frequency",
              "duration",
              "instructions"
            ],
            "properties": {
              "medicine_name": {
                "description": "Medicine name",
                "type": "array"
              },
              "strength": {
                "description": "Medicine strength such as 500 mg",
                "type": "array"
              },
              "dosage": {
                "description": "Dosage per administration",
                "type": "array"
              },
              "frequency": {
                "description": "Frequency such as once daily or twice daily",
                "type": "array"
              },
              "duration": {
                "description": "Treatment duration such as 5 days",
                "type": "array"
              },
              "instructions": {
                "description": "Medicine instructions such as before meals or after meals",
                "type": "array"
              }
            }
          }
        }
      }
    }
    $$);

    /* ============================================================
   PROMPT TEMPLATE -DISCHARGE SUMMARY
   ============================================================ */

    INSERT INTO PROMPT_TEMPLATES
(
    TEMPLATE_ID,
    DOCUMENT_TYPE,
    TEMPLATE_DESCRIPTION,
    TEMPLATE_VERSION,
    RESPONSE_FORMAT
)
SELECT
    'DISCHARGE_SUMMARY_V1',
    'DISCHARGE_SUMMARY',
    'Extract clinical discharge details',
    1,
    PARSE_JSON($$
    {
      "schema": {
        "type": "object",
        "properties": {
          "patient_name": {
            "description": "Full patient name",
            "type": "string"
          },
          "patient_id": {
            "description": "Patient or hospital registration ID",
            "type": "string"
          },
          "hospital_name": {
            "description": "Hospital name",
            "type": "string"
          },
          "admission_date": {
            "description": "Admission date. Return YYYY-MM-DD when possible",
            "type": "string"
          },
          "discharge_date": {
            "description": "Discharge date. Return YYYY-MM-DD when possible",
            "type": "string"
          },
          "attending_doctor": {
            "description": "Attending doctor name",
            "type": "string"
          },
          "primary_diagnosis": {
            "description": "Primary or final diagnosis",
            "type": "string"
          },
          "clinical_summary": {
            "description": "Summary of treatment and hospital stay",
            "type": "string"
          },
          "procedures_performed": {
            "description": "Procedures performed during treatment",
            "type": "array"
          },
          "discharge_medications": {
            "description": "Medicines prescribed at discharge",
            "type": "array"
          },
          "follow_up_advice": {
            "description": "Follow-up or discharge instructions",
            "type": "string"
          },
          "discharge_condition": {
            "description": "Patient condition at discharge",
            "type": "string"
          }
        }
      }
    }
    $$);

    /* ============================================================
   PROMPT TEMPLATE - HOSPITAL INVOICE 
   ============================================================ */

   INSERT INTO PROMPT_TEMPLATES
(
    TEMPLATE_ID,
    DOCUMENT_TYPE,
    TEMPLATE_DESCRIPTION,
    TEMPLATE_VERSION,
    RESPONSE_FORMAT
)
SELECT
    'HOSPITAL_INVOICE_V1',
    'HOSPITAL_INVOICE',
    'Extract hospital invoice totals and line items',
    1,
    PARSE_JSON($$
    {
      "schema": {
        "type": "object",
        "properties": {
          "invoice_number": {
            "description": "Hospital invoice number",
            "type": "string"
          },
          "claim_id": {
            "description": "Claim ID referenced by the invoice",
            "type": "string"
          },
          "patient_name": {
            "description": "Patient full name",
            "type": "string"
          },
          "patient_id": {
            "description": "Patient or hospital registration ID",
            "type": "string"
          },
          "hospital_name": {
            "description": "Hospital name",
            "type": "string"
          },
          "admission_date": {
            "description": "Admission date",
            "type": "string"
          },
          "discharge_date": {
            "description": "Discharge date",
            "type": "string"
          },
          "diagnosis": {
            "description": "Diagnosis shown on the invoice",
            "type": "string"
          },
          "subtotal": {
            "description": "Subtotal before discounts and adjustments",
            "type": "string"
          },
          "discount": {
            "description": "Discount amount",
            "type": "string"
          },
          "tax_amount": {
            "description": "Tax amount",
            "type": "string"
          },
          "invoice_total": {
            "description": "Final hospital invoice payable amount",
            "type": "string"
          },
          "invoice_items": {
            "description": "Extract all hospital invoice charge line items",
            "type": "object",
            "column_ordering": [
              "description",
              "quantity",
              "rate",
              "amount"
            ],
            "properties": {
              "description": {
                "description": "Description of the hospital service or charge",
                "type": "array"
              },
              "quantity": {
                "description": "Quantity or number of days",
                "type": "array"
              },
              "rate": {
                "description": "Rate per unit",
                "type": "array"
              },
              "amount": {
                "description": "Line-item amount",
                "type": "array"
              }
            }
          }
        }
      }
    }
    $$);


    /*============================================================
   PROMPT TEMPLATE - PHARMACY INVOICE 
   ============================================================ */ 

    INSERT INTO PROMPT_TEMPLATES
(
    TEMPLATE_ID,
    DOCUMENT_TYPE,
    TEMPLATE_DESCRIPTION,
    TEMPLATE_VERSION,
    RESPONSE_FORMAT
)
SELECT
    'PHARMACY_INVOICE_V1',
    'PHARMACY_INVOICE',
    'Extract pharmacy invoice and medicine line items',
    1,
    PARSE_JSON($$
    {
      "schema": {
        "type": "object",
        "properties": {
          "invoice_number": {
            "description": "Pharmacy invoice number",
            "type": "string"
          },
          "claim_id": {
            "description": "Claim ID referenced by the invoice",
            "type": "string"
          },
          "patient_name": {
            "description": "Patient full name",
            "type": "string"
          },
          "pharmacy_name": {
            "description": "Pharmacy name",
            "type": "string"
          },
          "invoice_date": {
            "description": "Invoice date. Return YYYY-MM-DD when possible",
            "type": "string"
          },
          "prescribing_doctor": {
            "description": "Prescribing doctor name",
            "type": "string"
          },
          "invoice_total": {
            "description": "Final pharmacy invoice amount",
            "type": "string"
          },
          "medicine_items": {
            "description": "Extract all purchased medicine line items",
            "type": "object",
            "column_ordering": [
              "medicine_name",
              "strength",
              "quantity",
              "unit_price",
              "line_amount"
            ],
            "properties": {
              "medicine_name": {
                "description": "Purchased medicine name",
                "type": "array"
              },
              "strength": {
                "description": "Medicine strength",
                "type": "array"
              },
              "quantity": {
                "description": "Purchased quantity",
                "type": "array"
              },
              "unit_price": {
                "description": "Price per unit",
                "type": "array"
              },
              "line_amount": {
                "description": "Total amount for the medicine line",
                "type": "array"
              }
            }
          }
        }
      }
    }
    $$);

 /*============================================================
   PROMPT TEMPLATE - PHARMACY INVOICE 
   ============================================================ */ 

   INSERT INTO PROMPT_TEMPLATES
(
    TEMPLATE_ID,
    DOCUMENT_TYPE,
    TEMPLATE_DESCRIPTION,
    TEMPLATE_VERSION,
    RESPONSE_FORMAT
)
SELECT
    'DIAGNOSTIC_REPORT_V1',
    'DIAGNOSTIC_REPORT',
    'Extract diagnostic report results',
    1,
    PARSE_JSON($$
    {
      "schema": {
        "type": "object",
        "properties": {
          "patient_name": {
            "description": "Full patient name",
            "type": "string"
          },
          "patient_id": {
            "description": "Patient or laboratory ID",
            "type": "string"
          },
          "laboratory_name": {
            "description": "Laboratory or diagnostic centre name",
            "type": "string"
          },
          "ordering_doctor": {
            "description": "Doctor who ordered the tests",
            "type": "string"
          },
          "report_date": {
            "description": "Diagnostic report date",
            "type": "string"
          },
          "diagnosis": {
            "description": "Diagnosis or clinical reason written in the report",
            "type": "string"
          },
          "clinical_interpretation": {
            "description": "Clinical interpretation written in the report. Do not generate a new diagnosis",
            "type": "string"
          },
          "test_results": {
            "description": "Extract all test and observation results",
            "type": "object",
            "column_ordering": [
              "test_date",
              "test_name",
              "result",
              "reference_or_comment"
            ],
            "properties": {
              "test_date": {
                "description": "Date of the test",
                "type": "array"
              },
              "test_name": {
                "description": "Test or observation name",
                "type": "array"
              },
              "result": {
                "description": "Reported test result",
                "type": "array"
              },
              "reference_or_comment": {
                "description": "Reference range or report comment",
                "type": "array"
              }
            }
          }
        }
      }
    }
    $$);


 /*============================================================
   PROMPT TEMPLATE - PAYMENT RECEIPT 
   ============================================================ */ 
   INSERT INTO PROMPT_TEMPLATES
(
    TEMPLATE_ID,
    DOCUMENT_TYPE,
    TEMPLATE_DESCRIPTION,
    TEMPLATE_VERSION,
    RESPONSE_FORMAT
)
SELECT
    'PAYMENT_RECEIPT_V1',
    'PAYMENT_RECEIPT',
    'Extract payment receipt details',
    1,
    PARSE_JSON($$
    {
      "schema": {
        "type": "object",
        "properties": {
          "receipt_number": {
            "description": "Payment receipt number",
            "type": "string"
          },
          "claim_id": {
            "description": "Claim ID",
            "type": "string"
          },
          "patient_name": {
            "description": "Patient full name",
            "type": "string"
          },
          "hospital_invoice_number": {
            "description": "Referenced hospital invoice number",
            "type": "string"
          },
          "pharmacy_invoice_number": {
            "description": "Referenced pharmacy invoice number",
            "type": "string"
          },
          "payment_date": {
            "description": "Payment date",
            "type": "string"
          },
          "amount_paid": {
            "description": "Total amount paid",
            "type": "string"
          },
          "payment_method": {
            "description": "Payment method such as card, bank transfer, cash, or UPI",
            "type": "string"
          },
          "transaction_reference": {
            "description": "Transaction reference",
            "type": "string"
          },
          "payment_status": {
            "description": "Payment status",
            "type": "string"
          }
        }
      }
    }
    $$);