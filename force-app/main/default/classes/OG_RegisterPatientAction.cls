public without sharing class OG_RegisterPatientAction {

    private static final String RT_PERSON_ACCT = 'PersonAccount';

    // ── Input ────────────────────────────────────────────────────
    public class ActionInput {
        @InvocableVariable(label='Input Data' required=true)
        public InputData input;
    }

    public class InputData {
        @AuraEnabled @InvocableVariable(label='First Name' required=true
            description='Patient first name.')
        public String firstName;

        @AuraEnabled @InvocableVariable(label='Last Name' required=true
            description='Patient last name.')
        public String lastName;

        @AuraEnabled @InvocableVariable(label='Mobile Number'
            description='Patient mobile number.')
        public String mobileNumber;

        @AuraEnabled @InvocableVariable(label='Email Address'
            description='Patient email address.')
        public String emailAddress;

        @AuraEnabled @InvocableVariable(label='Date of Birth'
            description='YYYY-MM-DD format. Optional.')
        public String dateOfBirth;
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

        @AuraEnabled @InvocableVariable(label='Is Success'
            description='True if the registration was successful.')
        public Boolean isSuccess;

        @AuraEnabled @InvocableVariable(label='Message'
            description='Human-readable result message.')
        public String message;
    }

    // ── Entry Point ──────────────────────────────────────────────
    @InvocableMethod(
        label='Register New Patient'
        description='Creates a new Person Account for the patient. Use this only if Check Existing Patient returns not found.'
        category='Onco Global')
    public static List<ActionOutput> execute(List<ActionInput> inputs) {
        InputData inp = inputs[0].input;
        OutputData out = new OutputData();
        out.isSuccess = false;

        try {
            if (String.isBlank(inp.firstName) || String.isBlank(inp.lastName)) {
                out.message = 'I need both your first name and last name to create your profile.';
                ActionOutput actionOut = new ActionOutput();
                actionOut.output = out;
                return new List<ActionOutput>{ actionOut };
            }

            System.debug('Register — ' + inp.firstName + ' ' + inp.lastName);

            // Double check existing duplicate
            String phone = normalizePhone(inp.mobileNumber);
            String email = String.isNotBlank(inp.emailAddress) ? inp.emailAddress.trim().toLowerCase() : null;
            String phoneFilter = String.isNotBlank(phone) ? '%' + phone : null;

            if (phoneFilter != null || email != null) {
                List<Account> existing;
                if (phoneFilter != null && email != null) {
                    existing = [SELECT Id, FirstName, LastName FROM Account
                                WHERE IsPersonAccount = true
                                AND (PersonMobilePhone LIKE :phoneFilter OR PersonEmail = :email)
                                LIMIT 1];
                } else if (phoneFilter != null) {
                    existing = [SELECT Id, FirstName, LastName FROM Account
                                WHERE IsPersonAccount = true
                                AND PersonMobilePhone LIKE :phoneFilter LIMIT 1];
                } else {
                    existing = [SELECT Id, FirstName, LastName FROM Account
                                WHERE IsPersonAccount = true
                                AND PersonEmail = :email LIMIT 1];
                }
                if (!existing.isEmpty()) {
                    out.isSuccess = true;
                    out.patientId = existing[0].Id;
                    out.patientName = existing[0].FirstName + ' ' + existing[0].LastName;
                    out.message = 'A profile already exists with this contact info. Welcome back, ' + existing[0].FirstName + '!';
                    ActionOutput errOut = new ActionOutput();
                    errOut.output = out;
                    return new List<ActionOutput>{ errOut };
                }
            }

            // Create new Person Account
            Id rtId = Schema.SObjectType.Account
                .getRecordTypeInfosByDeveloperName()
                .get(RT_PERSON_ACCT).getRecordTypeId();

            Account newPatient = new Account(
                RecordTypeId = rtId,
                FirstName = inp.firstName.trim(),
                LastName = inp.lastName.trim()
            );
            if (String.isNotBlank(inp.mobileNumber)) {
                newPatient.PersonMobilePhone = inp.mobileNumber.trim();
            }
            if (String.isNotBlank(inp.emailAddress)) {
                newPatient.PersonEmail = inp.emailAddress.trim().toLowerCase();
            }
            if (String.isNotBlank(inp.dateOfBirth)) {
                try {
                    newPatient.PersonBirthdate = Date.valueOf(inp.dateOfBirth.trim());
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, 'Invalid DOB: ' + inp.dateOfBirth);
                }
            }

            insert newPatient;
            System.debug('New patient created: ' + newPatient.Id);

            out.isSuccess = true;
            out.patientId = newPatient.Id;
            out.patientName = inp.firstName.trim() + ' ' + inp.lastName.trim();
            out.message = 'Welcome, ' + inp.firstName.trim() + '! Your profile has been created. How can I help you today?';
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Error: ' + ex.getMessage() + ' | Stack: ' + ex.getStackTraceString());
            out.message = 'Something went wrong while creating profile: ' + ex.getMessage();
        }

        ActionOutput finalOut = new ActionOutput();
        finalOut.output = out;
        return new List<ActionOutput>{ finalOut };
    }

    private static String normalizePhone(String phone) {
        if (String.isBlank(phone)) return '';
        String digits = phone.replaceAll('[^0-9]', '');
        return digits.length() >= 10 ? digits.substring(digits.length() - 10) : digits;
    }
}