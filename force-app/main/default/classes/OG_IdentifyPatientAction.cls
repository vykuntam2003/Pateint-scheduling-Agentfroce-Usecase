public without sharing class OG_IdentifyPatientAction {

    private static final String ACTION_IDENTIFY  = 'identify';
    private static final String ACTION_REGISTER  = 'register';
    private static final String RT_PERSON_ACCT   = 'PersonAccount';
    private static final Integer PHONE_TAIL_LEN  = 10;

    // ── Input ────────────────────────────────────────────────────
    public class ActionInput {
        @InvocableVariable(label='Input Data' required=true)
        public InputData input;
    }

    public class InputData {
        @AuraEnabled @InvocableVariable(label='Action Type' required=true
            description='Use "identify" to search for an existing patient or "register" to create a new one.')
        public String actionType;

        @AuraEnabled @InvocableVariable(label='Mobile Number'
            description='Patient registered mobile number.')
        public String mobileNumber;

        @AuraEnabled @InvocableVariable(label='Email Address'
            description='Patient registered email address.')
        public String emailAddress;

        @AuraEnabled @InvocableVariable(label='First Name'
            description='Required for registration. Patient first name.')
        public String firstName;

        @AuraEnabled @InvocableVariable(label='Last Name'
            description='Required for registration. Patient last name.')
        public String lastName;

        @AuraEnabled @InvocableVariable(label='Date of Birth'
            description='YYYY-MM-DD format. Optional for registration.')
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

        @AuraEnabled @InvocableVariable(label='Is Found'
            description='True if an existing patient was found.')
        public Boolean isFound;

        @AuraEnabled @InvocableVariable(label='Is New Patient'
            description='True if a new patient profile was created.')
        public Boolean isNewPatient;

        @AuraEnabled @InvocableVariable(label='Success'
            description='True if the action completed successfully.')
        public Boolean isSuccess;

        @AuraEnabled @InvocableVariable(label='Message'
            description='Human-readable result message for the patient.')
        public String message;
    }

    // ── Entry Point ──────────────────────────────────────────────
    @InvocableMethod(
        label='Identify or Register Patient'
        description='Step 1: Searches for a patient by phone or email. Step 2: Creates a new Person Account if not found. Always call this FIRST before any other action.'
        category='Onco Global')
    public static List<ActionOutput> execute(List<ActionInput> inputs) {
        InputData inp = inputs[0].input;
        OutputData outData = new OutputData();
        outData.isFound = false;
        outData.isNewPatient = false;
        outData.isSuccess = false;

        try {
            System.debug('>>> OG_IdentifyPatientAction | actionType=' + inp.actionType);
            String action = String.isNotBlank(inp.actionType)
                ? inp.actionType.trim().toLowerCase() : '';

            if (action == ACTION_IDENTIFY) {
                outData = identifyPatient(inp);
            } else if (action == ACTION_REGISTER) {
                outData = registerPatient(inp);
            } else {
                outData.message = 'Invalid action type. Use "identify" or "register".';
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Error: ' + ex.getMessage()
                + ' | Stack: ' + ex.getStackTraceString());
            outData.message = 'Something went wrong: ' + ex.getMessage();
        }

        System.debug('<<< Result: isSuccess=' + outData.isSuccess
            + ', isFound=' + outData.isFound + ', patientId=' + outData.patientId);
            
        ActionOutput actionOut = new ActionOutput();
        actionOut.output = outData;
        return new List<ActionOutput>{ actionOut };
    }

    // ── Identify ─────────────────────────────────────────────────
    private static OutputData identifyPatient(InputData inp) {
        OutputData out = new OutputData();
        out.isFound = false;
        out.isNewPatient = false;
        out.isSuccess = false;

        String phone = normalizePhone(inp.mobileNumber);
        String email = String.isNotBlank(inp.emailAddress)
            ? inp.emailAddress.trim().toLowerCase() : null;

        System.debug('Identify — phone=' + phone + ', email=' + email);

        if (String.isBlank(phone) && String.isBlank(email)) {
            out.message = 'Please provide your registered mobile number or email address so I can look you up.';
            return out;
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

        System.debug('Search returned ' + patients.size() + ' result(s)');

        if (!patients.isEmpty()) {
            Account p = patients[0];
            out.isFound = true;
            out.isSuccess = true;
            out.patientId = p.Id;
            out.patientName = p.FirstName + ' ' + p.LastName;
            out.message = 'Welcome back, ' + p.FirstName
                + '! I found your profile. How can I help you today?';
        } else {
            out.isSuccess = true;
            out.message = 'I could not find your profile. Would you like me to create one? '
                + 'I will need your First Name, Last Name, and Date of Birth.';
        }
        return out;
    }

    // ── Register ─────────────────────────────────────────────────
    private static OutputData registerPatient(InputData inp) {
        OutputData out = new OutputData();
        out.isFound = false;
        out.isNewPatient = false;
        out.isSuccess = false;

        if (String.isBlank(inp.firstName) || String.isBlank(inp.lastName)) {
            out.message = 'I need both your first name and last name to create your profile.';
            return out;
        }

        System.debug('Register — ' + inp.firstName + ' ' + inp.lastName);

        // Check for existing duplicate before creating
        String phone = normalizePhone(inp.mobileNumber);
        String email = String.isNotBlank(inp.emailAddress)
            ? inp.emailAddress.trim().toLowerCase() : null;
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
                out.isFound = true;
                out.isSuccess = true;
                out.patientId = existing[0].Id;
                out.patientName = existing[0].FirstName + ' ' + existing[0].LastName;
                out.message = 'A profile already exists with this contact info. '
                    + 'Welcome back, ' + existing[0].FirstName + '!';
                return out;
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
        out.isNewPatient = true;
        out.isFound = true;
        out.patientId = newPatient.Id;
        out.patientName = inp.firstName.trim() + ' ' + inp.lastName.trim();
        out.message = 'Welcome, ' + inp.firstName.trim()
            + '! Your profile has been created. How can I help you today?';
        return out;
    }

    // ── Phone Normalizer ─────────────────────────────────────────
    private static String normalizePhone(String phone) {
        if (String.isBlank(phone)) return '';
        String digits = phone.replaceAll('[^0-9]', '');
        return digits.length() >= PHONE_TAIL_LEN
            ? digits.substring(digits.length() - PHONE_TAIL_LEN) : digits;
    }
}