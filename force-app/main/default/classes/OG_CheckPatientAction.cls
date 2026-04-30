public without sharing class OG_CheckPatientAction {

    // ── Input ────────────────────────────────────────────────────
    public class ActionInput {
        @InvocableVariable(label='Input Data' required=true)
        public InputData input;
    }

    public class InputData {
        @AuraEnabled @InvocableVariable(label='Mobile Number'
            description='Patient registered mobile number.')
        public String mobileNumber;

        @AuraEnabled @InvocableVariable(label='Email Address'
            description='Patient registered email address.')
        public String emailAddress;
    }

    // ── Output ───────────────────────────────────────────────────
    public class ActionOutput {
        @InvocableVariable(label='Output Data')
        public OutputData output;
    }

    public class OutputData {
        @AuraEnabled @InvocableVariable(label='Patient ID'
            description='Salesforce Account ID of the patient.')
        public String patientId;

        @AuraEnabled @InvocableVariable(label='Patient Name'
            description='Full name of the patient.')
        public String patientName;

        @AuraEnabled @InvocableVariable(label='Is Found'
            description='True if an existing patient was found.')
        public Boolean isFound;

        @AuraEnabled @InvocableVariable(label='Success'
            description='True if the action completed successfully.')
        public Boolean isSuccess;

        @AuraEnabled @InvocableVariable(label='Message'
            description='Human-readable result message for the patient.')
        public String message;
    }

    // ── Entry Point ──────────────────────────────────────────────
    @InvocableMethod(
        label='Check Existing Patient'
        description='Searches for a patient by phone or email. Returns if found and their details.'
        category='Onco Global')
    public static List<ActionOutput> execute(List<ActionInput> inputs) {
        InputData inp = inputs[0].input;
        OutputData out = new OutputData();
        out.isFound = false;
        out.isSuccess = false;

        try {
            String phone = normalizePhone(inp.mobileNumber);
            String email = String.isNotBlank(inp.emailAddress)
                ? inp.emailAddress.trim().toLowerCase() : null;

            System.debug('Check Patient — phone=' + phone + ', email=' + email);

            if (String.isBlank(phone) && String.isBlank(email)) {
                out.message = 'Please provide your registered mobile number or email address so I can look you up.';
                ActionOutput actionOut = new ActionOutput();
                actionOut.output = out;
                return new List<ActionOutput>{ actionOut };
            }

            String phoneFilter = String.isNotBlank(phone) ? '%' + phone : null;
            List<Account> patients;

            if (phoneFilter != null && email != null) {
                patients = [SELECT Id, FirstName, LastName, PersonEmail, PersonMobilePhone
                            FROM Account WHERE IsPersonAccount = true
                            AND (PersonMobilePhone LIKE :phoneFilter OR PersonEmail = :email)
                            LIMIT 1];
            } else if (phoneFilter != null) {
                patients = [SELECT Id, FirstName, LastName, PersonEmail, PersonMobilePhone
                            FROM Account WHERE IsPersonAccount = true
                            AND PersonMobilePhone LIKE :phoneFilter LIMIT 1];
            } else {
                patients = [SELECT Id, FirstName, LastName, PersonEmail, PersonMobilePhone
                            FROM Account WHERE IsPersonAccount = true
                            AND PersonEmail = :email LIMIT 1];
            }

            if (!patients.isEmpty()) {
                Account p = patients[0];
                out.isFound = true;
                out.isSuccess = true;
                out.patientId = p.Id;
                out.patientName = p.FirstName + ' ' + p.LastName;
                out.message = 'Welcome back, ' + p.FirstName + '! I found your profile. How can I help you today?';
            } else {
                out.isSuccess = true;
                out.message = 'I could not find your profile. Would you like me to create one?';
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Error: ' + ex.getMessage()
                + ' | Stack: ' + ex.getStackTraceString());
            out.message = 'Something went wrong: ' + ex.getMessage();
        }

        ActionOutput actionOut = new ActionOutput();
        actionOut.output = out;
        return new List<ActionOutput>{ actionOut };
    }

    private static String normalizePhone(String phone) {
        if (String.isBlank(phone)) return '';
        String digits = phone.replaceAll('[^0-9]', '');
        return digits.length() >= 10
            ? digits.substring(digits.length() - 10) : digits;
    }
}