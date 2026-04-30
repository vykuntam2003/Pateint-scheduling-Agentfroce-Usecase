public with sharing class OG_ViewAppointmentsAction {

    private static final Integer MAX_RESULTS    = 10;
    private static final String  FILTER_UPCOMING = 'upcoming';
    private static final String  FILTER_PAST     = 'past';
    private static final String  FILTER_CANCELED = 'canceled';
    private static final String  FILTER_ALL      = 'all';

    // ── Input ────────────────────────────────────────────────────
    public class ActionInput {
        @InvocableVariable(label='Input Data' required=true)
        public InputData input;
    }

    public class InputData {
        @AuraEnabled @InvocableVariable(label='Patient ID' required=true
            description='Salesforce Account ID from the Identify Patient action.')
        public String patientId;

        @AuraEnabled @InvocableVariable(label='Status Filter'
            description='Filter type: upcoming (default), past, canceled, or all.')
        public String statusFilter;
    }

    // ── Output ───────────────────────────────────────────────────
    public class ActionOutput {
        @InvocableVariable(label='Output Data')
        public OutputData output;
    }

    public class OutputData {
        @AuraEnabled @InvocableVariable(label='Has Appointments'
            description='True if patient has matching appointments.')
        public Boolean hasAppointments;

        @AuraEnabled @InvocableVariable(label='Appointment Count'
            description='Number of appointments found.')
        public Integer appointmentCount;

        @AuraEnabled @InvocableVariable(label='Appointment Summary'
            description='Formatted text listing all appointments.')
        public String appointmentSummary;

        @AuraEnabled @InvocableVariable(label='Appointment IDs'
            description='Comma-separated ServiceAppointment IDs.')
        public String appointmentIds;

        @AuraEnabled @InvocableVariable(label='Success'
            description='True if completed successfully.')
        public Boolean isSuccess;

        @AuraEnabled @InvocableVariable(label='Error Message'
            description='Error details if failed.')
        public String errorMessage;
    }

    // ── Entry Point ──────────────────────────────────────────────
    @InvocableMethod(
        label='View Patient Appointments'
        description='Retrieves existing appointments for a verified patient. Use statusFilter for upcoming, past, canceled, or all. Call Identify Patient FIRST to get the Patient ID.'
        category='Onco Global')
    public static List<ActionOutput> execute(List<ActionInput> inputs) {
        InputData inp = inputs[0].input;
        OutputData outData = new OutputData();

        try {
            System.debug('>>> OG_ViewAppointmentsAction | patientId='
                + inp.patientId + ', filter=' + inp.statusFilter);

            if (String.isBlank(inp.patientId)) {
                outData.isSuccess = false;
                outData.errorMessage = 'Patient ID is required. Please use "Identify Patient" first.';
                ActionOutput errOut = new ActionOutput();
                errOut.output = outData;
                return new List<ActionOutput>{ errOut };
            }

            // Validate ID format
            try { Id validId = (Id) inp.patientId.trim(); }
            catch (Exception e) {
                outData.isSuccess = false;
                outData.errorMessage = '"' + inp.patientId
                    + '" is not a valid Patient ID. Call "Identify Patient" first.';
                ActionOutput errOut = new ActionOutput();
                errOut.output = outData;
                return new List<ActionOutput>{ errOut };
            }

            String filter = resolveFilter(inp.statusFilter);
            List<ServiceAppointment> appointments =
                queryAppointments(inp.patientId.trim(), filter);

            System.debug('Found ' + appointments.size() + ' appointment(s)');

            outData.hasAppointments = !appointments.isEmpty();
            outData.appointmentCount = appointments.size();
            outData.appointmentSummary = formatAppointments(appointments, filter);
            outData.appointmentIds = extractIds(appointments);
            outData.isSuccess = true;

        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Error: ' + ex.getMessage()
                + ' | Stack: ' + ex.getStackTraceString());
            outData.isSuccess = false;
            outData.errorMessage = 'Error checking appointments: ' + ex.getMessage();
        }

        System.debug('<<< hasAppts=' + outData.hasAppointments
            + ', count=' + outData.appointmentCount);
        ActionOutput finalOut = new ActionOutput();
        finalOut.output = outData;
        return new List<ActionOutput>{ finalOut };
    }

    // ── Filter resolver ──────────────────────────────────────────
    private static String resolveFilter(String input) {
        if (String.isBlank(input)) return FILTER_UPCOMING;
        String normalized = input.toLowerCase().trim();
        Set<String> valid = new Set<String>{
            FILTER_UPCOMING, FILTER_PAST, FILTER_CANCELED, FILTER_ALL
        };
        return valid.contains(normalized) ? normalized : FILTER_UPCOMING;
    }

    // ── Query appointments ───────────────────────────────────────
    private static List<ServiceAppointment> queryAppointments(
            String patientId, String filter) {

        if (filter == FILTER_UPCOMING) {
            return [SELECT Id, AppointmentNumber, Status, SchedStartTime, SchedEndTime,
                           WorkType.Name, ServiceTerritory.Name,
                           (SELECT ServiceResource.Name FROM ServiceResources)
                    FROM ServiceAppointment
                    WHERE AccountId = :patientId
                      AND SchedStartTime >= TODAY
                      AND Status NOT IN ('Canceled', 'Cannot Complete')
                    ORDER BY SchedStartTime ASC LIMIT :MAX_RESULTS];
        }
        if (filter == FILTER_PAST) {
            return [SELECT Id, AppointmentNumber, Status, SchedStartTime, SchedEndTime,
                           WorkType.Name, ServiceTerritory.Name,
                           (SELECT ServiceResource.Name FROM ServiceResources)
                    FROM ServiceAppointment
                    WHERE AccountId = :patientId AND SchedStartTime < TODAY
                    ORDER BY SchedStartTime DESC LIMIT :MAX_RESULTS];
        }
        if (filter == FILTER_CANCELED) {
            return [SELECT Id, AppointmentNumber, Status, SchedStartTime, SchedEndTime,
                           WorkType.Name, ServiceTerritory.Name,
                           (SELECT ServiceResource.Name FROM ServiceResources)
                    FROM ServiceAppointment
                    WHERE AccountId = :patientId AND Status = 'Canceled'
                    ORDER BY SchedStartTime DESC LIMIT :MAX_RESULTS];
        }
        return [SELECT Id, AppointmentNumber, Status, SchedStartTime, SchedEndTime,
                       WorkType.Name, ServiceTerritory.Name,
                       (SELECT ServiceResource.Name FROM ServiceResources)
                FROM ServiceAppointment
                WHERE AccountId = :patientId
                ORDER BY SchedStartTime DESC LIMIT :MAX_RESULTS];
    }

    // ── Formatter ────────────────────────────────────────────────
    private static String formatAppointments(
            List<ServiceAppointment> appointments, String filter) {

        List<String> lines = new List<String>{
            filter.toUpperCase() + ' APPOINTMENTS (' + appointments.size() + ' found):\n'
        };

        if (appointments.isEmpty()) {
            lines.add('You have no ' + filter + ' appointments.');
            return String.join(lines, '\n');
        }

        for (ServiceAppointment appt : appointments) {
            String doc = (appt.ServiceResources != null && !appt.ServiceResources.isEmpty())
                ? appt.ServiceResources[0].ServiceResource.Name : 'Not assigned';
            String hosp = appt.ServiceTerritory != null
                ? appt.ServiceTerritory.Name : 'Onco Global';
            String apptType = appt.WorkType != null
                ? appt.WorkType.Name : 'Consultation';

            lines.add('Appointment # : ' + appt.AppointmentNumber);
            lines.add('  Status      : ' + appt.Status);
            lines.add('  Date/Time   : ' + appt.SchedStartTime.format('EEEE, MMMM d, yyyy h:mm a'));
            lines.add('  Doctor      : ' + doc);
            lines.add('  Hospital    : ' + hosp);
            lines.add('  Type        : ' + apptType);
            lines.add('  ID          : ' + appt.Id);
            lines.add('');
        }
        return String.join(lines, '\n');
    }

    // ── ID extractor ─────────────────────────────────────────────
    private static String extractIds(List<ServiceAppointment> appointments) {
        List<String> ids = new List<String>();
        for (ServiceAppointment appt : appointments) {
            ids.add(appt.Id);
        }
        return String.join(ids, ',');
    }
}