public without sharing class OG_FindDoctorSlotsAction {

    // ── Input ────────────────────────────────────────────────────
    public class ActionInput {
        @InvocableVariable(label='Input Data' required=true)
        public InputData input;
    }

    public class InputData {
        @AuraEnabled @InvocableVariable(label='Patient ID' required=true
            description='Salesforce Account ID of the patient.')
        public String patientId;

        @AuraEnabled @InvocableVariable(label='Symptom Description' required=true
            description='Patient symptoms or reason for visit.')
        public String symptomDescription;

        @AuraEnabled @InvocableVariable(label='Doctor Name'
            description='Specific doctor name (optional).')
        public String doctorName;

        @AuraEnabled @InvocableVariable(label='Preferred City' required=true
            description='Preferred city for the appointment.')
        public String preferredCity;

        @AuraEnabled @InvocableVariable(label='Preferred Date'
            description='YYYY-MM-DD format (optional, defaults to today).')
        public String preferredDate;
    }

    // ── Output ───────────────────────────────────────────────────
    public class ActionOutput {
        @InvocableVariable(label='Output Data')
        public OutputData output;
    }

    public class OutputData {
        @AuraEnabled @InvocableVariable(label='Doctor and Slot Options'
            description='Human-readable summary of available doctors and slots.')
        public String availableSlotsSummary;

        @AuraEnabled @InvocableVariable(label='Recommended Specialty'
            description='Specialty determined from symptoms.')
        public String recommendedSpecialty;

        @AuraEnabled @InvocableVariable(label='Success'
            description='True if lookup succeeded.')
        public Boolean isSuccess;

        @AuraEnabled @InvocableVariable(label='Error Message'
            description='User-friendly error message if applicable.')
        public String errorMessage;

        @AuraEnabled @InvocableVariable(label='Search Date'
            description='The date searched for availability (yyyy-MM-dd).')
        public String searchDate;

        @AuraEnabled @InvocableVariable(label='Doctor List JSON'
            description='JSON string of doctor and slot data for LWC rendering.')
        public String doctorListJson;
    }

    public class DoctorInfo {
        @AuraEnabled public String name;
        @AuraEnabled public String resourceId;
        @AuraEnabled public String hospitalName;
        @AuraEnabled public String slotsJson;
    }

    // ── Entry Point ──────────────────────────────────────────────
    @InvocableMethod(
        label='Find Doctors and Available Slots'
        description='Searches for doctors based on symptoms and preferred city, then returns availability.'
        category='Onco Global')
    public static List<ActionOutput> execute(List<ActionInput> inputs) {
        InputData inp = inputs[0].input;
        OutputData out = new OutputData();
        out.isSuccess = false;
        out.doctorListJson = '[]';

        try {
            if (String.isBlank(inp.patientId)) {
                out.errorMessage = 'Patient ID is required. Please use "Check Existing Patient" first.';
                ActionOutput errOut = new ActionOutput();
                errOut.output = out;
                return new List<ActionOutput>{ errOut };
            }
            if (String.isBlank(inp.preferredCity)) {
                out.errorMessage = 'Please provide a preferred city to search for doctors.';
                ActionOutput errOut = new ActionOutput();
                errOut.output = out;
                return new List<ActionOutput>{ errOut };
            }

            System.debug('>>> FindDoctors | symptoms: ' + inp.symptomDescription + ', city: ' + inp.preferredCity);

            // 1. Get reference lists
            String specialtyList = OG_DoctorSearchService.buildSpecialtyList();
            String cityList = OG_DoctorSearchService.buildCityList();

            // 2. Resolve specialty
            String specialty = '';
            if (String.isNotBlank(inp.symptomDescription)) {
                String ptResult = OG_DoctorSearchService.callSymptomPT(inp, specialtyList);
                specialty = OG_DoctorSearchService.validateSpecialty(ptResult, specialtyList);
            }
            if (String.isBlank(specialty) && String.isBlank(inp.doctorName)) {
                out.errorMessage = 'I could not determine the right specialty. '
                    + 'Here are some available specialties: \n' + specialtyList;
                out.isSuccess = true;
                ActionOutput errOut = new ActionOutput();
                errOut.output = out;
                return new List<ActionOutput>{ errOut };
            }
            out.recommendedSpecialty = specialty;

            // 3. Find Doctors
            List<ServiceResource> doctors = OG_DoctorSearchService.findDoctors(inp, specialty);
            if (doctors.isEmpty()) {
                out.errorMessage = 'No ' + (String.isNotBlank(specialty) ? specialty : '')
                    + ' doctors found in ' + inp.preferredCity + '.\n'
                    + OG_DoctorSearchService.buildAlternatives(specialty, inp.preferredCity, cityList);
                out.isSuccess = true;
                ActionOutput errOut = new ActionOutput();
                errOut.output = out;
                return new List<ActionOutput>{ errOut };
            }

            // 4. Fetch Slots
            Date targetDate = OG_DoctorSearchService.parseDate(inp.preferredDate);
            out.searchDate = DateTime.newInstance(targetDate, Time.newInstance(0,0,0,0)).format('yyyy-MM-dd');
            Map<Id, List<TimeSlot>> slotsMap = OG_DoctorSearchService.fetchTimeSlots(doctors);
            Map<String, List<ServiceAppointment>> bookedMap = OG_DoctorSearchService.fetchBooked(doctors, targetDate);

            // 5. Build LWC UI Data
            List<DoctorInfo> docList = OG_DoctorSearchService.buildDoctorList(doctors, slotsMap, targetDate, inp.preferredCity);
            out.doctorListJson = JSON.serialize(docList);

            // 6. Build Raw Data & Get Summary
            String rawData = OG_DoctorSearchService.buildRawData(doctors, slotsMap, bookedMap, targetDate, inp.preferredCity);
            out.availableSlotsSummary = OG_DoctorSearchService.callSummaryPT(rawData, specialty, inp.preferredCity, inp.preferredDate, '');
            out.isSuccess = true;

        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'FindDoctors Error: ' + ex.getMessage());
            out.errorMessage = 'Something went wrong: ' + ex.getMessage();
        }

        ActionOutput finalOut = new ActionOutput();
        finalOut.output = out;
        return new List<ActionOutput>{ finalOut };
    }
}