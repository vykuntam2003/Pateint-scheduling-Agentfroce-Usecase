/**
 * @description Agentforce Action — Patient Verification
 *              Handles patient identification (lookup by mobile/email)
 *              and registration (create new Person Account).
 * @author      Onco Global Dev Team
 * @date        2026-04-22
 */
public without sharing class OG_PatientVerificationAction {

    private static final String ACTION_IDENTIFY = 'identify';
    private static final String ACTION_REGISTER = 'register';
    private static final String PERSON_ACCOUNT_RT = 'PersonAccount';
    private static final Integer PHONE_DIGITS_LENGTH = 10;

    public class Request {
        @InvocableVariable(label='Action Type' description='Use "identify" to look up or "register" to create a patient' required=true)
        public String actionType;
        @InvocableVariable(label='Mobile Number' description='Patient registered mobile number')
        public String mobileNumber;
        @InvocableVariable(label='Email Address' description='Patient registered email address')
        public String emailAddress;
        @InvocableVariable(label='First Name' description='Patient first name for registration')
        public String firstName;
        @InvocableVariable(label='Last Name' description='Patient last name for registration')
        public String lastName;
        @InvocableVariable(label='City' description='Patient city for registration')
        public String city;
    }

    public class Response {
        @InvocableVariable(label='Is Found')
        public Boolean isFound;
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Patient Account Id')
        public String patientAccountId;
        @InvocableVariable(label='Patient Name')
        public String patientName;
        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(label='OG Patient Verification' description='Identify or register a patient. actionType: identify or register.' category='Onco Global')
    public static List<Response> execute(List<Request> requests) {
        System.debug('OG_PatientVerificationAction invoked with ' + requests.size() + ' request(s)');
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            System.debug('Action Type: ' + req.actionType + ' | Mobile: ' + req.mobileNumber + ' | Email: ' + req.emailAddress);
            String action = String.isNotBlank(req.actionType) ? req.actionType.trim().toLowerCase() : '';
            if (action == ACTION_IDENTIFY) {
                responses.add(identifyPatient(req));
            } else if (action == ACTION_REGISTER) {
                responses.add(registerPatient(req));
            } else {
                Response res = new Response();
                res.isFound = false;
                res.isSuccess = false;
                res.message = 'Invalid action type. Use "identify" or "register".';
                System.debug('Invalid action type received: ' + req.actionType);
                responses.add(res);
            }
        }
        return responses;
    }

    private static Response identifyPatient(Request req) {
        Response res = new Response();
        res.isFound = false;
        res.isSuccess = false;

        String normalizedPhone = normalizePhone(req.mobileNumber);
        String email = String.isNotBlank(req.emailAddress) ? req.emailAddress.trim().toLowerCase() : null;
        System.debug('Identifying patient — Normalized Phone: ' + normalizedPhone + ' | Email: ' + email);

        if (String.isBlank(normalizedPhone) && String.isBlank(email)) {
            res.message = 'Please provide your registered mobile number or email address so I can look up your profile.';
            System.debug('No identifier provided');
            return res;
        }

        String phoneFilter = String.isNotBlank(normalizedPhone) ? '%' + normalizedPhone : null;
        List<Account> patients;

        if (phoneFilter != null && email != null) {
            patients = [SELECT Id, FirstName, LastName, PersonEmail, PersonMobilePhone
                        FROM Account WHERE IsPersonAccount = true
                        AND (PersonMobilePhone LIKE :phoneFilter OR PersonEmail = :email) LIMIT 1];
        } else if (phoneFilter != null) {
            patients = [SELECT Id, FirstName, LastName, PersonEmail, PersonMobilePhone
                        FROM Account WHERE IsPersonAccount = true
                        AND PersonMobilePhone LIKE :phoneFilter LIMIT 1];
        } else {
            patients = [SELECT Id, FirstName, LastName, PersonEmail, PersonMobilePhone
                        FROM Account WHERE IsPersonAccount = true
                        AND PersonEmail = :email LIMIT 1];
        }

        System.debug('Patient search returned ' + patients.size() + ' result(s)');

        if (!patients.isEmpty()) {
            Account patient = patients[0];
            res.isFound = true;
            res.isSuccess = true;
            res.patientAccountId = patient.Id;
            res.patientName = patient.FirstName + ' ' + patient.LastName;
            res.message = 'Welcome back, ' + patient.FirstName + '! How can I help you today?';
            System.debug('Patient found: ' + res.patientName + ' (Id: ' + patient.Id + ')');
        } else {
            res.isSuccess = true;
            res.message = 'I couldn\'t find your profile. Please provide your first name and last name to create your profile.';
            System.debug('No patient found for given identifier');
        }
        return res;
    }

    private static Response registerPatient(Request req) {
        Response res = new Response();
        res.isSuccess = false;
        res.isFound = false;
        System.debug('Registering patient — First: ' + req.firstName + ' | Last: ' + req.lastName);

        if (String.isBlank(req.firstName) || String.isBlank(req.lastName)) {
            res.message = 'I need both first name and last name to create your profile. Could you provide your full name?';
            System.debug('Missing name fields — firstName blank: ' + String.isBlank(req.firstName) + ' | lastName blank: ' + String.isBlank(req.lastName));
            return res;
        }

        try {
            Id personAcctRTId = Schema.SObjectType.Account
                .getRecordTypeInfosByDeveloperName()
                .get(PERSON_ACCOUNT_RT).getRecordTypeId();
            System.debug('Person Account RecordType Id: ' + personAcctRTId);

            // Check for existing duplicate
            String phone = normalizePhone(req.mobileNumber);
            String email = String.isNotBlank(req.emailAddress) ? req.emailAddress.trim().toLowerCase() : null;
            String phoneFilter = String.isNotBlank(phone) ? '%' + phone : null;

            if (phoneFilter != null || email != null) {
                List<Account> existing;
                if (phoneFilter != null && email != null) {
                    existing = [SELECT Id FROM Account WHERE IsPersonAccount = true
                                AND (PersonMobilePhone LIKE :phoneFilter OR PersonEmail = :email) LIMIT 1];
                } else if (phoneFilter != null) {
                    existing = [SELECT Id FROM Account WHERE IsPersonAccount = true
                                AND PersonMobilePhone LIKE :phoneFilter LIMIT 1];
                } else {
                    existing = [SELECT Id FROM Account WHERE IsPersonAccount = true
                                AND PersonEmail = :email LIMIT 1];
                }
                if (!existing.isEmpty()) {
                    res.isSuccess = true;
                    res.isFound = true;
                    res.patientAccountId = existing[0].Id;
                    res.message = 'A profile already exists with this contact information. I have linked you to the existing profile.';
                    System.debug('Duplicate found — existing Account Id: ' + existing[0].Id);
                    return res;
                }
            }

            Account newPatient = new Account(
                RecordTypeId = personAcctRTId,
                FirstName = req.firstName.trim(),
                LastName = req.lastName.trim()
            );
            if (String.isNotBlank(req.mobileNumber)) newPatient.PersonMobilePhone = req.mobileNumber.trim();
            if (String.isNotBlank(req.emailAddress)) newPatient.PersonEmail = req.emailAddress.trim().toLowerCase();
            if (String.isNotBlank(req.city)) {
                newPatient.BillingCity = req.city.trim();
            }
            insert newPatient;

            res.isSuccess = true;
            res.isFound = true;
            res.patientAccountId = newPatient.Id;
            res.patientName = req.firstName.trim() + ' ' + req.lastName.trim();
            res.message = 'Thank you! Your profile has been created successfully. How can I assist you today?';
            System.debug('New patient created: ' + res.patientName + ' (Id: ' + newPatient.Id + ')');
        } catch (Exception e) {
            res.message = 'Error creating profile: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, 'Registration error: ' + e.getMessage() + ' | Stack: ' + e.getStackTraceString());
        }
        return res;
    }

    private static String normalizePhone(String phone) {
        if (String.isBlank(phone)) return '';
        String digits = phone.replaceAll('[^0-9]', '');
        String result = digits.length() >= PHONE_DIGITS_LENGTH
            ? digits.substring(digits.length() - PHONE_DIGITS_LENGTH) : digits;
        System.debug('Phone normalized: "' + phone + '" → "' + result + '"');
        return result;
    }
}